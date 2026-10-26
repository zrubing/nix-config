# 代理节点清单的方言转换器（单一事实源：nix-secrets 的 proxy-nodes.json.age）。
#
# 输入：{ "nodes": [ ... ] }，每个节点是中性定义：
#   hysteria2: { kind, name, server, port, hopPorts{start,end}, password, sni, sibGroups? }
#   socks    : { kind, name, port }          —— 本机 provider 提供的 socks5 上游
#
# 输出：{ sib: [...outbounds], sibGroups: { 组名: [节点名] }, miho: [...proxies] }
# 三家方言差异只在这里收敛：
#   · sib  : server_ports 是 "8900:8990" 区间字符串，socks 用 type=socks
#   · miho : ports 是 "8901-8990"，socks 用 type=socks5
#
# 为什么在运行时跑而不是 nix 求值：节点清单是敏感的（server/密码/SNI），
# 经 nix 求值就会变成世界可读的 /nix/store 文件。这里只让「转换逻辑」进 store。

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
  else
    error("proxy-nodes: 未知 kind \(.kind)（节点 \(.name // "?")）")
  end;

.nodes as $nodes
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
