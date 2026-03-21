{
  config,
  inputs,
  lib,
  pkgs,
  system,
  namespace,
  ...
}:
{
  snowfallorg.users.jojo = { };
  snowfallorg.users.hiar = {
    home.config = config.${namespace}.home.extraOptions;
  };

  time.timeZone = "Asia/Shanghai";

  imports = [ ./hardware.nix ];

  system.stateVersion = "25.11";

  users.mutableUsers = true;
  users.users = {

    jojo = {
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
        "docker"
        "podman"
      ];
      initialPassword = "test";
    };

    hiar = {
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
        "docker"
        "podman"
      ];
      initialPassword = "test";
    };
  };

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    tailscale.headscaleAuthkeyFile = "headscale-authkey-nova13.age";
    nix-ld.enable = false;
    noctalia.enable = lib.mkForce false;
    #builder.enable = true;
    desktop.niri.enable = lib.mkForce false;

    home.extraOptions = {
      # nova13 的 sops-nix 使用主机 SSH key 解密，避免依赖用户家目录私钥。
      sops.age.sshKeyPaths = lib.mkForce [ "/etc/ssh/ssh_host_ed25519_key" ];

      ${namespace} = {
        ccr-router.enable = lib.mkForce false;
        desktop.niri.enable = lib.mkForce false;
        emacs.enable = lib.mkForce false;
        devpackages.treeSitter.enable = lib.mkForce false;
        devpackages.vscodeTools.enable = lib.mkForce false;
        devpackages.languageServers.enable = lib.mkForce false;
        devpackages.gui.enable = lib.mkForce false;
        modules.packages.gui.enable = lib.mkForce false;
        modules.packages.emacsTools.enable = lib.mkForce false;
        modules.packages.ocr.enable = lib.mkForce false;
        modules.packages.tools.ai.llmAgents.enable = lib.mkForce false;
        ghostty.enable = lib.mkForce false;
        modules.fcitx5.enable = lib.mkForce false;
        programs.wechat-uos.enable = lib.mkForce false;
        noctalia.enable = lib.mkForce false;
      };
    };

    #dae.enable = true;
    miho.enable = true;
    desktop-programs.enable = false;

    restic.enable = true;
  };

  # home = {

  #   ${namespace} = {
  #     terminal = "alacritty";
  #     emacs.enable = true;
  #     vcs.user = {
  #       name = "jojo";
  #       email = "a@b.com";
  #     };
  #   };

  #   home.packages = with pkgs; [ ];

  # };

  # 合盖不休眠，适合合盖外接屏幕或后台持续任务。
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # 启用电源策略并默认切到 performance，让散热风扇更积极介入。
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  systemd.services.default-performance-profile = {
    description = "Set default power profile to performance";
    wants = [ "power-profiles-daemon.service" ];
    after = [ "power-profiles-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance || true
    '';
  };

  networking.networkmanager.enable = true;

}
