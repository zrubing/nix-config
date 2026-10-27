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
# 把任意文本文件加密后投放到对象存储，并返回一个短时效的取件链接。
#
# 双重限制彼此独立：age 加密保证只有持钥方可读；签名链接保证过期即废。
# 即使链接被旁观者拿到并保存，得到的也只是密文。
#
# 读取端要求：消费方要认得 age armor（`-----BEGIN AGE ENCRYPTED FILE-----`），
# 并能拿到对应私钥。不具备这两个条件时，加密内容等同于乱码。
#
# 位置信息一律不写进本文件：bucket、endpoint 从环境变量或参数取，对象名
# 随机生成。
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
    TTL="''${HANDOFF_TTL:-600}"
    PREFIX="''${HANDOFF_PREFIX:-tmp}"

    usage() {
      cat <<'EOF'
    handoff - 加密投递一个文件，返回短时效取件链接

    用法:
      handoff <文件路径 | URL> [选项]

    选项:
      -b, --bucket <名>      对象存储 bucket（默认读 HANDOFF_BUCKET）
      -e, --endpoint <域名>  存储 endpoint（默认读 HANDOFF_ENDPOINT）
      -p, --profile <名>     凭证 profile（默认 self）
      -t, --ttl <秒>         链接有效期，默认 600（10 分钟）
      --prefix <前缀>        对象路径前缀，默认 tmp
      -n, --name <名>        对象名（默认随机）
      -h, --help             显示本帮助

    示例:
      handoff ./config.yaml -b mybucket -t 600
      handoff https://example.com/list.txt -b mybucket

    环境变量:
      HANDOFF_BUCKET / HANDOFF_ENDPOINT / HANDOFF_PROFILE / HANDOFF_TTL
      HANDOFF_PREFIX / HANDOFF_RECIPIENT

    取回私钥（交给接收方）:
      clan vars get zen14 handoff-key/secret-key
    EOF
    }

    src=""
    objname=""

    while [ $# -gt 0 ]; do
      case "$1" in
        -b|--bucket)   BUCKET="$2"; shift 2 ;;
        -e|--endpoint) ENDPOINT="$2"; shift 2 ;;
        -p|--profile)  PROFILE="$2"; shift 2 ;;
        -t|--ttl)      TTL="$2"; shift 2 ;;
        --prefix)      PREFIX="$2"; shift 2 ;;
        -n|--name)     objname="$2"; shift 2 ;;
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

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    # 1. 取内容
    plain="$workdir/plain"
    case "$src" in
      http://*|https://*)
        curl -fsSL --max-time 60 -A 'Mozilla/5.0' -o "$plain" "$src"
        ;;
      *)
        [ -f "$src" ] || { echo "文件不存在: $src" >&2; exit 1; }
        cp "$src" "$plain"
        ;;
    esac

    [ -s "$plain" ] || { echo "输入内容为空，已中止" >&2; exit 1; }

    # 2. age 加密。用消费方同款实现，保证格式（armor）能被其识别。
    enc="$workdir/enc"
    mihomo age encrypt "$RECIPIENT" "$plain" "$enc"

    head -n1 "$enc" | grep -q '^-----BEGIN AGE ENCRYPTED FILE-----$' \
      || { echo "加密输出不是 age armor，已中止" >&2; exit 1; }

    # 3. 对象名默认随机：不含扩展名、不含语义词，避免从 URL 反推内容性质
    if [ -z "$objname" ]; then
      objname="$(openssl rand -hex 10).dat"
    fi
    objkey="$PREFIX/$objname"

    # 4. 上传。对象保持私有，访问只靠下面的签名链接。
    aliyun --profile "$PROFILE" oss cp "$enc" "oss://$BUCKET/$objkey" \
      -e "$ENDPOINT" -f >/dev/null

    # 5. 生成签名链接。Expires 由 CLI 按 TTL 换算成绝对时间戳。
    url="$(aliyun --profile "$PROFILE" oss sign "oss://$BUCKET/$objkey" \
      -e "$ENDPOINT" --timeout "$TTL" 2>/dev/null \
      | grep -o 'https://[^[:space:]]*Signature[^[:space:]]*' | head -n1)"

    [ -n "$url" ] || { echo "签名链接生成失败" >&2; exit 1; }

    # 链接走 stdout（便于命令替换），其余提示走 stderr
    printf '%s\n' "$url"
    {
      printf '\n'
      printf '对象     : oss://%s/%s\n' "$BUCKET" "$objkey"
      printf '有效期   : %s 秒\n' "$TTL"
      printf '解密要求 : 接收方需持有 age 私钥，无则内容不可读\n'
      printf '访问控制 : 对象未设公开读，链接过期后需重新生成\n'
    } >&2
  '';

  meta = {
    description = "加密投递文件并返回短时效取件链接";
    mainProgram = "handoff";
  };
}
