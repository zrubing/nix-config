{ python3, writeShellApplication }:

writeShellApplication {
  name = "mcp-token";

  runtimeInputs = [ python3 ];

  text = ''
    # 设备码授权（手机也能完成）+ 自动刷新：见 mcp_token.py 头部。
    exec python3 ${./mcp_token.py} "$@"
  '';
}
