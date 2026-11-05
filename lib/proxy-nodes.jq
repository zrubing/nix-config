# 代理节点清单的方言转换器（单一事实源：nix-secrets 的 proxy-nodes.json.age）。
#
# 输入：{ "nodes": [ ... ] }，每个节点是中性定义：
#   hysteria2: { kind, name, server, server6?, port, hopPorts{start,end}, password, sni, sibGroups? }
#   vless-reality: { kind, name, server, port, uuid, publicKey, shortId?, sni, sibGroups? }
#   socks    : { kind, name, port }          —— 本机 provider 提供的 socks5 上游
#   vless-xhttp: { kind, name, server, port, uuid, sni, alpn?, fingerprint?, xhttpOpts, sibGroups? }
#              —— mihomo 原生 xhttp；sing-box 不支持该传输，sib 侧会跳过
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
    # flow 必须与服务端一致：服务端没配就不要写，配了就必须带，否则握手失败。
    require("port") | require("uuid") | require("publicKey") | require("sni")
    | {
        type: "vless",
        tag: .name,
        server: .server,
        server_port: .port,
        uuid: .uuid,
        flow: (.flow // null),
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
    | with_entries(select(.value != null))
  elif .kind == "vless-xhttp" then
    # sing-box 的 V2Ray transport 只有 http/ws/quic/grpc/httpupgrade，没有 xhttp。
    # 这类节点在 sib 上继续走清单里那条 socks（本机 xray-client），这里跳过。
    empty
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
        flow: (.flow // null),
        "client-fingerprint": "chrome",
        "reality-opts": ({
          "public-key": .publicKey,
          "short-id": (.shortId // ""),
          # 新版 Xray 服务端要求客户端带 ML-KEM key share，只发纯 X25519 时
          # 服务端解不开 sessionId（日志 processed invalid connection）。
          # 旧服务端如果不认，就不要给那条节点设 mlkem。
          "support-x25519mlkem768": (if .mlkem then true else null end)
        } | with_entries(select(.value != null)))
      }
    | with_entries(select(.value != null))
  elif .kind == "vless-xhttp" then
    require("port") | require("uuid") | require("xhttpOpts")
    | {
        name: .name,
        type: "vless",
        server: .server,
        port: .port,
        uuid: .uuid,
        network: "xhttp",
        tls: true,
        udp: true,
        servername: .sni,
        alpn: .alpn,
        "client-fingerprint": (.fingerprint // "chrome"),
        "xhttp-opts": .xhttpOpts
      }
    | with_entries(select(.value != null))
  else
    error("proxy-nodes: 未知 kind \(.kind)（节点 \(.name // "?")）")
  end;

.nodes as $raw
| ($raw | map(expand_v6) | add) as $nodes
| ($nodes | map(sib_outbound)) as $sib
| ($sib | map(.tag)) as $sibTags
| {
    sib: $sib,
    # 组名 → 成员列表。按节点顺序追加，不排序：selector 的默认项是列表第一项。
    #
    # 成员只取「真的产出了 sib 出站」的节点。有的 kind 在 sib 没有对应传输
    # （vless-xhttp），sib_outbound 对它是 empty；这时若还把名字写进组，
    # sib-prepare 末尾的引用检查会以「组 X → 不存在的出站 Y」失败，服务起不来
    # （2026-11-05 nova13 实测：组 全部节点 → 美-1-vless-xhttp-native）。
    #
    # 判据直接取 $sib 的 tag 列表，不在这里重述「哪些 kind 能进 sib」—— 那会成为
    # 第二份事实源，下次新增 kind 时又要同步一次，而漏掉同步的后果就是上面那条。
    sibGroups: (
      reduce ($nodes[] | select(.name as $n | $sibTags | index($n))) as $n ({};
        reduce ($n.sibGroups // [])[] as $g (.;
          .[$g] = ((.[$g] // []) + [$n.name])
        )
      )
    ),
    miho: ($nodes | map(miho_proxy))
  }
