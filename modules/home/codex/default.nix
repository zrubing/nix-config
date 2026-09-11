{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.codex;
  username = config.snowfallorg.user.name;
  # MCP server 定义复用 modules/home/mcp-servers/servers.nix 的 codex 视图
  # （与 pi / dsh / Claude Code 同一份源）。密钥走 sopsPlaceholder：渲染成占位符
  # 拼进下面的 config.toml 模板，激活时替换为明文。
  mcpServers = import ../mcp-servers/servers.nix {
    inherit lib pkgs namespace;
    sopsPlaceholder = name: config.sops.placeholder.${name};
  };
in
{
  options.${namespace}.modules.codex = {
    enable = lib.mkEnableOption "Codex configuration";
  };

  config = lib.mkIf cfg.enable {
    home.file.".codex/models.json".source = ./models.json;

    # config.toml contains the relay bearer token; render it through sops so the
    # secret is substituted during activation instead of being stored in Nix.
    sops.templates."codex-config" = lib.mkIf config.${namespace}.sops.enable {
      path = "/home/${username}/.codex/config.toml";
      mode = "0600";
      content = ''
        model = "deepseek-flash"
        model_provider = "deepseek"
        preferred_auth_method = "apikey"
        forced_login_method = "api"
        model_reasoning_effort = "max"
        # 内置原生 web_search（Responses API 服务端搜索）。
        # codex 侧不再挂智谱 web-search-prime MCP：其服务端对 notifications/initialized
        # 返回 200 + 无 Content-Type，被 rmcp 判为 "missing-content-type" 而握手失败
        # （国内站与 z.ai 国际站同病，且 pi/dsh 侧不受影响）。
        web_search = "live"
        model_catalog_json = "~/.codex/models.json"

        # yolo 模式：不弹审批 + 无沙箱全盘访问。
        # 必须留在第一个 [table] 之前，否则会被 TOML 解析成 model_providers.deepseek 的字段。
        # 参考：https://learn.chatgpt.com/docs/agent-approvals-security
        approval_policy = "never"
        sandbox_mode = "danger-full-access"

        [model_providers.deepseek]
        name = "deepseek"
        base_url = "${config.sops.placeholder."deepseek-relay/base_url"}"
        wire_api = "responses"
        experimental_bearer_token = "${config.sops.placeholder."deepseek-relay/api_key"}"

        # MCP servers：来源 modules/home/mcp-servers/servers.nix（codex 视图），
        # 与 pi / dsh / Claude Code 共用一份定义。密钥占位符由本模板的 sops 渲染替换。
        ${mcpServers.codexConfig}
      '';
    };
  };
}
