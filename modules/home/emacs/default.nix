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

  # tdlib's transitive shared library dependencies
  tdlib-pkg = pkgs-unstable.tdlib;
  tdlib-so-deps = [
    (lib.getLib pkgs-unstable.openssl)
    (lib.getLib pkgs-unstable.zlib)
    (lib.getLib pkgs-unstable.stdenv.cc.cc.lib)
  ];

  doom-repo = "${config.xdg.configHome}/emacs.doom/.local/straight/repos";

  envConfig = ''
    export PATH="${config.xdg.configHome}/emacs.doom/bin:$PATH"
    export EAT_SHELL_INTEGRATION_DIR="${doom-repo}/eat/integration"
  '';
  envExtra = lib.mkAfter ''
    ${envConfig}
  '';
  bashrcExtra = lib.mkAfter ''
    ${envConfig}
    
    if command -v direnv >/dev/null 2>&1; then
      if [ -n "$CLAUDECODE" ]; then
        eval "$(direnv hook bash)"
        eval "$(DIRENV_LOG_FORMAT= direnv export bash)"
      fi
    fi
  '';
  shellAliases = {
    e = "emacsclient --create-frame"; # gui
    et = "emacsclient --create-frame --tty"; # terminal
  };

  commonConfig = {
    programs.bash.bashrcExtra = bashrcExtra;
    programs.zsh.envExtra = lib.mkAfter ''
      ${envConfig}
    '';
    home.shellAliases = shellAliases;
    programs.nushell.shellAliases = shellAliases;
    programs.fish.shellAliases = shellAliases;
    programs.fish.shellInit = envExtra;

    home.activation.installEmacslib = hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${librime-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.librime}/ ${librime-dir}/
      mkdir -p ${rime-data-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.rime-ice}/ ${rime-data-dir}/
      mkdir -p ${tdlib-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${tdlib-pkg}/ ${tdlib-dir}/
      # Copy transitive .so dependencies (openssl, zlib, libstdc++) so
      # the rsync'd tdlib is self-contained and survives nix GC.
      ${lib.concatStringsSep "\n" (
        map (dep: "${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${dep}/lib/ ${tdlib-dir}/lib/")
          tdlib-so-deps
      )}
      # Patch RUNPATH to $ORIGIN so libtdjson.so finds co-located deps
      for so in ${tdlib-dir}/lib/libtdjson.so*; do
        if [ -L "$so" ] || ! file "$so" | grep -q 'ELF'; then continue; fi
        ${pkgs.patchelf}/bin/patchelf --set-rpath '\$ORIGIN' "$so" 2>/dev/null || true
      done
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

    # (mkIf desktopCfg.niri.enable (
    #   (import ./wayland.nix {
    #     inherit
    #       config
    #       lib
    #       pkgs
    #       namespace
    #       inputs
    #       system
    #       ;
    #   }).config
    # ))
  ]);
}
