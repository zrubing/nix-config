{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
let
  cfg = config.${namespace}.sops;
  mysecrets = inputs.mysecrets;
  username = config.snowfallorg.user.name;
in
{
  options.${namespace}.sops = with lib; {
    enable = mkEnableOption "Enable sops configuration";
  };

  config = mkIf cfg.enable {
    sops.age.sshKeyPaths = [ "/home/${username}/.ssh/id_ed25519" ];

    sops.secrets."anthropic/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."openrouter/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."runinfra/gateway_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };


    sops.secrets."anthropic/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."volc-coding/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."volc-coding/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."volc-coding/model" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."minimax-coding/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."minimax-coding/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."minimax-coding/model" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."qwen/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."qwen/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."woodpecker/token" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."woodpecker/server" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."zot/username" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."zot/password" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."deepseek/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."alphavantage/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."anysearch/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."opencode/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."openai/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    # 企业 relay key + base URL：密文由 clan vars 管理（clan/zen14.nix
    # openai-relay generator）。独立 env（DEEPSEEK_RELAY_*），不影响原
    # OPENAI_API_KEY；base URL 由 dsh 两个 provider 共用——deepseek-relay 路由与
    # 内置 catalog 路由 openai 的 baseURL 重定向（modules/home/dsh providers.openai）。
    sops.secrets."deepseek-relay/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/openai-relay/api-key/secret;
      format = "binary";
    };
    sops.secrets."deepseek-relay/base_url" = {
      sopsFile = ../../../vars/per-machine/zen14/openai-relay/base-url/secret;
      format = "binary";
    };

    # ApiPost MCP token：密文由 clan vars 管理（clan/zen14.nix 的 apipost-mcp-token
    # generator，写入 vars/per-machine/zen14/apipost-mcp-token/）。加密 recipients
    # 同时含 machines/zen14 与 users/jojo，故这里可用 jojo 的 age(ssh) key 解密。
    # binary 格式 = sops 整文件加密形态（{"data": "ENC[...]"}）。
    sops.secrets."apipost-mcp/api_token" = {
      sopsFile = ../../../vars/per-machine/zen14/apipost-mcp-token/api-token/secret;
      format = "binary";
    };

    # NVIDIA NIM API key：密文由 clan vars 管理（clan/zen14.nix 的
    # nvidia-nim-api-key generator，写入 vars/per-machine/zen14/nvidia-nim-api-key/）。
    # 渲染进 dsh.env 的 NVIDIA_NIM_API_KEY（dsh nvidia-nim provider）；pi 侧另由
    # pi 模块 activation 读同一 secret 写 auth.json。
    sops.secrets."nvidia-nim/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/nvidia-nim-api-key/api-key/secret;
      format = "binary";
    };

    # GitHub 远程 MCP server 的 PAT：密文由 clan vars 管理（clan/zen14.nix 的
    # github-mcp-token generator，写入 vars/per-machine/zen14/github-mcp-token/）。
    # 渲染进 dsh.env 的 GITHUB_MCP_TOKEN（dsh mcp-github server，Bearer 头）。加密
    # recipients 同 apipost（machines/zen14 与 users/jojo）。
    sops.secrets."github-mcp/api_token" = {
      sopsFile = ../../../vars/per-machine/zen14/github-mcp-token/api-token/secret;
      format = "binary";
    };

    # Context7 文档 MCP 的 API key：密文由 clan vars 管理（clan/zen14.nix 的
    # context7-api-key generator，写入 vars/per-machine/zen14/context7-api-key/）。
    # 渲染进 dsh.env 的 CONTEXT7_API_KEY（dsh mcp-context7 server，CONTEXT7_API_KEY
    # 请求头；无 key 时远程端点也可用但限流）。原存 claude 侧 agenix（stdio 版
    # 配置），DSH 侧改远程端点后统一入 clan vars。加密 recipients 同 apipost
    # （machines/zen14 与 users/jojo）。
    sops.secrets."context7/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/context7-api-key/api-key/secret;
      format = "binary";
    };

    # OpenBao LDAP agent 用户名：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-ldap-agent-username generator）。与密码配套渲染进 dsh.env 的
    # OPENBAO_LDAP_AGENT_USERNAME——程序经 OpenBao LDAP auth 零交互取动态
    # MySQL 只读凭证时读取。加密 recipients 同 apipost（machines/zen14 与
    # users/jojo）。
    sops.secrets."openbao-ldap-agent/username" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-ldap-agent-username/username/secret;
      format = "binary";
    };

    # OpenBao LDAP agent 密码：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-ldap-agent-password generator，写入
    # vars/per-machine/zen14/openbao-ldap-agent-password/）。渲染进 dsh.env 的
    # OPENBAO_LDAP_AGENT_PASSWORD——程序经 OpenBao LDAP auth 零交互取动态
    # MySQL 只读凭证时读取。加密 recipients 同 apipost（machines/zen14 与
    # users/jojo）。
    sops.secrets."openbao-ldap-agent/password" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-ldap-agent-password/password/secret;
      format = "binary";
    };

    # OpenBao 集群访问地址：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-addr generator）。渲染进 dsh.env 的 BAO_ADDR——程序执行
    # bao CLI 时自动带上，无需手动 export。加密 recipients 同 apipost
    # （machines/zen14 与 users/jojo）。
    sops.secrets."openbao-addr/addr" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-addr/addr/secret;
      format = "binary";
    };

    # dsh agent 全局指令（~/.dsh/AGENTS.md）：所有 dsh agent 的用法说明都
    # 放这里（当前为 OpenBao 操作指南）。全文 sops 加密（仓库内 .sops.yaml
    # zen14 规则，systems/x86_64-linux/zen14/secrets/AGENTS.md），激活时解密
    # 渲染并 symlink 到 dsh-agent-instructions 的全局指令位置。内容含集群
    # 地址等不宜明文入库的信息；不含密码（密码经 env 注入）。
    sops.secrets."dsh-agents/AGENTS.md" = {
      sopsFile = ../../../systems/x86_64-linux/zen14/secrets/AGENTS.md;
      format = "binary";
      path = "/home/${username}/.dsh/AGENTS.md";
    };

    sops.templates."anysearch-env" = {
      path = "/home/${username}/.pi/agent/skills/anysearch/.env";
      content = ''
        export ANYSEARCH_API_KEY="${config.sops.placeholder."anysearch/api_key"}"
      '';
    };

    sops.templates."tradingagents.env" = {
      path = "/home/${username}/.config/tradingagents/.env";
      content = ''
        # --- LLM Provider ---
        export TRADINGAGENTS_LLM_PROVIDER=deepseek

        # --- DeepSeek (sops-managed) ---
        export DEEPSEEK_API_KEY="${config.sops.placeholder."deepseek/api_key"}"

        # --- Anthropic-compatible (Zhipu via sops) ---
        export ANTHROPIC_API_KEY="${config.sops.placeholder."anthropic/api_key"}"
        export ANTHROPIC_BASE_URL="${config.sops.placeholder."anthropic/base_url"}"

        # --- Alpha Vantage (sops-managed) ---
        export ALPHA_VANTAGE_API_KEY="${config.sops.placeholder."alphavantage/api_key"}"

        # --- Optional overrides ---
        # export TRADINGAGENTS_DEEP_THINK_LLM=deepseek-chat
        # export TRADINGAGENTS_QUICK_THINK_LLM=deepseek-chat
        # export TRADINGAGENTS_OUTPUT_LANGUAGE=Chinese
      '';
    };

    sops.templates."default-env" = {
      path = "/home/${username}/.config/default.env";
      content = ''

        export OPENAI_API_KEY="${config.sops.placeholder."openai/api_key"}"
        export OPENROUTER_API_KEY="${config.sops.placeholder."openrouter/api_key"}"
        export OPENCODE_API_KEY="${config.sops.placeholder."opencode/api_key"}"
        export DEEPSEEK_API_KEY="${config.sops.placeholder."deepseek/api_key"}"
        export ZAI_CODING_CN_API_KEY="${config.sops.placeholder."anthropic/api_key"}"
        # GH_TOKEN 复用 github-mcp/api_token 同一份 PAT（clan/zen14.nix github-mcp-token），
        # 供 gh CLI / git 等读标准 GH_TOKEN 完成认证。单一来源，随 MCP token 一起轮换。
        export GH_TOKEN="${config.sops.placeholder."github-mcp/api_token"}"
      '';
    };

    # dsh-web 服务的环境文件（无 export 前缀，systemd EnvironmentFile 格式）。
    # sops 激活时把 placeholder 替换为真实密钥，比直接写进 unit 的 Environment 可靠。
    sops.templates."dsh.env" = {
      path = "/home/${username}/.config/dsh.env";
      mode = "0400";
      content = ''
        DEEPSEEK_API_KEY=${config.sops.placeholder."deepseek/api_key"}
        OPENAI_API_KEY=${config.sops.placeholder."openai/api_key"}
        DEEPSEEK_RELAY_API_KEY=${config.sops.placeholder."deepseek-relay/api_key"}
        DEEPSEEK_RELAY_BASE_URL=${config.sops.placeholder."deepseek-relay/base_url"}
        OPENROUTER_API_KEY=${config.sops.placeholder."openrouter/api_key"}
        RUNINFRA_GATEWAY_KEY=${config.sops.placeholder."runinfra/gateway_key"}
        OPENCODE_API_KEY=${config.sops.placeholder."opencode/api_key"}
        ZAI_CODING_CN_API_KEY=${config.sops.placeholder."anthropic/api_key"}
        APIPOST_MCP_TOKEN=${config.sops.placeholder."apipost-mcp/api_token"}
        NVIDIA_NIM_API_KEY=${config.sops.placeholder."nvidia-nim/api_key"}
        GITHUB_MCP_TOKEN=${config.sops.placeholder."github-mcp/api_token"}
        CONTEXT7_API_KEY=${config.sops.placeholder."context7/api_key"}
        OPENBAO_LDAP_AGENT_USERNAME=${config.sops.placeholder."openbao-ldap-agent/username"}
        OPENBAO_LDAP_AGENT_PASSWORD=${config.sops.placeholder."openbao-ldap-agent/password"}
        BAO_ADDR=${config.sops.placeholder."openbao-addr/addr"}
        # woodpecker-cli 凭据：bashrc 只 export 进交互 shell（WOODPECKER_TOKEN
        # 会被 dsh subprocess 的敏感名 scrub 擦除），dsh 侧经 shell-env 受信通道
        # 以 DSH_WOODPECKER_* 注入（见 modules/home/dsh 的 woodpecker-shell-env
        # 插件），此处渲染进 dsh-web 宿主进程 env 供该插件 resolve。
        WOODPECKER_SERVER=${config.sops.placeholder."woodpecker/server"}
        WOODPECKER_TOKEN=${config.sops.placeholder."woodpecker/token"}
        # 模型 bash 调用的自动桥接（见 home.file ".dsh/dsh-bash-env.sh"）：
        # bash 非交互启动时 source BASH_ENV，把 shell-env 注入的 DSH_WOODPECKER_*
        # 转回 WOODPECKER_*，woodpecker-cli 无需 agent 手动转换即可直接使用。
        BASH_ENV=/home/${username}/.dsh/dsh-bash-env.sh
        # dsh-web-fetch-http 走本地 gost HTTP->SOCKS5 桥接代理，绕过 fake-ip 导致的
        # "resolves to a non-public IP address" SSRF 误拦。gost 转发的上游是
        HTTP_PROXY=http://127.0.0.1:10086
        HTTPS_PROXY=http://127.0.0.1:10086
      '';
    };
  };
}
