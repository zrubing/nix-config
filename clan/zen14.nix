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

    script = ''
      cat $prompts/access-key-id > $out/access-key-id
      cat $prompts/access-key-secret > $out/access-key-secret
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
      cat $prompts/api-token > $out/api-token
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
      cat $prompts/api-key > $out/api-key
    '';
  };

  # 企业 openai relay 的 API key + base URL。
  # 新 key 属于 relay 全目录分组（123 模型，含 deepseek-v4 系 / claude / gemini /
  # kimi / qwen / gpt 全家族）；旧 codex_pro 分组 key（6 个 gpt）弃用。
  # 消费方：home sops 渲染进 dsh.env（DEEPSEEK_RELAY_API_KEY /
  # DEEPSEEK_RELAY_BASE_URL），两个 dsh provider 共用：
  #   - deepseek-relay 路由（apiKeyEnv=DEEPSEEK_RELAY_API_KEY）；
  #   - 内置 catalog 路由 openai 的 baseURL 重定向（认证仍走 OPENAI_API_KEY，
  #     见 modules/home/dsh 的 cordis patch providers.openai）。
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
      cat $prompts/api-key > $out/api-key
      cat $prompts/base-url > $out/base-url
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
      cat $prompts/api-token > $out/api-token
    '';
  };
}
