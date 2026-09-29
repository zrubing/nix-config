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
  options.${namespace}.desktop = {
    niri = with types; {
      enable = mkBoolOpt false "Enable niri config";
    };

    # ── 输出（显示器）配置：全仓库唯一来源 ──
    # 常规的每屏 scale / mode / position，不是 mixed-DPI workaround。
    # X11 只有一个全局 scale，混合 DPI 的处理在 xwayland-satellite 侧
    # （补丁取所有输出 scale 的最大值，见 overlays/xwayland-satellite）。
    # wayle / noctalia / gpui-shell 三个 niri 配置模块共用这一份；
    # x11Scale 由它派生，供 Xft.dpi 使用（见 modules/home/xwayland-conf）。
    outputs = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          scale = mkOption {
            type = types.float;
            description = "Wayland scale。X11 全局 scale 取所有输出里的最大值。";
          };
          mode = mkOption {
            type = types.submodule {
              options = {
                width = mkOption { type = types.int; };
                height = mkOption { type = types.int; };
                refresh = mkOption { type = types.float; };
              };
            };
          };
          position = mkOption {
            type = types.submodule {
              options = {
                x = mkOption { type = types.int; };
                y = mkOption { type = types.int; };
              };
            };
          };
        };
      });
      default = {
        "eDP-1" = {
          scale = 1.75;
          mode = {
            width = 2880;
            height = 1800;
            refresh = 120.003;
          };
          position = {
            x = 0;
            y = 0;
          };
        };
        "HDMI-A-1" = {
          scale = 1.0;
          mode = {
            width = 1920;
            height = 1080;
            refresh = 60.0;
          };
          position = {
            x = -1920;
            y = 0;
          };
        };
      };
      description = "niri 输出（显示器）配置。";
    };

    x11Scale = mkOption {
      type = types.float;
      readOnly = true;
      default = foldl' max 0.0 (map (o: o.scale) (attrValues config.${namespace}.desktop.outputs));
      defaultText = literalExpression "max(outputs.*.scale)";
      description = ''
        xwayland-satellite 实际使用的 X11 全局 scale（补丁取所有输出 scale 的最大值）。
        所有需要跟 X11 像素空间对齐的地方都从这里取，不要各写一份字面量。
      '';
    };
  };

  config = mkIf cfg.enable {
    # services.xwayland-satellite.enable = true;
    # services.dunst.enable = true;
    # services.swayidle.enable = true;

    ${namespace} = {
      #rgbar.enable = true;
      gpui-shell.enable = false;
      wayle.enable = true;
      noctalia.enable = false;
      #copyq.enable = true;
      yazi.enable = true;
      fileManager.program = "thunar";
      #xdg-portal.enable = true;
      linux.desktop = {
        enable = true;
        type = "niri";
      };

      swayidle.enable = false;
      hypridle.enable = true;

      # niri-flake.enable 目前是空壳（见 modules/home/niri-flake），保留仅为兼容，
      # xwayland-satellite 的包来源已改为 overlays/xwayland-satellite。
      niri-flake.enable = true;

    };
    home.packages = with pkgs; [
      swappy
      slurp

      mako
      xrdb
      papirus-icon-theme
    ];

  };
}
