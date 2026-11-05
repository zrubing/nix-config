#!/usr/bin/env bash
# 节点一致性检查：部署前把「删了节点但别处还引用」这类问题挖出来。
#
# 节点清单拆成两半之后（见 lib/proxy-nodes-merge.jq 头注释），派生链是：
#   meta（明文）+ creds（密文） → 合并 → 转换器 → sib 出站/组、mihomo proxies、
#   直连地址表、tuic-client 实例。因此这里检查的是「派生链的各环是否闭合」：
#   1. 节点名唯一
#   2. 节点声明的 sibGroups 组在 sib base 里存在
#   3. sib base 里手写的成员（组/直连之外）都能在节点清单里找到
#   4. 转换器产出的 sib 组成员，每个都能在它产出的 sib 出站里找到
#   5. relay 引用的密文文件存在（实例已由 meta 派生，端口不再单独校验）
#   6. creds 里没有 meta 已经不用的残留条目
#   7. 密文地址表里没有已经由派生覆盖的节点地址（否则退役会留下走不到的项）
#
# 用法：
#   scripts/check-nodes.sh
#   MYSECRETS=~/elsewhere/nix-secrets scripts/check-nodes.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSECRETS="${MYSECRETS:-$HOME/codeWorkspace/nix-secrets}"
AGE_KEY="${NODE_AGE_KEY:-$HOME/.ssh/id_ed25519}"

# age / yq / jq 不在默认 PATH 里：用 nix shell 重新执行自己
if ! command -v age >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  exec nix shell nixpkgs#age nixpkgs#jq nixpkgs#yq-go -c "$0" "$@"
fi

[[ -d "$MYSECRETS" ]] || { echo "找不到 mysecrets：$MYSECRETS" >&2; exit 2; }
[[ -f "$AGE_KEY" ]] || { echo "找不到解密私钥：$AGE_KEY" >&2; exit 2; }
[[ -f "$MYSECRETS/proxy-nodes.meta.json" ]] || { echo "找不到 meta：$MYSECRETS/proxy-nodes.meta.json" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dec() { age -d -i "$AGE_KEY" "$MYSECRETS/$1" > "$tmp/$2"; }

dec proxy-nodes.creds.json.age creds.json
dec sib-conf/zen14.json.age sib.json
dec net-policy-addresses.json.age addr.json

# meta（在不在）+ creds（连哪里）→ 与主机 prepare 完全相同的合并逻辑。
jq -f "$REPO/lib/proxy-nodes-merge.jq" --slurpfile c "$tmp/creds.json" \
  "$MYSECRETS/proxy-nodes.meta.json" > "$tmp/nodes.json"

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  warn %s\n' "$*"; }

echo "== 节点清单 =="
# 展开 -v6 派生腿后的有效名字
jq -r '.nodes[] | .name, (if (.server6 // null) != null then .name + "-v6" else empty end)' \
  "$tmp/nodes.json" | sort -u > "$tmp/names"
node_count="$(jq '.nodes | length' "$tmp/nodes.json")"
ok "节点 $node_count 个，展开后出站 $(wc -l < "$tmp/names") 个"

dups="$(jq -r '.nodes[].name' "$tmp/nodes.json" | sort | uniq -d)"
[[ -z "$dups" ]] && ok "节点名唯一" || bad "节点名重复：$dups"

echo "== sibGroups → sib base 组 =="
missing_groups="$(jq -r --slurpfile s "$tmp/sib.json" '
  ([$s[0].outbounds[].tag]) as $tags
  | .nodes[] as $n
  | ($n.sibGroups // [])[]
  | select(($tags | index(.)) == null)
  | "\($n.name) -> \(.)"
' "$tmp/nodes.json")"
[[ -z "$missing_groups" ]] && ok "所有 sibGroups 都能在 base 里找到" || bad "sibGroups 指向不存在的组：
$missing_groups"

echo "== 转换器的 sib 组 → sib 出站 =="
# 第 2 条只查组名；这里查成员。sib 没有某些传输（vless-xhttp），转换器对那类节点
# 不产出 sib 出站 —— 若组成员仍按全部节点收集，prepare 的引用检查会以
# 「组 X → 不存在的出站 Y」失败，整个 sing-box 起不来（2026-11-05 nova13 实测）。
conv_dangling="$(jq -f "$REPO/lib/proxy-nodes.jq" --slurpfile addr "$tmp/addr.json" "$tmp/nodes.json" | jq -r '
  ([.sib[].tag]) as $tags
  | .sibGroups | to_entries[]
  | .key as $g
  | .value[] as $m
  | select(($tags | index($m)) == null)
  | "\($g) -> \($m)"
')"
[[ -z "$conv_dangling" ]] \
  && ok "sib 组里的成员都有对应的 sib 出站" \
  || bad "sib 组引用了 sib 里不存在的出站（sing-box 会拒绝启动）：
$conv_dangling"

echo "== sib base 里的手写成员 =="
# base 里 selector/urltest 的成员，除去「组标签」和「直连」，都应当是节点名
orphan_members="$(jq -r --slurpfile n "$tmp/nodes.json" '
  ([ $n[0].nodes[].name ]) as $names
  | ([.outbounds[].tag]) as $tags
  | .outbounds[]
  | select(.type == "selector" or .type == "urltest")
  | .tag as $g
  | (.outbounds // [])[]
  | select(($tags | index(.)) == null and . != "直连")
  | select(($names | index(.)) == null)
  | "\($g) -> \(.)"
' "$tmp/sib.json")"
if [[ -z "$orphan_members" ]]; then
  ok "没有指向不存在节点的成员"
else
  bad "base 里引用了节点清单里没有的名字：
$orphan_members"
fi

echo "== tuic 实例（由 meta 派生）=="
# 实例与 unit 的对应关系现在是结构性的：tuic-client 模块直接读同一份 meta，
# 所以这里只剩「引用的密文在不在」与「creds 有没有退役残留」两件事可查。
relay_refs="$(jq -r '.nodes[] | select(.relay != null) | .relay | (.serverSecret, (.ipSecret // empty))' "$tmp/nodes.json" | sort -u)"
missing_secret=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  [[ -f "$MYSECRETS/$ref.age" ]] || { bad "meta 引用了不存在的密文 $ref.age（tuic-client 会起不来）"; missing_secret=1; }
done <<<"$relay_refs"
(( missing_secret )) || ok "relay 密文都存在"

stale_creds="$(jq -r --slurpfile m "$MYSECRETS/proxy-nodes.meta.json" '
  ([ $m[0].nodes[].name ]) as $meta
  | .nodes | keys[] | select(($meta | index(.)) == null)
' "$tmp/creds.json")"
if [[ -z "$stale_creds" ]]; then
  ok "creds 里没有退役残留"
else
  warn "以下 creds 条目已无对应 meta（退役后忘了清，可删）：
$(sed 's/^/    /' <<<"$stale_creds")"
fi

# relay 只在 meta 里（合并进转换器输入时会被丢掉），所以这里读 meta。
socks_other="$(jq -r '.nodes[] | select(.kind == "socks" and .enabled != false) | select(.relay == null) | "\(.name)\t\(.port)"' "$MYSECRETS/proxy-nodes.meta.json")"
if [[ -n "$socks_other" ]]; then
  warn "以下 socks 节点由 xray-client 提供（端口写死在 xray 密文里，本检查不覆盖）：
$(sed 's/^/    /' <<<"$socks_other")"
fi

echo "== 直连地址表（节点部分由转换器派生）=="
# 转换器把节点 server 自动并入 directCidrs/directDomains；密文表里若还手写着
# 同一批值，就是退役后会留下「走不到的项」的那种重复。
overlap="$(jq -r --slurpfile a "$tmp/addr.json" '
  ((($a[0].directCidrs) // []) + (($a[0].directDomains) // [])) as $listed
  | [ .nodes[] | (.server // empty), (.server6 // empty) | select(. != null) ] as $servers
  | $servers[]
  | . as $s
  | if test("^[0-9.]+$") then "\($s)/32" elif test(":") then "\($s)/128" else $s end
  | . as $v
  | select(($listed | index($v)) != null)
' "$tmp/nodes.json" | sort -u)"
if [[ -z "$overlap" ]]; then
  ok "密文地址表里没有重复的节点地址"
else
  warn "以下节点地址已由派生覆盖，密文表里的同名条目可以删（多了不会报错，但退役会残留）：
$(sed 's/^/    /' <<<"$overlap")"
fi

echo
if (( fail )); then
  echo "有不一致项，不要部署。" >&2
  exit 1
fi
echo "全部通过。"
