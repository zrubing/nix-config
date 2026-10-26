# 把 mysecrets/proxy-nodes.nix 的节点清单渲染成两家客户端各自要的形状。
#
# 单一事实源在私有仓（节点域名/地址不能进公开仓）；这里只做「方言转换」：
#   · sib（sing-box）：server_ports 用 "8900:8990" 区间字符串，socks 用 type=socks
#   · miho（mihomo） ：ports 用 "8901-8990"，socks 用 type=socks5
#
# 分组：sib 的分组是显式列表（这里按节点的 sibGroups 汇总，渲染时补进去）；
# miho 的分组用 include-all + filter 自动匹配节点名，不需要额外数据。
{ lib, mysecrets }:
let
  nodes = (import "${mysecrets}/proxy-nodes.nix").nodes;

  assertField =
    n: field:
    if n ? ${field} then
      n.${field}
    else
      throw "proxy-nodes: 节点 ${n.name} 缺少字段 ${field}";

  toSib =
    n:
    if n.kind == "hysteria2" then
      {
        type = "hysteria2";
        tag = n.name;
        server = assertField n "server";
        server_ports = [
          "${toString n.hopPorts.start}:${toString n.hopPorts.end}"
        ];
        password = assertField n "password";
        tls = {
          enabled = true;
          server_name = assertField n "sni";
        };
      }
    else if n.kind == "socks" then
      {
        type = "socks";
        tag = n.name;
        server = "127.0.0.1";
        server_port = assertField n "port";
      }
    else
      throw "proxy-nodes: 未知 kind ${n.kind}（节点 ${n.name}）";

  toMiho =
    n:
    if n.kind == "hysteria2" then
      {
        name = n.name;
        type = "hysteria2";
        server = assertField n "server";
        port = assertField n "port";
        ports = "${toString n.hopPorts.start}-${toString n.hopPorts.end}";
        inherit (n) password;
      }
      // lib.optionalAttrs (n ? sni) { inherit (n) sni; }
    else if n.kind == "socks" then
      {
        name = n.name;
        type = "socks5";
        server = "127.0.0.1";
        port = assertField n "port";
      }
    else
      throw "proxy-nodes: 未知 kind ${n.kind}（节点 ${n.name}）";

  # 分组名 → 节点名列表，供 sib 的 selector/urltest 补成员。
  sibGroups = lib.foldl' (
    acc: n:
    lib.foldl' (
      a: g: a // { ${g} = (a.${g} or [ ]) ++ [ n.name ]; }
    ) acc (n.sibGroups or [ ])
  ) { } nodes;
in
{
  inherit nodes toSib toMiho sibGroups;

  # 渲染好的成品列表，消费方直接用，不必自己 map。
  sibOutbounds = map toSib nodes;
  mihoProxies = map toMiho nodes;
}
