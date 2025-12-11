# Snowfall Lib provides access to additional information via a primary argument of
# your overlay.
{
  # Channels are named after NixPkgs instances in your flake inputs. For example,
  # with .input `nixpkgs` there will be a channel available at `channels.nixpkgs`.
  # These channels are system-specific instances of NixPkgs that can be used to quickly
  # pull packages into your overlay.
  channels,

  # Inputs from your flake.
  inputs,
  lib,
  ... }:

final: prev: {
  # 简化版本的 prettier-with-plugins，专注于 nginx 插件
  prettier-with-nginx = prev.prettier.overrideAttrs (oldAttrs: {
    nativeBuildInputs = oldAttrs.nativeBuildInputs or [] ++ [ prev.makeWrapper ];
    
    postInstall = 
      let
        nginxPlugin = prev.callPackage ../../packages/prettier-plugin-nginx { };
        pluginPath = "${nginxPlugin}/lib/node_modules/prettier-plugin-nginx/dist/index.js";
      in
      ''
        # 原有的 postInstall
        ${oldAttrs.postInstall or ""}
        
        # 确保 prettier 的 node_modules 可用
        mkdir -p $out/node_modules
        ln -sf $out/lib/node_modules/prettier $out/node_modules/prettier
        
        # 添加 nginx 插件支持
        wrapProgram $out/bin/prettier --add-flags "--plugin=${pluginPath}" \
          --prefix NODE_PATH : $out/lib/node_modules
        
        # 创建符号链接到 node_modules
        ln -sf ${nginxPlugin}/lib/node_modules/prettier-plugin-nginx $out/node_modules/
      '';
    
    doInstallCheck = false;
  });

  # 通用版本，支持多个插件
  prettier-with-plugins = 
    { enabled ? [] }:
    prev.prettier.overrideAttrs (oldAttrs: {
      nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [ prev.makeWrapper ] ++ enabled;
      
      postInstall = 
        let
          pluginFlags = builtins.concatStringsSep " " (
            builtins.map (plugin: "--plugin=${plugin.outPath}/lib/node_modules/prettier-plugin-nginx/dist/index.js") enabled
          );
        in
      ''
        # 原有的 postInstall
        ${oldAttrs.postInstall or ""}
        
        # 确保 prettier 的 node_modules 可用
        mkdir -p $out/node_modules
        ln -sf $out/lib/node_modules/prettier $out/node_modules/prettier
        
        # 添加插件支持
        wrapProgram $out/bin/prettier --add-flags "${pluginFlags}" \
          --prefix NODE_PATH : $out/lib/node_modules
        
        # 创建符号链接到 node_modules
        ${builtins.concatStringsSep "\n" (
          builtins.map (plugin: "ln -sf ${plugin.outPath}/lib/node_modules/prettier-plugin-nginx $out/node_modules/") enabled
        )}
      '';
    
    doInstallCheck = false;
    });
}