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
  pkgs-unstable = import inputs.nixpkgs-unstable {inherit system; config.allowUnfree = true; };


  cfg = config.${namespace}.modules.packages;
in
{

  options.${namespace}.modules.packages = {
    enable = lib.mkEnableOption "packages";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      grim
      satty

      nautilus
      cherry-studio
      redisinsight
      feishu
      wechat-uos
      conda
      vscode
      ollama-rocm
      # for aider
      python312Packages.playwright
      code-cursor
      mysql84
      wireshark-qt
      pkgs-unstable.tdlib
      pkgs-unstable.localsend
      #pkgs.${namespace}.aider
      #pkgs-unstable.aider-chat-with-playwright
      pkgs-unstable.aider-chat
      pkgs-unstable.claude-code
      pkgs-unstable.mise
      pkgs.${namespace}.wl-ocr
      tesseract
      pkgs-unstable.tailscale
      pkgs-unstable.dbeaver-bin
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
