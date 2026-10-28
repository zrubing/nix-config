{
  writeShellApplication,
  sing-box,
  jq,
  curl,
  coreutils,
  util-linux,
  gawk,
}:

# 代理节点质量探针：按「真实可用性」而不是 RTT 选节点。
#
# 为什么不能用客户端自带健康检查：url-test / urltest 只发一个 204，跑在**已建立**
# 的会话上，测到的是 200–300ms 的热会话；而实际体验的分水岭是冷启动——实测同一
# 节点冷会话 5.6s、拥塞时 20s 起不来。本脚本每个候选都新起一个 sing-box 实例，
# 等于强制走一次冷启动，测出来的才是用户真正会遇到的代价。
#
# 输入只有两样：运行中的客户端配置（含 Clash API 地址/密钥，root 可读）和组名。
# 候选节点从 API 现读，不写死在 nix 里 —— 节点名、协议、地区都不进公开仓库。
#
# 输出：写 state.json（EWMA + 连续失败数），并（非 dry-run 时）通过 API 切换
# selector。带迟滞：新节点要显著更好且过了最小驻留时间才切，否则链路抖动会让
# 分组跟着噪声横跳。
writeShellApplication {
  name = "proxy-quality";

  runtimeInputs = [
    sing-box
    jq
    curl
    coreutils
    util-linux
    gawk
  ];

  text = ''
    config=""
    group=""
    group_file=/var/lib/proxy-quality/group
    url="https://www.gstatic.com/generate_204"
    bytes=65536
    timeout_s=8
    state=/var/lib/proxy-quality/state.json
    api_wait=60
    min_dwell=1200
    improvement=0.25
    alpha=0.4
    dry_run=0
    quick=0
    quick_fails=2
    excludes=()

    usage() {
      cat <<'EOF'
    proxy-quality - 按实测可用性选择代理节点

    用法:
      proxy-quality --config <运行中的客户端配置> --group <selector 组名> [选项]

    选项:
      --group-file <路径>     从文件读组名（默认 /var/lib/proxy-quality/group）。
                              每行一个，全部处理；优先于 --group。
      --url <探测 URL>        默认 https://www.gstatic.com/generate_204
      --bytes <字节数>        探测负载大小，用于把耗时换算成速率（默认 65536）
      --timeout <秒>          单个节点超时（默认 8）
      --state <路径>          状态文件（默认 /var/lib/proxy-quality/state.json，跨重启保留）
      --api-wait <秒>         等 Clash API 就绪的上限（默认 60）
      --min-dwell <秒>        切换后最小驻留时间（默认 1200）
      --improvement <比例>    新节点需优于当前的比例才切（默认 0.25）
      --alpha <比例>          EWMA 系数（默认 0.4）
      --exclude-suffix <后缀> 跳过 tag 以该后缀结尾的候选（可重复，如 -v6）
      --quick                只测当前节点做存活检查：正常就静默退出，
                             连续失败 --quick-fails 次才切到历史评分最优
      --quick-fails <次数>    快速模式下的失败阈值（默认 2）
      --dry-run              只测不切

    说明:
      · 每个候选都新起一个 sing-box 进程 = 强制冷启动，测的是首次连接代价；
      · 候选名单从运行中客户端的 Clash API 现读，不在 nix 里写死节点名；
      · 只驱动 selector 组；urltest/url-test 组不可写，会直接退出。
    EOF
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --config)      config="$2"; shift 2 ;;
        --group)       group="$2"; shift 2 ;;
        --group-file)  group_file="$2"; shift 2 ;;
        --url)         url="$2"; shift 2 ;;
        --bytes)       bytes="$2"; shift 2 ;;
        --timeout)     timeout_s="$2"; shift 2 ;;
        --state)       state="$2"; shift 2 ;;
        --api-wait)    api_wait="$2"; shift 2 ;;
        --min-dwell)   min_dwell="$2"; shift 2 ;;
        --improvement) improvement="$2"; shift 2 ;;
        --alpha)       alpha="$2"; shift 2 ;;
        --exclude-suffix) excludes+=("$2"); shift 2 ;;
        --quick)       quick=1; shift ;;
        --quick-fails) quick_fails="$2"; shift 2 ;;
        --dry-run)     dry_run=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    [ -n "$config" ] || { echo "--config 必填" >&2; exit 2; }

    # 全量评分和存活检查是两个 timer，会撞在同一秒；用文件锁把 state 的
    # 读-改-写串行化，避免互相覆盖。
    state_dir="$(dirname "$state")"
    install -d -m 0700 "$state_dir"
    exec 9>"$state_dir/lock"
    flock -w 60 9 || { echo "另一个探测还在跑，跳过本次" >&2; exit 0; }

    # 组名：文件每行一个，全部处理。--group 只在这台机器还没落组名文件时兜底 ——
    # 组名不进仓库，所以文件优先。
    if [ -s "$group_file" ]; then
      groups="$(tr -d '\r' < "$group_file" | grep -v '^[[:space:]]*$')"
      echo "组名来自 $group_file"
    else
      groups="$group"
    fi
    if [ -z "$groups" ]; then
      echo "没有组名：$group_file 不存在/为空，也没给 --group，跳过本次探测" >&2
      exit 0
    fi
    [ -r "$config" ] || { echo "读不到客户端配置: $config" >&2; exit 1; }

    api="$(jq -r '.experimental.clash_api.external_controller // empty' "$config")"
    secret="$(jq -r '.experimental.clash_api.secret // empty' "$config")"
    if [ -z "$api" ]; then
      echo "客户端没开 clash_api，无法探测" >&2
      exit 0
    fi
    base="http://$api"
    auth=()
    [ -n "$secret" ] && auth=(-H "Authorization: Bearer $secret")

    # sib 是 Type=simple：systemd 认为「已启动」时进程可能还没监听端口。
    # 开机或重建时本服务与 sib 同一秒被拉起，会扑空；先等 API 就绪，
    # 别把「还没起来」误报成「没这个组」。
    deadline=$(( $(date +%s) + api_wait ))
    until curl -fsS --max-time 2 "''${auth[@]}" "$base/version" >/dev/null 2>&1; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "Clash API $base 等了 ''${api_wait}s 仍不可达，跳过本次探测" >&2
        exit 1
      fi
      sleep 2
    done

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # 一个组跑一遍：候选、评分、驻留都按组隔离（state 以组名为 key）。
    process_group() {
      group="$1"
      local enc="" group_json="" gtype="" actual="" members="" now=0
      local results="$tmp/results.jsonl"
      local tag="" skip=0 suf="" t0=0 t1=0 ok=0 ms=0 score=0 row=""
      local prev="" bypass=0 cur="" since=0 best="" best_ewma=0 cur_ewma=0 cur_fails=0
      local switch=0 reason=""

      # 组名可能含非 ASCII，路径段必须百分号编码。
      enc="$(jq -rn --arg s "$group" '$s|@uri')"
      if ! group_json="$(curl -fsS "''${auth[@]}" "$base/proxies/$enc" 2>/dev/null)"; then
        echo "Clash API 已就绪，但取不到组 $group（组名不对，或该组不存在）" >&2
        return 1
      fi
      gtype="$(jq -r '.type' <<<"$group_json")"
      if [ "$gtype" != "Selector" ]; then
        echo "组 $group 是 $gtype，只有 selector 能被外部切换；跳过" >&2
        return 0
      fi

      # 客户端里的真实选择才是事实来源：sib 重启后会回到配置里的默认节点，
      # 而 state 里的 current 还停在上次切到的节点上。每轮都以 API 的 now 为准。
      actual="$(jq -r '.now // empty' <<<"$group_json")"

      if [ "$quick" = 1 ]; then
        # 存活检查：只测当前节点，把「节点死了没人发现」的窗口压到快速周期。
        if [ -z "$actual" ]; then
          echo "组 $group 当前没有选中节点，快速检查无事可做" >&2
          return 0
        fi
        members="$actual"
      else
        members="$(jq -r '.all[]?' <<<"$group_json")"
        if [ -z "$members" ]; then
          echo "组 $group 没有成员" >&2
          return 0
        fi
      fi

      now="$(date +%s)"
      : > "$results"

    while IFS= read -r tag; do
      [ -n "$tag" ] || continue
      skip=0
      for suf in ''${excludes[@]+"''${excludes[@]}"}; do
        case "$tag" in *"$suf") skip=1 ;; esac
      done
      if [ "$skip" = 1 ]; then
        echo "跳过 $tag：命中排除后缀" >&2
        continue
      fi
      # 每个候选独立配置：只留它自己 + direct，无 inbound、无 TUN。
      # 拿不到该 tag 的 outbound 就跳过（可能是嵌套组或已删除的节点）。
      if ! jq -e --arg t "$tag" '.outbounds[]|select(.tag==$t)' "$config" >/dev/null 2>&1; then
        echo "跳过 $tag：配置里没有这个出站" >&2
        continue
      fi
      jq --arg t "$tag" '{
        log: { level: "error" },
        outbounds: [ (.outbounds[]|select(.tag==$t)), { type: "direct", tag: "direct" } ],
        route: { final: "direct" }
      }' "$config" > "$tmp/probe.json"

      t0="$(date +%s%N)"
      ok=0
      if timeout "$timeout_s" sing-box tools fetch -c "$tmp/probe.json" \
           --outbound "$tag" "$url" >/dev/null 2>&1; then
        ok=1
      fi
      t1="$(date +%s%N)"
      ms=$(( (t1 - t0) / 1000000 ))
      [ "$ms" -gt 0 ] || ms=1

      # 分数 = 字节/秒（失败为 0）。大文件探测时它逼近吞吐，小文件时它同时惩罚
      # 冷启动：同样 64KB，热会话 0.2s 与冷启动 5.6s 差 28 倍。
      score="$(awk -v b="$bytes" -v m="$ms" -v ok="$ok" 'BEGIN{
        if (ok == 1) printf "%.0f", b * 1000 / m; else printf "0"
      }')"

      jq -cn --arg t "$tag" --argjson s "$score" --argjson ms "$ms" --argjson ok "$ok" \
        '{tag:$t, score:$s, ms:$ms, ok:$ok}' >> "$results"
    done <<< "$members"

      [ -f "$state" ] || echo '{}' > "$state"

    while IFS= read -r row; do
      tag="$(jq -r '.tag' <<<"$row")"
      score="$(jq -r '.score' <<<"$row")"
      ms="$(jq -r '.ms' <<<"$row")"
      ok="$(jq -r '.ok' <<<"$row")"
      jq --arg g "$group" --arg t "$tag" --argjson s "$score" \
         --argjson ok "$ok" --argjson ms "$ms" --argjson a "$alpha" '
        .[$g] //= { current: null, since: 0, nodes: {} }
        | .[$g].nodes[$t] //= {}
        | .[$g].nodes[$t].ewma =
            (if (.[$g].nodes[$t].ewma // null) == null
             then $s
             else ($a * $s + (1 - $a) * .[$g].nodes[$t].ewma) end)
        | .[$g].nodes[$t].fails =
            (if $ok == 1 then 0 else ((.[$g].nodes[$t].fails // 0) + 1) end)
        | .[$g].nodes[$t].ms = $ms
        | .[$g].nodes[$t].ok = $ok
      ' "$state" > "$state.next" && mv "$state.next" "$state"
    done < "$results"

    # 客户端里的真实选择才是事实来源：sib 重启后会回到配置里写的默认节点，
    # 而 state 里的 current 还停在上次切到的节点上。只在 state 为空时现读一次
    # 会漏掉这种重置 —— 之后一直以为自己在用 A、实际跑着 B。
    prev="$(jq -r --arg g "$group" '.[$g].current // empty' "$state")"
    bypass=0
    if [ "$actual" != "$prev" ]; then
      # 选择被外部改过（客户端重启、手工切换）：以实际为准，重置驻留起点，
      # 但本轮跳过驻留检查 —— 驻留期只防我们自己抖动，不该拦住「回到当前最优」。
      if [ -n "$actual" ]; then
        jq --arg g "$group" --arg c "$actual" --argjson now "$now" \
          '.[$g].current = $c | .[$g].since = $now' "$state" > "$state.next" \
          && mv "$state.next" "$state"
      fi
      cur="$actual"
      since="$now"
      bypass=1
    else
      cur="$actual"
      since="$(jq -r --arg g "$group" '.[$g].since // 0' "$state")"
    fi
    best="$(jq -r --arg g "$group" '
      .[$g].nodes | to_entries | map(select(.value.ewma > 0))
      | sort_by(-.value.ewma) | .[0].key // empty' "$state")"

    if [ -z "$best" ]; then
      echo "所有候选都失败，保持当前选择（$cur）"
      return 0
    fi

    cur_ewma="$(jq -r --arg g "$group" --arg c "$cur" '.[$g].nodes[$c].ewma // 0' "$state")"
    cur_fails="$(jq -r --arg g "$group" --arg c "$cur" '.[$g].nodes[$c].fails // 0' "$state")"
    best_ewma="$(jq -r --arg g "$group" --arg b "$best" '.[$g].nodes[$b].ewma // 0' "$state")"

    if [ "$quick" = 1 ]; then
      # 正常就静默：这个 timer 每分钟跑一次，不该刷日志。
      if [ "$cur_fails" -lt "$quick_fails" ]; then
        return 0
      fi
      # 连续失败才算死。切到历史评分最优（排除当前），不受驻留期约束。
      best="$(jq -r --arg g "$group" --arg c "$cur" '
        .[$g].nodes | to_entries
        | map(select(.value.ewma > 0 and .key != $c))
        | sort_by(-.value.ewma) | .[0].key // empty' "$state")"
      if [ -z "$best" ]; then
        echo "当前节点 $cur 连续失败 $cur_fails 次，且没有别的候选可用" >&2
        return 1
      fi
    else
      echo "组 $group 本次测量："
      jq -r --arg g "$group" '
        .[$g].nodes | to_entries | sort_by(-.value.ewma)[]
        | "  \(.key)\t\(.value.ms)ms\tewma=\(.value.ewma|floor)\tfails=\(.value.fails)"' "$state"
    fi

    switch=0
    reason=""
    if [ "$quick" = 1 ]; then
      switch=1; reason="存活检查连续失败 $cur_fails 次"
    elif [ -z "$cur" ]; then
      switch=1; reason="没有当前选择"
    elif [ "$best" = "$cur" ]; then
      :
    elif [ "$cur_fails" -ge 2 ]; then
      switch=1; reason="当前节点连续失败 $cur_fails 次"
    elif awk -v b="$best_ewma" -v c="$cur_ewma" -v i="$improvement" \
           'BEGIN{exit !(b > c * (1 + i))}'; then
      if [ "$bypass" = 1 ] || [ $(( now - since )) -ge "$min_dwell" ]; then
        switch=1; reason="优于当前 $(awk -v b="$best_ewma" -v c="$cur_ewma" 'BEGIN{printf "%.0f%%", (b/c-1)*100}')"
      else
        echo "$best 更快但还在驻留期（$(( now - since ))s / ''${min_dwell}s）"
      fi
    fi

    if [ "$switch" = 0 ]; then
      echo "保持 $cur"
      return 0
    fi

    echo "切换 $cur -> $best（$reason）"
    if [ "$dry_run" = 1 ]; then
      echo "dry-run：不实际切换"
      return 0
    fi

    if curl -fsS -X PUT "''${auth[@]}" -H 'Content-Type: application/json' \
         -d "$(jq -cn --arg n "$best" '{name:$n}')" \
         "$base/proxies/$enc" >/dev/null; then
      jq --arg g "$group" --arg b "$best" --argjson now "$now" \
        '.[$g].current = $b | .[$g].since = $now' "$state" > "$state.next" \
        && mv "$state.next" "$state"
    else
      echo "切换失败" >&2
      return 1
    fi
    }

    rc=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      process_group "$g" || rc=1
    done <<< "$groups"
    exit "$rc"
  '';

  meta = {
    description = "按实测冷启动可用性选择代理节点（Clash API）";
    mainProgram = "proxy-quality";
  };
}
