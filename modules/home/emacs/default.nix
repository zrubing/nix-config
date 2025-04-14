{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  system,
  ...
}:
with lib;
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.emacs;
  hm = config.lib;
  desktopCfg = config.${namespace}.desktop;

  librime-dir = "${config.xdg.dataHome}/emacs/librime";
  tdlib-dir = "${config.xdg.dataHome}/tdlib";
  rime-data-dir = "${config.xdg.dataHome}/rime-data";
  librime-emacs-dir = "${config.xdg.configHome}/emacs/.local/straight/repos/emacs-rime";

  envExtra = lib.mkAfter ''
    export PATH="${config.xdg.configHome}/emacs.doom/bin:$PATH"
  '';
  shellAliases = {
    e = "emacsclient --create-frame"; # gui
    et = "emacsclient --create-frame --tty"; # terminal
  };

  commonConfig = {
    programs.bash.bashrcExtra = envExtra;
    programs.zsh.envExtra = envExtra;
    home.shellAliases = shellAliases;
    programs.nushell.shellAliases = shellAliases;

    home.activation.installEmacslib = hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${librime-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.librime}/ ${librime-dir}/
      mkdir -p ${rime-data-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.rime-data}/ ${rime-data-dir}/
      mkdir -p ${tdlib-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs-unstable.tdlib}/ ${tdlib-dir}/
    '';
  };
in
{
  options.${namespace}.emacs = {
    enable = mkEnableOption "Emacs Editor";
    type = mkOption {
      type = types.enum [
        "doom"
        "centaur"
      ];
      default = "doom";
      description = "Which Emacs distribution to use";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    commonConfig
    (import ./tree-sitter-libs.nix {
      inherit
        config
        lib
        pkgs
        namespace
        inputs
        system
        ;
    }).config

    (import ./chemacs2.nix {
      inherit
        config
        lib
        pkgs
        namespace
        inputs
        system
        ;
    }).config
    (mkIf (cfg.type == "doom") (
      (import ./doom.nix {
        inherit
          config
          lib
          pkgs
          namespace
          inputs
          system
          ;
      }).config
    ))
    (mkIf (cfg.type == "centaur") (
      (import ./centaur.nix {
        inherit
          config
          lib
          pkgs
          namespace
          inputs
          system
          ;
      }).config
    ))
    (mkIf desktopCfg.kde.enable (
      (import ./xserver.nix {
        inherit
          config
          lib
          pkgs
          namespace
          inputs
          system
          ;
      }).config
    ))
    (mkIf desktopCfg.niri.enable (
      (import ./wayland.nix {
        inherit
          config
          lib
          pkgs
          namespace
          inputs
          system
          ;
      }).config
    ))
  ]);
}
