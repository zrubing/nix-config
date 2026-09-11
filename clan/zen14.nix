# Clan vars-only machine config for zen14.
#
# 目的：仅用 clan 管理 zen14 的 aliyun work AK/SK（加密存储于 vars/per-machine/zen14/），
# 不接管 zen14 的系统构建（系统仍由 snowfall 的 systems/x86_64-linux/zen14 管理）。
#
# 消费方：snowfall 侧 zen14 配置用 sops-nix 直接引用 vars 生成的加密文件，
# 解密后渲染 ~/.aliyun/credentials（profile 名 work）；apipost token 则由
# jojo 的 home 级 sops（modules/home/sops）解密注入 dsh.env。
{
  clan.core.vars.generators.aliyun-work = {
    prompts.access-key-id = {
      description = "Aliyun work AccessKey ID";
    };
    files.access-key-id.secret = true;

    prompts.access-key-secret = {
      description = "Aliyun work AccessKey Secret";
      type = "hidden";
    };
    files.access-key-secret.secret = true;

    # clan 的 prompt 文件以换行结尾，secret 一律 str 类型；单行凭据必须去掉
    # 结尾换行，否则消费方拿到的值会自带 \n（TOML/请求头等严格上下文直接报错）。
    script = ''
      tr -d '\n' < $prompts/access-key-id > $out/access-key-id
      tr -d '\n' < $prompts/access-key-secret > $out/access-key-secret
    '';
  };

  # ApiPost 开放平台的 MCP api-token（https://open.apipost.net/mcp 认证头）。
  # 消费方：homes/x86_64-linux/jojo 的 home 级 sops 引用本加密文件，
  # 渲染进 dsh.env，由 dsh 的 mcp-client 插件以 process.env.APIPOST_MCP_TOKEN 读取。
  clan.core.vars.generators.apipost-mcp-token = {
    prompts.api-token = {
      description = "ApiPost MCP api-token";
      type = "hidden";
    };
    files.api-token.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-token > $out/api-token
    '';
  };

  # build.nvidia.com 的 NIM API key（nvapi-...，免费档 40 req/min、1000 credits）。
  # 消费方：home sops 渲染进 dsh.env 的 NVIDIA_NIM_API_KEY（dsh nvidia-nim
  # provider）；pi 模块 activation 合并进 ~/.pi/agent/auth.json（pi-nvidia-nim
  # 扩展）。换 key：clan vars set zen14 nvidia-nim-api-key/api-key
  clan.core.vars.generators.nvidia-nim-api-key = {
    prompts.api-key = {
      description = "NVIDIA NIM API key (nvapi-...)";
      type = "hidden";
    };
    files.api-key.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-key > $out/api-key
    '';
  };

  # 企业 openai relay 的历史 API key + 共享 base URL。
  # api-key 保留给 openai-relay 自身，不跟随 deepseek-relay 轮换；base-url 仍由
  # dsh 的 deepseek-relay 与内置 catalog 路由 openai 共同消费。
  # 换值：clan vars set zen14 openai-relay/api-key（或 /base-url）
  clan.core.vars.generators.openai-relay = {
    prompts.api-key = {
      description = "OpenAI relay API key (sk-...)";
      type = "hidden";
    };
    prompts.base-url = {
      description = "OpenAI relay base URL (https://.../v1)";
      type = "line";
    };
    files.api-key.secret = true;
    files.base-url.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-key > $out/api-key
      tr -d '\n' < $prompts/base-url > $out/base-url
    '';
  };

  # DeepSeek relay 的独立 API key，与 openai-relay/api-key 完全解耦。
  # 消费方：home sops 渲染进 dsh.env 的 DEEPSEEK_RELAY_API_KEY，仅供
  # deepseek-relay 路由使用。换值：clan vars set zen14 deepseek-relay/api-key
  clan.core.vars.generators.deepseek-relay = {
    prompts.api-key = {
      description = "DeepSeek relay API key (sk-...)";
      type = "hidden";
    };
    files.api-key.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-key > $out/api-key
    '';
  };

  # OpenBao LDAP agent 用户名 + 密码：OpenBao 的 LDAP auth（LLDAP 用户，agent
  # 通道）用于程序零交互获取动态 MySQL 只读凭证（读 database/creds/...）。
  # 消费方：home sops 渲染进 dsh.env（dsh-web 服务）与 default.env（终端
  # agent：codex / pi / Claude Code 等，经 ~/.bashrc source）的
  # OPENBAO_LDAP_AGENT_USERNAME / OPENBAO_LDAP_AGENT_PASSWORD / BAO_ADDR。换值：
  # clan vars set zen14 openbao-ldap-agent-password/password
  # clan vars set zen14 openbao-ldap-agent-username/username
  # clan vars set zen14 openbao-addr/addr
  clan.core.vars.generators.openbao-ldap-agent-password = {
    prompts.password = {
      description = "OpenBao LDAP agent 用户密码";
      type = "hidden";
    };
    files.password.secret = true;

    script = ''
      tr -d '\n' < $prompts/password > $out/password
    '';
  };

  clan.core.vars.generators.openbao-ldap-agent-username = {
    prompts.username = {
      description = "OpenBao LDAP agent 用户名（LLDAP 用户）";
    };
    files.username.secret = true;

    script = ''
      tr -d '\n' < $prompts/username > $out/username
    '';
  };

  clan.core.vars.generators.openbao-addr = {
    prompts.addr = {
      description = "OpenBao 集群访问地址（HTTPS URL）";
    };
    files.addr.secret = true;

    script = ''
      tr -d '\n' < $prompts/addr > $out/addr
    '';
  };

  # 平台文档 MCP 端点。消费方：home sops 渲染进 dsh.env（dsh-web 的通用
  # MCP 配置）与 default.env（终端 agent：pi / claude / codex，经 ~/.bashrc
  # source）的 AGENT_DOCS_MCP_URL；codex 侧另以 sops 占位符写进 config.toml。
  # 换值：clan vars set zen14 agent-docs-url/url
  clan.core.vars.generators.agent-docs-url = {
    prompts.url = {
      description = "平台文档 MCP 端点（HTTPS URL，形如 https://<host>/mcp）";
    };
    files.url.secret = true;

    script = ''
      tr -d '\n' < $prompts/url > $out/url
    '';
  };

  # GitHub 远程 MCP server 的 PAT（github_pat_... 或 ghp_...，至少 repo scope）。
  # 消费方：home sops 渲染进 dsh.env 的 GITHUB_MCP_TOKEN，dsh 的 mcp-client 插件
  # （mcp-github）以 process.env.GITHUB_MCP_TOKEN 拼 Bearer 头。换 key：
  # clan vars set zen14 github-mcp-token/api-token
  clan.core.vars.generators.github-mcp-token = {
    prompts.api-token = {
      description = "GitHub MCP personal access token";
      type = "hidden";
    };
    files.api-token.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-token > $out/api-token
    '';
  };

  # Context7 文档 MCP（https://mcp.context7.com/mcp，Upstash 托管）的 API key
  # （ctx7sk-...）。远程端点无 key 可用但限流，带 key 提升配额。原存 claude 侧
  # agenix claude.settings.json（stdio 版 @upstash/context7-mcp），DSH 侧改用
  # 远程 streamable-http 端点 + CONTEXT7_API_KEY 请求头，密文统一入 clan vars。
  # 消费方：home sops 渲染进 dsh.env 的 CONTEXT7_API_KEY（dsh mcp-context7）。
  # 换 key：clan vars set zen14 context7-api-key/api-key
  clan.core.vars.generators.context7-api-key = {
    prompts.api-key = {
      description = "Context7 API key (ctx7sk-...)";
      type = "hidden";
    };
    files.api-key.secret = true;

    script = ''
      tr -d '\n' < $prompts/api-key > $out/api-key
    '';
  };
}
