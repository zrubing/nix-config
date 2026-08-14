# Clan vars-only machine config for zen14.
#
# 目的：仅用 clan 管理 zen14 的 aliyun work AK/SK（加密存储于 vars/per-machine/zen14/），
# 不接管 zen14 的系统构建（系统仍由 snowfall 的 systems/x86_64-linux/zen14 管理）。
#
# 消费方：snowfall 侧 zen14 配置用 sops-nix 直接引用 vars 生成的加密文件，
# 解密后渲染 ~/.aliyun/credentials（profile 名 work）。
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
}
