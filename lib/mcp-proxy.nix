# MCP 凭证代理的监听地址：全仓库唯一事实来源。
#
# 为什么不是 9100：zen14 / nova13 都是 k0s 节点，9100 被 node_exporter
# DaemonSet 的 hostPort 占着，代理绑不上会以 EADDRINUSE 循环重启（实测
# status=1，restart counter 84）。换端口比动集群监控便宜。
#
# 消费者（改端口只改这里）：
#   - modules/home/mcp-servers/default.nix  选项 listen 的默认值
#   - modules/home/mcp-servers/servers.nix  客户端条目（pi/dsh/codex 的 catalog）
#   - modules/home/multica/default.nix      文档示例
#   - systems/x86_64-linux/{zen14,nova13}   systemd 单元的 MCP_PROXY_LISTEN
let
  host = "127.0.0.1";
  port = 9110;
in
{
  inherit host port;
  # 绑地址（systemd 环境变量 / 选项默认值）
  listen = "${host}:${toString port}";
  # 客户端条目的基址：<baseUrl>/<route>（route 之后的路径原样拼在上游 URL 后面）
  baseUrl = "http://${host}:${toString port}";
}
