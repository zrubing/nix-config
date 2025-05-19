{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};

  cfg = config.${namespace}.modules.packages;
in
{

  options.${namespace}.modules.packages = {
    enable = lib.mkEnableOption "packages";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      wechat-uos

      vscode
      ollama-rocm
      # for aider
      python312Packages.playwright
      code-cursor
      mysql84
      wireshark-qt
      pkgs-unstable.tdlib
      pkgs-unstable.localsend
      pkgs.${namespace}.aider
      pkgs-unstable.mise
      pkgs.${namespace}.wl-ocr
      tesseract
      pkgs-unstable.tailscale
      dbeaver-bin
      devenv
      devpod
      devbox
      zed-editor
      sioyek
      libreoffice
    ];

    programs = {
      direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };
    };
  };

}
