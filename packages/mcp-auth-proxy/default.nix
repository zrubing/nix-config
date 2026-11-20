{ python3, writeShellApplication }:

writeShellApplication {
  name = "mcp-auth-proxy";

  runtimeInputs = [ python3 ];

  text = ''
    # 监听地址 / 路由 / token 文件全部来自环境（见 proxy.py 头部）：
    # nix 只负责「进程怎么起」，具体端点由 sops 渲染的 env 提供。
    exec python3 ${./proxy.py} "$@"
  '';
}
