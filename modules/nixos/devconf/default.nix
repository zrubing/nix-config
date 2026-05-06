{ pkgs, ... }:
{
  # programs.nix-ld.enable = true;
  programs.npm = {

    enable = true;
    package = pkgs.nodejs;
    npmrc = ''
      prefix = ''${HOME}/.npm-global
    '';
  };

}
