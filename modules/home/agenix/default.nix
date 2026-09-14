{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  home = config.home.homeDirectory;
  M = "0600"; # 这些全是凭据，统一 0600

  # pi 扩展/模型的配置只在启用 pi 模块的用户上存在（modules/home/pi）。
  # 未启用的用户（如 hiar）没有 ~/.config/pi/models-overlay.json，也不该跑
  # 合并——否则每次激活都要为一个用不到的 provider 做工作，还会因缺少 user
  # session 而失败（见 configurePiModels 注释）。
  piEnabled = config.${namespace}.modules.pi.enable;

  # 把 age secret 稳定地暴露到某个 app 硬编码的 dotfile 路径上。
  # symlink 默认 true → 明文只在 $XDG_RUNTIME_DIR，<path> 是个软链接。
  place = file: target: mode: {
    file = file;
    path = "${home}${target}";
    mode = mode;
  };

  # app 硬编码路径 → 声明式放置，不再拷贝
  placed = {
    "authinfo"                  = place "${mysecrets}/authinfo.age"                 "/.authinfo"                    M;
    "rclone.conf"               = place "${mysecrets}/rclone.conf.age"              "/.config/rclone/rclone.conf"   M;
    "topsap/env.ini"            = place "${mysecrets}/topsap/env.ini.age"           "/.config/topsap/env.ini"       M;
    "netrc"                     = place "${mysecrets}/netrc.age"                    "/.netrc"                       M;
    "work/k8s/milvzn.kube"      = place "${mysecrets}/work/k8s/milvzn.kube.age"     "/.kube/config-milv-default.yml" M;
    "work/k8s/sinopec.milv.kube" = place "${mysecrets}/work/k8s/milvzn.sinopec.kube.age" "/.kube/config-milv-sinopec.yml" M;
    "work/k8s/k0s.kube"         = place "${mysecrets}/work/k8s/k0s.kube.age"        "/.kube/config"         M;
    "codex/auth.json"           = place "${mysecrets}/codex/auth.json.age"          "/.codex/auth.json"             M;
    "ccr.config.json"           = place "${mysecrets}/ccr.config.age"               "/.claude-code-router/config.json" M;
    "agents/pi/auth.json"       = place "${mysecrets}/agents/pi/auth.json.age"      "/.pi/agent/auth.json"          M;
  };

  # 其余 secret 仍走默认 tmpfs 路径，交给别的模块消费（ssh、claude-code），
  # 以及必须「合并」而非直接拷贝的 pi models.json
  plain = {
    "ssh/topsap-config".file = "${mysecrets}/ssh/topsap-config.age";
    "ssh/work-config".file = "${mysecrets}/ssh/work-config.age";
    "ssh/default-config".file = "${mysecrets}/ssh/default-config.age";
    "claude.settings.json".file = "${mysecrets}/claude.settings.json.age";
    "agents/pi/models.json".file = "${mysecrets}/agents/pi/models.json.age";
  };

  # pi/models.json 是「age 密钥 ⊕ 明文 overlay」的合并，不是简单拷贝，
  # 这是唯一真正需要一步生成的 case，保留一个最小的生成 unit。
  #
  # 幂等守卫（2026-09-14 加）：本 unit 只在 boot 时由 default.target 拉起一次
  # （Type=oneshot + WantedBy=default.target），home-manager switch 不会重跑它。
  # 于是"只改 overlay（nix 侧非机密模型声明）而不改密文"时，~/.pi/agent/models.json
  # 会停留在旧内容——nix 构建看起来成功，pi 实际用的还是旧 provider 定义。
  # 这正是 modules/home/llm-routes/routes.nix 落地时会踩的坑：relay 的 apiKey /
  # 模型清单都在 overlay 里，密文不变则合并结果永不刷新。
  # 解法与 dsh 模块的 dsh.env 守卫同款：比对 overlay+secret 的内容哈希，变了才重写；
  # 状态文件在 ~/.pi/agent/.models-hash。首次无记录也重写并落基线。
  piModels = pkgs.writeShellScriptBin "agenix-pi-models" ''
    set -euo pipefail
    # agenix 的 secret 路径字面就是 "''${XDG_RUNTIME_DIR}/agenix/<name>"
    # （age-home.nix 的 userDirectory）。该变量由 user systemd session 提供，
    # 而本脚本也可能在无 session 的上下文被调用（激活期、或 Linger=no 的
    # 用户在开机早期）——此时 set -u 下直接解引用会 unbound 报错。故先兜底
    # 到 systemd 的固定 uid 路径（/run/user/<uid>），与 modules/home/ssh 的
    # replaceStrings 做法同源。
    XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    export XDG_RUNTIME_DIR
    secret=${config.age.secrets."agents/pi/models.json".path}
    overlay=${home}/.config/pi/models-overlay.json
    out=${home}/.pi/agent/models.json
    hash_state=${home}/.pi/agent/.models-hash
    mkdir -p "$(dirname "$out")"

    # 密钥尚未解密（首次激活、或 agenix.service 还没跑）→ 无事可做，静默退出。
    # 不要在这里报错：激活期调用本脚本时 secret 可能确实还不存在。
    if [ ! -f "$secret" ]; then
      exit 0
    fi

    # 输入指纹：两个来源文件的内容哈希（overlay 缺失时记成空）
    overlay_hash="none"
    if [ -f "$overlay" ]; then
      overlay_hash="$(${pkgs.coreutils}/bin/sha256sum "$overlay" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    fi
    secret_hash="none"
    if [ -f "$secret" ]; then
      secret_hash="$(${pkgs.coreutils}/bin/sha256sum "$secret" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    fi
    want="$overlay_hash:$secret_hash"
    have="$(${pkgs.coreutils}/bin/cat "$hash_state" 2>/dev/null || true)"

    # 输出缺失也必须重建（例如用户手删了 models.json）
    if [ "$want" = "$have" ] && [ -f "$out" ]; then
      exit 0
    fi

    if [ -f "$overlay" ]; then
      # 合并规则：overlay 对它声明的每个 provider 是**权威**——整体替换密文里的
      # 同名条目，只补回密文独有的 baseUrl（pi 的 baseUrl 不支持 env 插值，见
      # modules/home/llm-routes/routes.nix 文件头）。overlay 未声明的 provider
      # 保持原有的深合并行为。
      #
      # 为什么不能用朴素深合并 jq '.[0] * .[1]'（2026-09-14 实证）：jq 的 * 会
      # 递归合并，overlay 里 deepseek-relay.compat 只写了 supportsDeveloperRole，
      # 密文里那四个兼容键就会**透传**进结果——于是路由的 compat 有两个来源，
      # 改了 overlay 也删不掉密文里的旧键。这正是本次要消灭的"多来源"。
      # 同理 models 数组：虽然数组是整体替换，但 provider 层的标量（apiKey）必须
      # 以 overlay 为准，才能把明文 key 换成 $DEEPSEEK_RELAY_API_KEY 引用。
      ${pkgs.jq}/bin/jq -s '
        .[0] as $secret | .[1] as $overlay
        | ($secret * $overlay) as $merged
        | $merged
        | .providers = (
            ($merged.providers // {}) as $p
            | ($overlay.providers // {}) as $o
            | ($p | to_entries | map(
                .key as $k
                | if ($o | has($k)) then
                    .value = (
                      $o[$k]
                      + (if ($o[$k] | has("baseUrl")) then {}
                         else (($secret.providers[$k] // {}).baseUrl // null)
                              | if . == null then {} else { baseUrl: . } end
                         end)
                    )
                  else . end
              ) | from_entries)
          )
      ' "$secret" "$overlay" > "$out"
    else
      ${pkgs.coreutils}/bin/cp -- "$secret" "$out"
    fi
    chmod 0600 "$out"
    printf '%s\n' "$want" > "$hash_state"
  '';
in
{
  config = {
    age.identityPaths = [ "${home}/.ssh/id_ed25519" ];
    age.secrets = placed // plain;

    # piModels 与合并 unit 只在启用 pi 模块的用户上存在：未启用者没有
    # ~/.config/pi/models-overlay.json，合并无对象可作用；且其 user session
    # 可能不存在（XDG_RUNTIME_DIR 缺失），跑了只会失败。
    home.packages = lib.optional piEnabled piModels;

    systemd.user.services."agenix-pi-models" = lib.mkIf piEnabled {
      Unit = {
        Description = "merge agenix pi models into ~/.pi/agent/models.json";
        Requires = [ "agenix.service" ];
        After = [ "agenix.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${piModels}/bin/agenix-pi-models";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # 激活期同步跑一次合并（幂等，脚本自带内容哈希守卫）。
    # 为什么需要：上面的 unit 只在 boot 被 default.target 拉起；home-manager
    # switch 对已变更的 user unit 只打印 "systemctl --user restart ..." 提示
    # （modules/systemd-activate.sh 实测），不会重跑 oneshot。于是"改了 overlay
    # 但没改密文"的 switch 会让 ~/.pi/agent/models.json 停留在旧内容。
    # 顺序：entryAfter linkGeneration——此时 home.file 已把新 overlay 软链到位；
    # 再加 agenix-pi-models.service 触发一次渲染让 age 密文解到 /run（首次或
    # boot 后未解的情况）。服务离线时跳过并 WARN，不阻塞激活。
    home.activation.configurePiModels = lib.mkIf piEnabled (config.lib.dag.entryAfter [ "linkGeneration" ] ''
      set -euo pipefail
      export PATH='/etc/profiles/per-user/${config.snowfallorg.user.name}/bin:/run/current-system/sw/bin:$PATH'
      # XDG_RUNTIME_DIR 兜底（同 piModels 脚本内的说明）：home-manager 的
      # hm-setup-env 只在 user session 存在时才导出它，而本步骤也可能在无
      # session 时执行（无 session 的用户 / Linger=no 的用户在开机早期）。
      XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      export XDG_RUNTIME_DIR
      if systemctl --user is-system-running 2>/dev/null | grep -qE '^(running|degraded)$'; then
        # 幂等触发：seed 已解密则本命令立即成功返回
        systemctl --user start agenix-pi-models.service 2>/dev/null || true
      fi
      if [ -f "${config.age.secrets."agents/pi/models.json".path}" ]; then
        ${piModels}/bin/agenix-pi-models
      else
        echo "WARN: pi models secret 未解密（user systemd 离线？）；跳过 ~/.pi/agent/models.json 合并"
      fi
    '');
  };
}
