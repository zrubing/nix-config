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
}
