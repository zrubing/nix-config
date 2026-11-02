{
  writeShellApplication,
  aliyun-cli,
  curl,
  coreutils,
  openssl,
  callPackage,
}:

let
  # 必须用仓库内这份mihomo：nixpkgs 里的是 1.19.24，没有 age 子命令，
  # 传入 `age encrypt ...` 会被当成普通参数直接拉起完整服务并挂住。
  mihomo = callPackage ../mihomo { };
in
# 把任意文本文件加密后投放到对象存储，并返回一个取件链接。
#
# 双重限制彼此独立：age 加密保证只有持钥方可读；签名链接保证过期即废。
# 即使链接被旁观者拿到并保存，得到的也只是密文。
#
# 支持两种时效：
#   · 默认按固定到期日（DEFAULT_EXPIRE_AT）签名。对象名与到期日都不变时，
#     Expires 与 Signature 完全可复现，输出的是同一条 URL —— 重复投递只
#     覆盖对象内容，接收方手里的链接不用换。
#   · 显式 `-t` 按相对时长签名，用于临时投递。
#
# 读取端要求：消费方要认得 age armor（`-----BEGIN AGE ENCRYPTED FILE-----`），
# 并能拿到对应私钥。不具备这两个条件时，加密内容等同于乱码。
#
# 位置信息一律不写进本文件：bucket、endpoint 从环境变量或参数取，对象名
# 随机生成或由调用方指定。
writeShellApplication {
  name = "handoff";

  runtimeInputs = [
    mihomo
    aliyun-cli
    curl
    coreutils
    openssl
  ];

  text = ''
    # 接收方公钥。公钥只能用于加密，泄露不会使既有内容失守，因此可以固化。
    RECIPIENT="''${HANDOFF_RECIPIENT:-age1g3rs9f3ad7m5hqhf0w5vfy02qa0wnf0shv8km0mhtfaawer5jv0q9mkkwg}"

    BUCKET="''${HANDOFF_BUCKET:-}"
    ENDPOINT="''${HANDOFF_ENDPOINT:-oss-cn-beijing.aliyuncs.com}"
    PROFILE="''${HANDOFF_PROFILE:-self}"
    PREFIX="''${HANDOFF_PREFIX:-tmp}"

    # 默认到期日。固定值让「同对象名 + 同到期日」的签名可复现：Expires 相同，
    # 签名相同，链接逐字节不变。到期后这里直接报错，不会静默退回短时效。
    # 需要换日期时改这一行（或用 HANDOFF_EXPIRE_AT / --expire-at 临时覆盖）。
    DEFAULT_EXPIRE_AT="2027-10-30"
    EXPIRE_AT="''${HANDOFF_EXPIRE_AT:-$DEFAULT_EXPIRE_AT}"

    usage() {
      cat <<'EOF'
    handoff - 加密投递一个文件，返回取件链接

    用法:
      handoff <文件路径 | URL | -> [选项]

    位置参数写 `-` 表示从标准输入读，便于管道：
      some-generator --stdout | handoff - -n cfg.age

    选项:
      -b, --bucket <名>      对象存储 bucket（默认读 HANDOFF_BUCKET）
      -e, --endpoint <域名>  存储 endpoint（默认读 HANDOFF_ENDPOINT）
      -p, --profile <名>     凭证 profile（默认 self）
      -t, --ttl <时长>       相对当前时间的有效期，如 600 / 10m / 12h / 30d / 1y
      --expire-at <日期>     绝对到期日，YYYY-MM-DD 表示当天 23:59:59，
                             也接受 date -d 能解析的完整时间
      --prefix <前缀>        对象路径前缀，默认 tmp
      -n, --name <名>        对象名（默认随机）
      --plain                不加密，直接投放原文
      -h, --help             显示本帮助

    时效（两种模式互斥）:
      默认按固定到期日签名（内置 2027-10-30，可用 HANDOFF_EXPIRE_AT 覆盖）。
      同一对象名 + 同一到期日 → 同一 URL，重复投递只更新内容，链接不变。
      -t 按相对时长签名，每次生成的 Expires 会顺延，适合一次性投递。

    稳定性:
      OSS V1 签名只覆盖资源路径与 Expires，不覆盖内容。因此覆盖同名对象后，
      旧链接在到期前一直有效，读到的就是新内容。链接到期、对象被删、bucket
      改成公共读、AK 被禁用/轮换，都会让链接立即失效。

    --plain 的取舍:
      不加密时内容对任何拿到链接的人都是明文，安全性完全靠两层外部约束——
      对象 private（无签名不可访问）+ 链接短时效。有效期超过 7 天时本工具
      直接拒绝 --plain，避免把一个长期可读的明文地址发出去。

    示例:
      # 固定链接：首次生成后保存 URL；以后重复这条命令即可更新内容
      some-generator --stdout | handoff - -n cfg.age
      # 一次性投递，10 分钟
      some-generator --stdout | handoff - -t 600
      # 精确到期日
      handoff ./cfg.age -n cfg.age --expire-at 2027-12-31

    环境变量:
      HANDOFF_BUCKET / HANDOFF_ENDPOINT / HANDOFF_PROFILE
      HANDOFF_PREFIX / HANDOFF_RECIPIENT / HANDOFF_EXPIRE_AT

    取回私钥（交给接收方）:
      clan vars get zen14 handoff-key/secret-key
    EOF
    }

    # 把相对时长换算成秒。纯数字按秒；后缀 y/d/h/m/s 分别为
    # 365 天、天、时、分、秒。不接受小数。
    parse_ttl() {
      local v="$1" num unit
      case "$v" in
        *y) num="''${v%y}"; unit=31536000 ;;
        *d) num="''${v%d}"; unit=86400 ;;
        *h) num="''${v%h}"; unit=3600 ;;
        *m) num="''${v%m}"; unit=60 ;;
        *s) num="''${v%s}"; unit=1 ;;
        *)  num="$v"; unit=1 ;;
      esac
      case "$num" in
        '''|*[!0-9]*) return 1 ;;
      esac
      [ "$num" -gt 0 ] || return 1
      printf '%s' "$(( num * unit ))"
    }

    # 解析绝对到期日，输出 Unix 秒。纯日期补到当天 23:59:59；GNU date 对
    # 2027-02-30 这类非法日期会顺延，回读校验把它拦住。
    parse_expire_at() {
      local v="$1" e
      case "$v" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
          e="$(date -d "$v 23:59:59" +%s 2>/dev/null)" || return 1
          [ "$(date -d "@$e" +%F)" = "$v" ] || return 1
          ;;
        *)
          e="$(date -d "$v" +%s 2>/dev/null)" || return 1
          ;;
      esac
      [ -n "$e" ] || return 1
      printf '%s' "$e"
    }

    src=""
    objname=""
    name_given=0
    encrypt=1
    explicit_expire_at=""
    ttl_given=0
    ttl=""

    while [ $# -gt 0 ]; do
      case "$1" in
        # 单独的 `-` 是位置参数（表示 stdin），必须排在 `-*` 前面，
        # 否则 `-*` 会先匹配上并报“未知选项”。
        -)             src="$1"; shift ;;
        -b|--bucket)   BUCKET="$2"; shift 2 ;;
        -e|--endpoint) ENDPOINT="$2"; shift 2 ;;
        -p|--profile)  PROFILE="$2"; shift 2 ;;
        -t|--ttl)      ttl="$2"; ttl_given=1; shift 2 ;;
        --expire-at)   explicit_expire_at="$2"; shift 2 ;;
        --prefix)      PREFIX="$2"; shift 2 ;;
        -n|--name)     objname="$2"; name_given=1; shift 2 ;;
        --plain)       encrypt=0; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "未知选项: $1" >&2; usage >&2; exit 2 ;;
        *)             src="$1"; shift ;;
      esac
    done

    if [ -z "$src" ]; then
      echo "缺少输入：请给出文件路径或 URL" >&2
      usage >&2
      exit 2
    fi

    if [ -z "$BUCKET" ]; then
      echo "未指定 bucket：用 -b 或设置 HANDOFF_BUCKET" >&2
      exit 2
    fi

    if [ -n "$explicit_expire_at" ] && [ "$ttl_given" -eq 1 ]; then
      echo "--expire-at 与 -t 不能同时使用：前者是绝对到期日，后者是相对时长" >&2
      exit 2
    fi

    # 1. 定下到期时间：显式 --expire-at > 显式 -t > 默认固定到期日
    now="$(date +%s)"
    if [ -n "$explicit_expire_at" ]; then
      expires_epoch="$(parse_expire_at "$explicit_expire_at")" \
        || { echo "无法解析到期日: $explicit_expire_at" >&2; exit 2; }
    elif [ "$ttl_given" -eq 1 ]; then
      ttl_seconds="$(parse_ttl "$ttl")" \
        || { echo "无法解析 -t: $ttl（支持 600 / 10m / 12h / 30d / 1y）" >&2; exit 2; }
      expires_epoch=$(( now + ttl_seconds ))
    else
      expires_epoch="$(parse_expire_at "$EXPIRE_AT")" \
        || { echo "无法解析 HANDOFF_EXPIRE_AT: $EXPIRE_AT" >&2; exit 2; }
    fi

    if [ "$expires_epoch" -le "$now" ]; then
      {
        printf '到期日已过: %s\n' "$(date -d "@$expires_epoch" '+%F %T %Z')"
        printf '改本包的 DEFAULT_EXPIRE_AT，或 HANDOFF_EXPIRE_AT / --expire-at；临时投递用 -t\n'
      } >&2
      exit 2
    fi

    horizon=$(( expires_epoch - now ))

    # 长期链接 + 明文 = 长期明文可读。这是唯一需要硬拦的组合。
    if [ "$encrypt" -eq 0 ] && [ "$horizon" -gt 604800 ]; then
      {
        printf '拒绝: --plain 与超过 7 天的有效期不能同时使用\n'
        printf '当前有效期 %s 天；明文只用于临时投递，请显式加 -t 600\n' "$(( horizon / 86400 ))"
      } >&2
      exit 2
    fi

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    # 2. 取内容
    plain="$workdir/plain"
    case "$src" in
      # `-` 与 /dev/stdin 都是管道入口。注意 /dev/stdin 是字符设备，
      # 用 -f 判断会直接当成“文件不存在”，这里不能按普通文件处理。
      -|/dev/stdin|/dev/fd/0)
        cat > "$plain"
        ;;
      http://*|https://*)
        curl -fsSL --max-time 60 -A 'Mozilla/5.0' -o "$plain" "$src"
        ;;
      *)
        [ -f "$src" ] || { echo "文件不存在: $src" >&2; exit 1; }
        cp "$src" "$plain"
        ;;
    esac

    [ -s "$plain" ] || { echo "输入内容为空，已中止" >&2; exit 1; }

    # 3. age 加密（默认）。--plain 时跳过，直接上传原文。
    enc="$workdir/enc"
    if [ "$encrypt" -eq 1 ]; then
      # 用消费方同款实现，保证格式（armor）能被其识别。
      mihomo age encrypt "$RECIPIENT" "$plain" "$enc"
      head -n1 "$enc" | grep -q '^-----BEGIN AGE ENCRYPTED FILE-----$' \
        || { echo "加密输出不是 age armor，已中止" >&2; exit 1; }
    else
      cp "$plain" "$enc"
    fi

    # 4. 对象名默认随机：不含扩展名、不含语义词，避免从 URL 反推内容性质。
    # 固定名字时重复运行会覆盖同名对象，链接指向的内容随之更新。
    if [ -z "$objname" ]; then
      objname="$(openssl rand -hex 10).dat"
    fi
    objkey="$PREFIX/$objname"

    # 5. 上传。对象保持私有，访问只靠下面的签名链接。
    aliyun --profile "$PROFILE" oss cp "$enc" "oss://$BUCKET/$objkey" \
      -e "$ENDPOINT" -f >/dev/null

    # 6. 生成签名链接。V1 签名的 Expires 是绝对时间戳，因此固定到期日
    # 可以让整条 URL 逐字节复现。ossutil 的 --timeout 是相对值，这里换算。
    # 若时钟在两次取秒之间跨过边界，Expires 可能差 1 秒，重试收敛。
    url=""
    got_exp=""
    for _ in 1 2 3 4 5; do
      timeout=$(( expires_epoch - $(date +%s) ))
      [ "$timeout" -gt 0 ] || break

      raw="$(aliyun --profile "$PROFILE" oss sign "oss://$BUCKET/$objkey" \
        -e "$ENDPOINT" --timeout "$timeout" 2>/dev/null || true)"
      url="$(printf '%s' "$raw" | grep -o 'https://[^[:space:]]*' | head -n1 || true)"
      [ -n "$url" ] || continue

      case "$url" in
        *[?\&]Expires=*)
          got_exp="''${url#*Expires=}"
          got_exp="''${got_exp%%&*}"
          ;;
        *) got_exp="" ;;
      esac

      if [ "$got_exp" = "$expires_epoch" ]; then
        break
      fi
      url=""
    done

    [ -n "$url" ] || {
      echo "签名链接生成失败（或 Expires 与目标不一致）" >&2
      exit 1
    }

    # V4 签名的 presign 上限是 7 天（x-oss-expires 1..604800），长期链接
    # 必须走 V1。这里显式断言，避免 CLI 升级后静默退化。
    case "$url" in
      *x-oss-signature-version*)
        {
          printf '签名不是 V1（URL 含 x-oss-signature-version）\n'
          printf 'V4 presign 上限 7 天，无法用于固定到期日；检查 aliyun/ossutil 版本\n'
        } >&2
        exit 1
        ;;
    esac

    printf '%s' "$url" | grep -q '[?&]Expires=' || {
      echo "签名 URL 缺少 Expires 参数，已中止" >&2
      exit 1
    }

    # 链接走 stdout（便于命令替换），其余提示走 stderr
    printf '%s\n' "$url"
    {
      printf '\n'
      printf '对象     : oss://%s/%s\n' "$BUCKET" "$objkey"
      printf '到期     : %s (%s)\n' \
        "$(date -d "@$expires_epoch" '+%F %T %Z')" "$expires_epoch"
      printf '有效期   : %s 天\n' "$(( horizon / 86400 ))"
      printf '解密要求 : %s\n' \
        "$([ "$encrypt" -eq 1 ] && echo '接收方需持有 age 私钥，无则内容不可读' || echo '无（明文，仅靠链接短时效与对象私有保护）')"
      printf '访问控制 : 对象未设公开读，链接过期后需重新生成\n'
      if [ "$name_given" -eq 1 ]; then
        printf '覆盖语义 : 对象名固定，重复投递会覆盖内容；旧链接在到期前读到的是新内容\n'
      else
        printf '提示     : 对象名随机，本次链接只对本次对象有效；要固定链接请加 -n <名>\n'
      fi
      printf '链接稳定 : 同对象名 + 同到期日 → 同一 URL（Expires 与签名可复现）\n'
      if [ "$encrypt" -eq 1 ]; then
        # 打印的是取私钥的命令，不是私钥本身——命令不含敏感值，可以直接截图/转发。
        printf '取私钥   : clan vars get zen14 handoff-key/secret-key\n'
      fi
    } >&2
  '';

  meta = {
    description = "加密投递文件并返回取件链接（支持固定到期日）";
    mainProgram = "handoff";
  };
}
