# 代理节点清单的方言转换器（单一事实源：nix-secrets 的 proxy-nodes.json.age）。
#
# 输入：{ "nodes": [ ... ] }，每个节点是中性定义：
#   hysteria2: { kind, name, server, server6?, port, hopPorts{start,end}, password, sni, sibGroups? }
#   vless-reality: { kind, name, server, port, uuid, publicKey, shortId?, sni, sibGroups? }
#   socks    : { kind, name, port }          —— 本机 provider 提供的 socks5 上游
#
# 输出：{ sib: [...outbounds], sibGroups: { 组名: [节点名] }, miho: [...proxies] }
# 三家方言差异只在这里收敛：
#   · sib  : server_ports 是 "8900:8990" 区间字符串，socks 用 type=socks
#   · miho : ports 是 "8901-8990"，socks 用 type=socks5
#
# 为什么在运行时跑而不是 nix 求值：节点清单是敏感的（server/密码/SNI），
# 经 nix 求值就会变成世界可读的 /nix/store 文件。这里只让「转换逻辑」进 store。

# 带 server6 的节点额外派生一个 v6 出站：同一节点、同一份凭据，只是 server 换成
# v6 字面量；名字加 -v6 后缀，sibGroups 原样继承（所以会自动进「自动选择」等组）。
#
# 为什么不用「域名 + domain_resolver.strategy=prefer_ipv6」派生：那只是换解析偏好，
# 出站仍然只有一条链路——v4 挂了也走 v6，反过来 v6 挂了也回不来。两个独立出站 +
# urltest，才能让「哪族活着就用哪族」由测速决定。
# 实测依据（2026-10-27）：屏蔽某节点的 v4 后 45 秒，QUIC 出站 0 次尝试 v6——
# 它不会替你换族（QUIC/UDP 也没有 TCP 那种 Happy Eyeballs）。
def expand_v6:
  if (.server6 // null) == null then [ . ]
  else [ ., (. + { name: (.name + "-v6"), server: .server6 }) ]
  end;

def require($f):
  if has($f) and .[$f] != null then .
  else error("proxy-nodes: 节点 \(.name // "?") 缺少字段 \($f)")
  end;

def sib_outbound:
  if .kind == "hysteria2" then
    require("server") | require("hopPorts") | require("password") | require("sni")
    | {
        type: "hysteria2",
        tag: .name,
        server: .server,
        server_ports: ["\(.hopPorts.start):\(.hopPorts.end)"],
        password: .password,
        tls: { enabled: true, server_name: .sni }
      }
  elif .kind == "socks" then
    require("port")
    | { type: "socks", tag: .name, server: "127.0.0.1", server_port: .port }
  elif .kind == "vless-reality" then
    # 服务端没配 flow，这里也不设（两边必须一致，否则握手失败）。
    require("port") | require("uuid") | require("publicKey") | require("sni")
    | {
        type: "vless",
        tag: .name,
        server: .server,
        server_port: .port,
        uuid: .uuid,
        tls: {
          enabled: true,
          server_name: .sni,
          utls: { enabled: true, fingerprint: "chrome" },
          reality: {
            enabled: true,
            public_key: .publicKey,
            short_id: (.shortId // "")
          }
        }
      }
  else
    error("proxy-nodes: 未知 kind \(.kind)（节点 \(.name // "?")）")
  end;

def miho_proxy:
  if .kind == "hysteria2" then
    require("server") | require("port") | require("hopPorts") | require("password")
    | {
        name: .name,
        type: "hysteria2",
        server: .server,
        port: .port,
        ports: "\(.hopPorts.start)-\(.hopPorts.end)",
        password: .password
      }
      + (if .sni != null then { sni: .sni } else {} end)
  elif .kind == "socks" then
    require("port")
    | { name: .name, type: "socks5", server: "127.0.0.1", port: .port }
  elif .kind == "vless-reality" then
    require("port") | require("uuid") | require("publicKey") | require("sni")
    | {
        name: .name,
        type: "vless",
        server: .server,
        port: .port,
        uuid: .uuid,
        network: "tcp",
        tls: true,
        servername: .sni,
        udp: true,
        "client-fingerprint": "chrome",
        "reality-opts": {
          "public-key": .publicKey,
          "short-id": (.shortId // "")
        }
      }
  else
    error("proxy-nodes: 未知 kind \(.kind)（节点 \(.name // "?")）")
  end;

.nodes as $raw
| ($raw | map(expand_v6) | add) as $nodes
| {
    sib: ($nodes | map(sib_outbound)),
    # 组名 → 成员列表。按节点顺序追加，不排序：selector 的默认项是列表第一项。
    sibGroups: (
      reduce $nodes[] as $n ({};
        reduce ($n.sibGroups // [])[] as $g (.;
          .[$g] = ((.[$g] // []) + [$n.name])
        )
      )
    ),
    miho: ($nodes | map(miho_proxy))
  }
