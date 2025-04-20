{ ... }:
{
  programs.npm = {

    enable = true;
    npmrc = ''
      prefix = ''${HOME}/.npm-global
    '';
  };

}
