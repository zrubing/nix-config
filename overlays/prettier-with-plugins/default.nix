{
  channels,
  inputs,
  lib,
  ...
}:
self: super: {
  # 为 prettier 添加 nginx 插件支持
  prettier-with-nginx = super.prettier.override {
    # 添加插件到 prettier
    plugins = [
      # 使用你现有的 prettier-plugin-nginx 包
      (super.callPackage ../packages/prettier-plugin-nginx { })
    ];
  };
}