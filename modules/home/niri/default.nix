{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
with lib.${namespace};
let
  hm = config.lib;
  cfg = config.${namespace}.desktop.niri;
in
{
  options.${namespace}.desktop.niri = with types; {
    enable = mkBoolOpt false "Enable niri config";
  };

  config = mkIf cfg.enable {
    # services.xwayland-satellite.enable = true;
    # services.dunst.enable = true;
    # services.swayidle.enable = true;

    ${namespace} = {
      #rgbar.enable = true;
      noctalia.enable = true;
      #copyq.enable = true;
      #yazi.enable = true;
      #xdg-portal.enable = true;
      linux.desktop = {
        enable = true;
        type = "niri";
      };

      # 使用niri-flake自带的xwayland-satellite
      niri-flake.enable = true;

    };
    home.packages = with pkgs; [
      swappy
      slurp

      mako
      xorg.xrdb
      papirus-icon-theme
      (pkgs.writeScriptBin "brave" ''
        #!/bin/sh
        BRAVE_USER_FLAGS_FILE="$XDG_CONFIG_HOME/brave-flags.conf"
        if [[ -f $BRAVE_USER_FLAGS_FILE ]]; then
            USER_FLAGS="$(cat $BRAVE_USER_FLAGS_FILE | sed 's/#.*//')"
        else
            echo "not found conf file"
        fi
        ${pkgs.brave}/bin/brave $@ $USER_FLAGS
      '')

    ];

    # 使用 home.file 管理 Brave 配置文件
    home.file.".config/brave-flags.conf".text = ''
      # Brave 浏览器启动参数配置
      # 用于启用远程调试，支持 niri-fuzzel-switcher 的标签页切换功能

      --remote-debugging-port=9222

      # 其他可选参数
      # --enable-features=UseOzonePlatform
      # --ozone-platform-hint=auto
      # --disable-features=VizDisplayCompositor
    '';

  };
}
