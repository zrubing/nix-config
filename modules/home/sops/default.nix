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

    # DeepSeek 官方平台 key（api.deepseek.com）：密文由 clan vars 管理
    # （clan/zen14.nix 的 deepseek-api-key generator，写入
    # vars/per-machine/zen14/deepseek-api-key/）。原先读私有 nix-secrets 的
    # env.yaml；消费方不变——dsh.env / default.env / tradingagents.env 的
    # DEEPSEEK_API_KEY（dsh 内置 deepseek-official 路由 + dsh-web-search-deepseek）。
    # 换 key：clan vars set zen14 deepseek-api-key/api-key
    sops.secrets."deepseek/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/deepseek-api-key/api-key/secret;
      format = "binary";
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

    # DeepSeek relay 独立 key：密文由 clan vars 的 deepseek-relay generator 管理，
    # 与保留的 openai-relay/api-key 解耦。渲染进 dsh.env 的
    # DEEPSEEK_RELAY_API_KEY，仅供 dsh 的 deepseek-relay 路由使用。
    sops.secrets."deepseek-relay/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/deepseek-relay/api-key/secret;
      format = "binary";
    };

    # relay base URL 仍复用 openai-relay generator：deepseek-relay 路由与内置
    # catalog 路由 openai 的 baseURL 重定向共用同一端点。openai 路由认证仍走
    # OPENAI_API_KEY，不使用两个 relay key 文件。
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

    # HuggingFace access token（hf_...）：密文由 clan vars 管理（clan/zen14.nix 的
    # huggingface-token generator，写入 vars/per-machine/zen14/huggingface-token/）。
    # 渲染进 default.env（终端）与 dsh.env（dsh-web 宿主进程）的 HF_TOKEN——
    # hf CLI（huggingface_hub，终端里经 `uvx --from huggingface_hub hf` 或自装
    # python 环境）与 transformers / datasets 等库读该变量自动鉴权，无需
    # `hf auth login`（后者会把明文写到 ~/.cache/huggingface/token，脱离声明式
    # 管理）。dsh 侧 agent shell 还要过一层：HF_TOKEN 命中 subprocess 敏感名
    # scrub，由 hf-shell-env 插件（modules/home/dsh）以受信通道注入
    # DSH_HF_TOKEN，再经 BASH_ENV 桥接回 HF_TOKEN。加密 recipients 同 apipost
    # （machines/zen14 与 users/jojo）。换值：clan vars set zen14 huggingface-token/token
    sops.secrets."huggingface/token" = {
      sopsFile = ../../../vars/per-machine/zen14/huggingface-token/token/secret;
      format = "binary";
    };

    # Figma PAT：密文由 clan vars 管理（clan/zen14.nix 的 figma-api-key
    # generator）。渲染进 dsh.env 与 default.env 的 FIGMA_API_KEY——
    # Framelink MCP（figma-developer-mcp）读该变量鉴权，pi / dsh / claude-code
    # 三处同一个 secret；codex 侧走 config.toml 的 sops 占位符（同 apipost）。
    # 加密 recipients 同 apipost（machines/zen14 与 users/jojo）。
    sops.secrets."figma/api_key" = {
      sopsFile = ../../../vars/per-machine/zen14/figma-api-key/api-key/secret;
      format = "binary";
    };

    # OpenBao LDAP agent 用户名：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-ldap-agent-username generator）。与密码/地址配套渲染进两处 env：
    # dsh.env（dsh-web 服务，见下方 dsh.env 模板）与 default.env（终端 agent：
    # codex / pi / Claude Code 等，经 ~/.bashrc source）的
    # OPENBAO_LDAP_AGENT_USERNAME——程序经 OpenBao LDAP auth 零交互取动态
    # MySQL 只读凭证时读取。加密 recipients 同 apipost（machines/zen14 与
    # users/jojo）。
    sops.secrets."openbao-ldap-agent/username" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-ldap-agent-username/username/secret;
      format = "binary";
    };

    # OpenBao LDAP agent 密码：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-ldap-agent-password generator，写入
    # vars/per-machine/zen14/openbao-ldap-agent-password/）。与用户名/地址配套
    # 渲染进 dsh.env（dsh-web 服务）与 default.env（终端 agent）的
    # OPENBAO_LDAP_AGENT_PASSWORD——程序经 OpenBao LDAP auth 零交互取动态
    # MySQL 只读凭证时读取。加密 recipients 同 apipost（machines/zen14 与
    # users/jojo）。
    sops.secrets."openbao-ldap-agent/password" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-ldap-agent-password/password/secret;
      format = "binary";
    };

    # OpenBao 集群访问地址：密文由 clan vars 管理（clan/zen14.nix 的
    # openbao-addr generator）。与 LDAP agent 凭据配套渲染进 dsh.env 与
    # default.env 的 BAO_ADDR——程序执行 bao CLI 时自动带上，无需手动
    # export。加密 recipients 同 apipost（machines/zen14 与 users/jojo）。
    sops.secrets."openbao-addr/addr" = {
      sopsFile = ../../../vars/per-machine/zen14/openbao-addr/addr/secret;
      format = "binary";
    };

    # 平台文档 MCP 端点：密文由 clan vars 管理（clan/zen14.nix 的
    # agent-docs-url generator）。渲染进 default.env / dsh.env 的
    # AGENT_DOCS_MCP_URL（pi/claude/dsh 的 MCP 配置读它），codex 侧以 sops 占位符
    # 写进 config.toml 的 mcp_servers.agent-docs.url。加密 recipients 同 apipost。
    sops.secrets."agent-docs/url" = {
      sopsFile = ../../../vars/per-machine/zen14/agent-docs-url/url/secret;
      format = "binary";
    };

    # 全局 agent 指令（~/.agents/AGENTS.md，当前内容为通用协作偏好：先对齐
    # 再输出 / KISS / 优先根源重构 / 多步骤用有序列表 等）：全文 sops 加密
    # （仓库内 .sops.yaml zen14 规则，
    # systems/x86_64-linux/zen14/secrets/AGENTS.md），激活时解密渲染到共享
    # 根 ~/.agents/（与 ~/.agents/skills 同一约定根）。内容含集群地址等不宜
    # 明文入库的信息；不含密码（密码经 env 注入）。
    #
    # 消费方（各家全局指令路径不同，且 dsh/codex/pi 都没有 include 机制）：
    #   - dsh  : ~/.dsh/AGENTS.md（$DSH_HOME/AGENTS.md，dsh-agent-instructions 插件）
    #   - codex: ~/.codex/AGENTS.md（$CODEX_HOME/AGENTS.md；官方文档：优先
    #            AGENTS.override.md，缺省读 AGENTS.md）
    #   - pi   : ~/.pi/agent/AGENTS.md（pi 每目录只取一个 context file，
    #            无 include；由 sops 模板合成「pi 专属明文 + 本文档」，
    #            见 modules/home/pi 的 sops.templates."pi-agents-md"）
    # 前两者由下方 home.activation.linkSharedAgentsMd 建 symlink 指向真源；
    # claude（~/.claude/CLAUDE.md，支持 @import）本次未接。
    sops.secrets."agents/AGENTS.md" = {
      sopsFile = ../../../systems/x86_64-linux/zen14/secrets/AGENTS.md;
      format = "binary";
      path = "/home/${username}/.agents/AGENTS.md";
    };

    # 共享 AGENTS.md 的消费方软链（dsh / codex），必须在 sops-nix 渲染出真源
    # 之后执行。~/.dsh/AGENTS.md 在本改动前是 sops 直接管理的 symlink（secret
    # path 指向它），ln -sfn 会覆盖为新真源的链接，不留旧指向。
    home.activation.linkSharedAgentsMd = inputs.home-manager.lib.hm.dag.entryAfter [ "sops-nix" ] ''
      mkdir -p "$HOME/.agents" "$HOME/.dsh" "$HOME/.codex"
      ln -sfn "$HOME/.agents/AGENTS.md" "$HOME/.dsh/AGENTS.md"
      ln -sfn "$HOME/.agents/AGENTS.md" "$HOME/.codex/AGENTS.md"
    '';

    # anysearch CLI 运行时从 skill 目录读 .env（anysearch_cli.{sh,py,js} 的
    # _load_env：先 <script_dir>/.env，再 <script_dir>/../.env）。skill 由
    # modules/home/skills 投放到 ~/.agents/skills（pi / DSH / Codex）与
    # ~/.claude/skills（Claude Code），两个根各要一份 .env，否则 CLI 只拿到
    # 匿名额度。home-manager 的 recursive 投放走 lndir，只补源目录里存在的
    # 文件，不会删这里放进去的 .env。
    # bashrc 也 source 同一份（见 modules/home/bash 的 anysearch 块，路径取自本
    # 模板的 path），终端里启动的 agent 另有环境变量兜底。
    sops.templates."anysearch-env" = {
      path = "/home/${username}/.agents/skills/anysearch/.env";
      content = ''
        export ANYSEARCH_API_KEY="${config.sops.placeholder."anysearch/api_key"}"
      '';
    };

    sops.templates."anysearch-env-claude" = {
      path = "/home/${username}/.claude/skills/anysearch/.env";
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
        # DeepSeek relay：与 dsh.env 的 DEEPSEEK_RELAY_API_KEY 同一个 clan var
        # （deepseek-relay/api-key），只是渲染到两个 env 文件——dsh-web 读
        # ~/.config/dsh.env，终端 agent（pi）读本文件。pi 的 models.json 里该
        # provider 写 apiKey: "$DEEPSEEK_RELAY_API_KEY" 引用（见
        # modules/home/llm-routes/routes.nix 的 apiKeyEnv），故此处必须 export，
        # 否则 pi 的 relay 模型会因缺 env 而不可用。
        # 2026-09-14 之前 pi 侧 key 硬编码在 age 密文里且与 dsh 不同源（dsh key
        # 对 v4-flash/v4-pro 全部 403，pi key 可访问），现已统一到同一 secret。
        export DEEPSEEK_RELAY_API_KEY="${config.sops.placeholder."deepseek-relay/api_key"}"
        # GH_TOKEN 复用 github-mcp/api_token 同一份 PAT（clan/zen14.nix github-mcp-token），
        # 供 gh CLI / git 等读标准 GH_TOKEN 完成认证。单一来源，随 MCP token 一起轮换。
        export GH_TOKEN="${config.sops.placeholder."github-mcp/api_token"}"
        # Context7 MCP：pi 侧（npx stdio 版）读 CONTEXT7_API_KEY，pi-mcp-adapter
        # 连接时对 env 做 ''${VAR} 插值，故必须出现在启动 pi 的 shell 环境里；
        # dsh 侧同名变量由 dsh.env 提供（同一份 context7/api_key）。
        export CONTEXT7_API_KEY="${config.sops.placeholder."context7/api_key"}"
        # Figma PAT：Framelink MCP（figma-developer-mcp，npx stdio）读 FIGMA_API_KEY
        # 鉴权，pi / claude-code 在启动 MCP 子进程时把该变量传下去；dsh 侧同名变量
        # 由 dsh.env 提供（同一份 figma/api_key）。
        export FIGMA_API_KEY="${config.sops.placeholder."figma/api_key"}"
        # HuggingFace token（clan vars huggingface-token）：hf CLI（huggingface_hub）
        # 与 transformers / datasets / vLLM 等库读 HF_TOKEN 自动鉴权（gated 模型
        # 下载也走它）。不用 `hf auth login`——那会把明文写到
        # ~/.cache/huggingface/token；env 变量是声明式的等价物。
        export HF_TOKEN="${config.sops.placeholder."huggingface/token"}"

        # OpenBao LDAP agent 凭据（clan vars openbao-ldap-agent-username /
        # -password / openbao-addr）：终端 agent（codex 等）与 dsh 走同一套
        # 「LLDAP agent 用户 + bao login -method=ldap → 动态 MySQL 只读凭证」
        # 流程，凭据必须出现在 shell 环境里才可用（非交互子进程不会自己 source
        # 这个文件；codex 的 shell_environment_policy 继承全量 env 且不改默认
        # 排除表，故 export 后即可见）。dsh-web 另有 dsh.env（同源 secret），
        # 不经本文件。
        export OPENBAO_LDAP_AGENT_USERNAME="${config.sops.placeholder."openbao-ldap-agent/username"}"
        export OPENBAO_LDAP_AGENT_PASSWORD="${config.sops.placeholder."openbao-ldap-agent/password"}"
        export BAO_ADDR="${config.sops.placeholder."openbao-addr/addr"}"
        # 平台文档 MCP 端点（终端 agent 的 MCP 配置读取）
        export AGENT_DOCS_MCP_URL="${config.sops.placeholder."agent-docs/url"}"
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
        FIGMA_API_KEY=${config.sops.placeholder."figma/api_key"}
        # HuggingFace token（clan vars huggingface-token）：宿主进程读 HF_TOKEN
        # 交给 hf-shell-env 插件的 contributor；名字含 TOKEN 会被 agent
        # subprocess 的敏感名 scrub 擦除，agent 侧只能经受信通道
        # （DSH_HF_TOKEN）+ BASH_ENV 桥接拿回原名。
        HF_TOKEN=${config.sops.placeholder."huggingface/token"}
        OPENBAO_LDAP_AGENT_USERNAME=${config.sops.placeholder."openbao-ldap-agent/username"}
        OPENBAO_LDAP_AGENT_PASSWORD=${config.sops.placeholder."openbao-ldap-agent/password"}
        BAO_ADDR=${config.sops.placeholder."openbao-addr/addr"}
        AGENT_DOCS_MCP_URL=${config.sops.placeholder."agent-docs/url"}
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
