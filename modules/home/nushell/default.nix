{ lib, pkgs, ... }: {
  programs.nushell = {
    enable = true;
    configFile.source = ./config.nu;
  };

  programs.nushell.extraConfig = ''
    use ${./exstd.nu} *
    use ${./completions-cache.nu} *

    use ${./nix-rebuild.nu} *
    use ${./nix-search.nu} *
    use ${./docker.nu} *

    ${lib.optionalString (!pkgs.stdenv.isDarwin) ''
      use ${./protontricks.nu} *
      use ${./linux-utils.nu} *
    ''}

    ${lib.optionalString pkgs.stdenv.isDarwin ''
      use ${./macos-defaults.nu} *
      use ${./gcloud.nu} *
      use ${./kubectl.nu} *
    ''}

    plugin add ${pkgs.nushellPlugins.formats}/bin/nu_plugin_formats
  '';
}
