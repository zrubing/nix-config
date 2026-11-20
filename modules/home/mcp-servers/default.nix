# MCP 凭证代理（客户端侧）：一个进程、一份 token 文件、零密钥配置。
#
# 问题：五个 MCP（以及聚合端点）都认同一张 OpenBao periodic token，但
#   · 客户端（multica / dsh / pi / codex）的 MCP 配置是静态的，没有刷新位置；
#   · 把 token 抄进配置 = 每个客户端存一份明文副本，轮换时 N 处手改；
#   · multica 的 MCP 库在**服务端**，抄进去等于明文进它的数据库。
#
# 做法：本机跑一个只监听 127.0.0.1 的转发进程，**每个请求**从 token 文件读一次，
# 注入 `Authorization: Bearer`。客户端只写 `<代理基址>/<name>`（见 lib/mcp-proxy.nix）
# —— 不含任何密钥，也不含上游地址（地址在 sops 渲染的 env 里）。
#
# 轮换：`mcp-token login` 重写文件，下一个请求即生效，不需要重启任何客户端。
{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.mcp-proxy;
  # 监听地址的单一事实（端口与客户端条目同源）
  mcpProxy = import ../../../lib/mcp-proxy.nix;
  dsh = config.${namespace}.modules.dsh;
in
{
  options.${namespace}.modules.mcp-proxy = with lib; {
    enable = mkEnableOption "Local MCP credential proxy (token file → Authorization header)";

    listen = mkOption {
      type = types.str;
      default = mcpProxy.listen;
      description = ''
        监听地址。只应该绑回环：它不做客户端认证，任何能连上的进程都能借道使用
        token 文件（与 token 文件本身 0600 的信任级一致）。
      '';
    };

    tokenFile = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/state/mcp/token";
      description = "OpenBao token 文件；由 <code>mcp-token login</code> 写入（0600）。";
    };

    routes = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        catalog = "MCP_CATALOG_URL";
        db = "DB_MCP_URL";
      };
      description = ''
        路由名 → 上游地址所在的**环境变量名**。变量由 sops 渲染的 env 文件提供
        （与 dsh 的 MCP 配置同源），本仓库里不出现明文端点。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.${namespace}.mcp-token
      pkgs.${namespace}.mcp-auth-proxy
    ];

    systemd.user.services.mcp-auth-proxy = {
      Unit = {
        Description = "Local MCP credential proxy (token file → Authorization header)";
        After = [ "network-online.target" ] ++ lib.optional (dsh.envFile != null) "sops-nix.service";
        Wants = [ "network-online.target" ] ++ lib.optional (dsh.envFile != null) "sops-nix.service";
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe pkgs.${namespace}.mcp-auth-proxy}";
        # 上游地址来自 sops 渲染的 env（与 dsh-web 同一份），token 路径显式给。
        EnvironmentFile = lib.optional (dsh.envFile != null) dsh.envFile;
        # MCP_PROXY_ROUTES 用 `name=ENVVAR` 形式：上游变量名由这里声明，
        # 值由 EnvironmentFile（sops）提供。systemd 的 Environment= 不做变量
        # 展开，所以不能在这里把 ${ENVVAR} 转发成另一个名字。
        Environment = [
          "MCP_PROXY_LISTEN=${cfg.listen}"
          "MCP_TOKEN_FILE=${cfg.tokenFile}"
          "MCP_PROXY_ROUTES=${
            lib.concatStringsSep "," (lib.mapAttrsToList (name: env: "${name}=${env}") cfg.routes)
          }"
          # dsh.env 里带了 HTTP(S)_PROXY：本机回环请求不能走代理。
          "NO_PROXY=localhost,127.0.0.1,::1"
        ];
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
