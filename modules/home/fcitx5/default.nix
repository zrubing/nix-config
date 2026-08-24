{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  cfg = config.${namespace}.modules.fcitx5;

  default = ''
    patch:
      schema_list:
        - schema: rime_ice
  '';

  rime_ice_custom = ''

    patch:
      traditionalize/opencc_config: s2hk.json
      grammar:
        language: amz-v2n3m1-zh-hans
        collocation_max_length: 8         #命中的最长词组
        collocation_min_length: 3         #命中的最短词组，搭配词频健全的词库时候应当最小值设为3避开2字高频词
        collocation_penalty: -10           #默认-12 对常见搭配词组施加的惩罚值。较高的负值会降低这些搭配被选中的概率，防止过于频繁地出现某些固定搭配。
        non_collocation_penalty: -17      #默认-12 对非搭配词组施加的惩罚值。较高的负值会降低非搭配词组被选中的概率，避免不合逻辑或不常见的词组组合。
        weak_collocation_penalty: -24     #默认-24 对弱搭配词组施加的惩罚值。保持默认值通常是为了有效过滤掉不太常见但仍然合理的词组组合。
        rear_penalty: -18                 #默认-18 对词组中后续词语的位置施加的惩罚值。较高的负值会降低某些词语在句子后部出现的概率，防止句子结构不自然。

      translator/contextual_suggestions: false
      translator/max_homophones: 5
      translator/max_homographs: 5



  '';
in
{

  options.${namespace}.modules.fcitx5 = {
    enable = lib.mkEnableOption "fcitx5";
  };

  config = lib.mkIf cfg.enable {

    # WeChat runs through Xwayland and uses XIM. Start fcitx only after the
    # X server is ready, otherwise its XIM connection may silently disappear
    # and WeChat will keep accepting Chinese input without showing candidates.
    systemd.user.services.fcitx5-daemon = {
      Unit = {
        After = lib.mkAfter [ "xwayland-satellite.service" ];
        Wants = [ "xwayland-satellite.service" ];
      };
      Install.WantedBy = lib.mkForce [ "graphical-session.target" ];
      Service = {
        Environment = [ "DISPLAY=:0" ];
        # on-failure misses clean exits (fcitx5 exits with status 0 when its
        # dbus/wayland frontend wedges), leaving the bus name free for a
        # dbus-activated rogue instance. Restart unconditionally instead.
        Restart = lib.mkForce "always";
        RestartSec = "2";
        # Kill rogue instances so the managed one can claim org.fcitx.Fcitx5.
        # On NixOS the running process has comm '.fcitx5-wrapped' while its
        # cmdline still reads 'fcitx5 ...', so neither 'pkill -x fcitx5' nor
        # 'pkill -f fcitx5-wrapped' can catch it. Match the real comm.
        # '-' ignores failure when nothing is running.
        ExecStartPre = "-${pkgs.procps}/bin/pkill -x .fcitx5-wrapped";
      };
    };



    xdg = {
      # for emacs rime
      configFile = {
        "rime/default.custom.yaml" = {
          text = default;
        };
        "rime/rime_ice.custom.yaml" = {
          text = rime_ice_custom;
        };

        # Create a disabled autostart desktop file which takes precedence of
        # /etc/profiles/per-user/meowking/etc/xdg/autostart/org.fcitx.Fcitx5.desktop
        # which is created by fcitx5 package:
        # https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/tools/inputmethods/fcitx5/with-addons.nix
        "autostart/org.fcitx.Fcitx5.desktop".text = ''
          [Desktop Entry]
          Name=Fcitx 5
          Hidden=true
        '';

        # Redirect dbus activation to the systemd unit, so a rogue instance
        # can never be spawned outside of systemd management.

        # Make Fcitx5 work on XWayland (e.g. wechat)
        # Niri used xwayland-satellite doesn't support IME yet.
        # https://github.com/Supreeeme/xwayland-satellite/issues/92#issuecomment-2881949607
        "fcitx5/conf/xim.conf".text = ''
          UseOnTheSpot=True
        '';

      };

      dataFile = {
        "fcitx5/rime/amz-v2n3m1-zh-hans.gram" = {
          source = inputs.rime-3gram;
        };

        # Redirect dbus activation to the systemd unit, so a rogue instance
        # can never be spawned outside of systemd management.
        # Overrides the file shipped in /etc/profiles/per-user/*/share/dbus-1/services.
        "dbus-1/services/org.fcitx.Fcitx5.service".text = ''
          [D-BUS Service]
          Name=org.fcitx.Fcitx5
          Exec=${config.i18n.inputMethod.package}/bin/fcitx5
          SystemdService=fcitx5-daemon.service
        '';

        # https://wiki.archlinuxcn.org/wiki/Rime

        "fcitx5/rime/default.custom.yaml" = {
          text = default;
        };
        "fcitx5/rime/rime_ice.custom.yaml" = {
          text = rime_ice_custom;
        };
      };
    };

    home.sessionVariables = {
      GLFW_IM_MODULE = lib.mkForce "ibus"; # IME support in kitty and fuzzel
      XMODIFIERS = "@im=fcitx";
      GTK_IM_MODULE = lib.mkForce "";
      QT_IM_MODULE = lib.mkForce "";

    }
    //
      # Only KDE needs the legacy toolkit variables (kimpanel). On niri they
      # make apps bypass the compositor text-input protocol and cause
      # 'Toolkit specific environment variable detected' warnings.
      lib.optionalAttrs config.${namespace}.desktop.kde.enable {
        GTK_IM_MODULE = lib.mkForce "fcitx";
        QT_IM_MODULE = lib.mkForce "fcitx";
      };

    i18n.inputMethod = {
      type = "fcitx5";
      enable = true;
      fcitx5.addons = with pkgs; [
        # for flypy chinese input method
        fcitx5-rime
        # needed enable rime using configtool after installed
        qt6Packages.fcitx5-chinese-addons
        qt6Packages.fcitx5-configtool
        # fcitx5-mozc    # japanese input method
        fcitx5-gtk # gtk im module
        qt6Packages.fcitx5-skk-qt
      ];
    };

  };
  #home.file.".config/rime/default.custom.yaml".source = ./rime-data-flypy/share/rime-data/default.custom.yaml;

}
