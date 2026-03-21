{
  config,
  inputs,
  lib,
  pkgs,
  system,
  namespace,
  ...
}:
let
  hermesPackage = inputs.llm-agents.packages.${system}.hermes-agent;
in
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

    "hermes-agent" = {
      isNormalUser = true;
      createHome = true;
      home = "/home/hermes-agent";
      group = "users";
      extraGroups = [
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
    noctalia.enable = lib.mkForce true;
    #builder.enable = true;
    desktop.niri.enable = lib.mkForce true;

    home.extraOptions = {
      ${namespace} = {
        ccr-router.enable = lib.mkForce false;
        desktop.niri.enable = lib.mkForce true;
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
        noctalia.enable = lib.mkForce true;
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

  environment.systemPackages = [
    hermesPackage
  ];

  systemd.tmpfiles.rules = [
    "d /home/hermes-agent/.hermes 0750 hermes-agent users -"
    "d /home/hermes-agent/.hermes/logs 0750 hermes-agent users -"
    "f /home/hermes-agent/.hermes/.env 0640 hermes-agent users -"
    "d /var/log/hermes-gateway-hermes-agent 0700 hermes-agent users -"
    "f /var/log/hermes-gateway-hermes-agent/gateway.log 0600 hermes-agent users -"
  ];

  systemd.services.hermes-gateway-hermes-agent = {
    description = "Hermes gateway daemon for hermes-agent";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      User = "hermes-agent";
      Group = "users";
      WorkingDirectory = "/home/hermes-agent";
      Environment = [
        "HOME=/home/hermes-agent"
        "HERMES_HOME=/home/hermes-agent/.hermes"
        "PYTHONPATH=${pkgs.python3Packages.python-telegram-bot}/${pkgs.python3.sitePackages}"
      ];
      EnvironmentFile = "-/home/hermes-agent/.hermes/.env";
      ExecStart = "${hermesPackage}/bin/hermes gateway run";
      Restart = "always";
      RestartSec = 5;
      UMask = "0077";
      # Write logs to a dedicated file so hermes-agent can read without broad journal permissions.
      StandardOutput = "append:/var/log/hermes-gateway-hermes-agent/gateway.log";
      StandardError = "append:/var/log/hermes-gateway-hermes-agent/gateway.log";
    };
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (
        subject.user == "hermes-agent" &&
        action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "hermes-gateway-hermes-agent.service" &&
        ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0
      ) {
        return polkit.Result.YES;
      }
    });
  '';

  networking.networkmanager.enable = true;

}
