# 节点清单的两份事实源合并成转换器的输入（方言见同目录 proxy-nodes.jq）。
#
#   proxy-nodes.meta.json    明文：{'name','kind','port','sibGroups','enabled','relay'}
#   proxy-nodes.creds.json   age 加密：name → 该节点独有的字段
#                            （server / server6 / password / uuid / publicKey / sni / …）
#
# 为什么要拆：
#   · nix 求值期只能读明文。tuic 实例该不该存在、节点进不进组，取决于「节点在不在」
#     —— 这是明文事实，必须能在求值期看到；而 server / 密码 / SNI 一旦进 /nix/store
#     就是世界可读的明文，只能留在密文里。
#   · 拆开后退役一个节点 = 在 meta 里删掉它（或 enabled: false），派生出来的实例、
#     组成员、直连地址随之消失，不需要再改两台主机的 nix 文件。
#
# 用法（$c 是 creds 的 slurpfile）：
#   jq -f lib/proxy-nodes-merge.jq --slurpfile c proxy-nodes-creds.json proxy-nodes.meta.json
#
# 输出与合并前完全同形：{ "nodes": [ {name, kind, port, sibGroups, server, …} ] }。
# socks 节点没有 creds 条目（它只描述本机 127.0.0.1 的监听），其余 kind 缺条目直接报错
# —— 少了 server/密码的节点在 prepare 阶段才炸，错误信息远不如这里清楚。
. as $meta
| ($c[0].nodes // {}) as $creds
| ($meta.nodes // []) as $nodes
| {
    nodes: [
      $nodes[]
      | select(.enabled != false)
      | . as $n
      | ($creds[$n.name] // null) as $cred
      | if $cred == null and $n.kind != "socks" then
          error("proxy-nodes: \($n.name)（kind=\($n.kind)）缺少 creds 条目")
        else . end
      | ($n | del(.relay, .enabled)) + ($cred // {})
    ]
  }
