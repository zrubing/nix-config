{ ... }:
{
  # programs.nix-ld.enable = true;
  programs.npm = {

    enable = true;
    npmrc = ''
      prefix = ''${HOME}/.npm-global
    '';
  };

}
