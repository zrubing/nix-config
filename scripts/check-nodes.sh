#!/usr/bin/env bash
# 节点一致性检查：部署前把「删了节点但别处还引用」这类问题挖出来。
#
# 检查的是四份运行时密文 + 两台主机的 tuic-client 实例声明之间的一致性：
#   1. 节点名唯一
#   2. 节点声明的 sibGroups 组在 sib base 里存在
#   3. sib base 里手写的成员（组/直连之外）都能在节点清单里找到
#   4. socks 节点的端口 ↔ tuic-client 实例的 listen 一一对应
#   5. tuic-client 引用的 relay 密文文件存在
#   6. 节点的 IP 字面量都出现在 net-policy 的 directCidrs 里
#
# 用法：
#   scripts/check-nodes.sh
#   MYSECRETS=~/elsewhere/nix-secrets scripts/check-nodes.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSECRETS="${MYSECRETS:-$HOME/codeWorkspace/nix-secrets}"
AGE_KEY="${NODE_AGE_KEY:-$HOME/.ssh/id_ed25519}"

# age / yq 不在默认 PATH 里：用 nix shell 重新执行自己
if ! command -v age >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  exec nix shell nixpkgs#age nixpkgs#jq nixpkgs#yq-go -c "$0" "$@"
fi

[[ -d "$MYSECRETS" ]] || { echo "找不到 mysecrets：$MYSECRETS" >&2; exit 2; }
[[ -f "$AGE_KEY" ]] || { echo "找不到解密私钥：$AGE_KEY" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dec() { age -d -i "$AGE_KEY" "$MYSECRETS/$1" > "$tmp/$2"; }

dec proxy-nodes.json.age nodes.json
dec sib-conf/zen14.json.age sib.json
dec net-policy-addresses.json.age addr.json

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

echo "== socks 节点 ↔ tuic-client 实例 =="
: > "$tmp/instances"
for h in zen14 nova13; do
  nix eval --json "$REPO#nixosConfigurations.$h.config.internal.tuic-client.instances" \
    --apply 'i: builtins.mapAttrs (n: v: { inherit (v) serverSecret ipSecret listen; }) i' \
    > "$tmp/$h.json" 2>/dev/null || { warn "eval $h 失败，跳过该主机"; continue; }
  jq -r --arg h "$h" 'to_entries[] | "\($h)\t\(.key)\t\(.value.listen | split(":") | .[-1])\t\(.value.serverSecret)\t\(.value.ipSecret // "-")"' \
    "$tmp/$h.json" >> "$tmp/instances"
done

# socks 节点有两类提供者：tuic-client（名字带 tuic）和 xray-client（xhttp/reality，
# 端口 1086/1087 写死在 xray 密文里）。这里只校验 tuic 那一类。
jq -r '.nodes[] | select(.kind == "socks") | select(.name | test("tuic")) | "\(.name)\t\(.port)"' \
  "$tmp/nodes.json" | sort -k2 > "$tmp/socks"
jq -r '.nodes[] | select(.kind == "socks") | select(.name | test("tuic") | not) | "\(.name)\t\(.port)"' \
  "$tmp/nodes.json" > "$tmp/socks_other"

cut -f3 "$tmp/instances" | sort -u > "$tmp/instance_ports"
cut -f2 "$tmp/socks" | sort -u > "$tmp/sock_ports"

missing_instance="$(comm -23 "$tmp/sock_ports" "$tmp/instance_ports")"
extra_instance="$(comm -13 "$tmp/sock_ports" "$tmp/instance_ports")"
if [[ -z "$missing_instance" ]]; then
  ok "每个 socks 节点都有 tuic-client 实例"
else
  bad "socks 节点没有对应的 tuic-client 实例（端口）：$missing_instance"
fi
if [[ -z "$extra_instance" ]]; then
  ok "每个 tuic-client 实例都有 socks 节点"
else
  bad "tuic-client 实例没有对应的 socks 节点（端口）：$extra_instance"
fi
if [[ -s "$tmp/socks_other" ]]; then
  warn "以下 socks 节点由 xray-client 提供，本检查不覆盖其端口：
$(sed 's/^/    /' "$tmp/socks_other")"
fi

echo "== tuic-client 引用的密文 =="
missing_secret=0
while IFS=$'\t' read -r h name port server ip; do
  for ref in "$server" "$ip"; do
    [[ "$ref" == "-" ]] && continue
    [[ -f "$MYSECRETS/$ref.age" ]] || { bad "$h/$name 引用不存在的密文 $ref.age"; missing_secret=1; }
  done
done < "$tmp/instances"
(( missing_secret )) || ok "relay 密文都存在"

echo "== 节点 IP 字面量 → directCidrs =="
# 只看 IP 字面量；域名形式的 server 需要人工确认其解析结果也在表里
jq -r --slurpfile a "$tmp/addr.json" '
  ($a[0].directCidrs // []) as $c
  | .nodes[]
  | (.server // empty), (.server6 // empty)
  | select(. != null and . != "127.0.0.1")
  | . as $ip
  | if test("^[0-9.]+$") then "\($ip)/32"
    elif test(":") then "\($ip)/128"
    else empty end
  | select(($c | index(.)) == null)
' "$tmp/nodes.json" > "$tmp/missing_addr"
if [[ -s "$tmp/missing_addr" ]]; then
  bad "以下节点地址不在 directCidrs 里：
$(sed 's/^/    /' "$tmp/missing_addr")"
else
  ok "所有 IP 字面量都在 directCidrs 里"
fi
hostname_servers="$(jq -r '.nodes[] | (.server // empty) | select(test("^[0-9.]+$") | not) | select(test(":") | not) | select(. != "127.0.0.1")' "$tmp/nodes.json" | sort -u)"
if [[ -n "$hostname_servers" ]]; then
  warn "以下节点的 server 是域名，directCidrs 需要人工确认解析结果：
$(sed 's/^/    /' <<<"$hostname_servers")"
fi

echo
if (( fail )); then
  echo "检查失败：先修上面的 FAIL 再部署。"
  exit 1
fi
echo "全部通过。"
