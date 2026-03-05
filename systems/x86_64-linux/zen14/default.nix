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
  snowfallorg.users.hiar = { };

  time.timeZone = "Asia/Shanghai";

  imports = [ ./hardware.nix ];

  system.stateVersion = "25.11";

  users.mutableUsers = true;
  users.users = {

    jojo = {
      uid = 1000;
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
        "docker"
        "podman"
      ];
      initialPassword = "test";

      # NOTICE THIS PART
      subUidRanges = [

        {
          startUid = 100000;
          count = 200000;
        }
        {
          startUid = 300000;
          count = 400000;
        }
      ];
      subGidRanges = [

        {
          startGid = 100000;
          count = 200000;
        }
        {
          startGid = 300000;
          count = 400000;
        }
      ];

    };

    hiar = {
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
      ];
      initialPassword = "test";
    };
  };

  modules.secrets.desktop.enable = true;

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    tailscale.headscaleAuthkeyFile = "headscale-authkey-zen14.age";
    #builder.enable = true;
    desktop = {
      #kde.enable = true;
      niri.enable = true;
    };

    #dae.enable = true;
    miho.enable = true;
    ollama.enable = false;
    desktop-programs.enable = false;

    restic.enable = true;
  };

  networking.networkmanager.enable = true;

  networking.extraHosts = ''
    127.0.0.1 zot.zot.svc.cluster.local
  '';

  # 本地通过 SSH 隧道推送到集群内 Zot（HTTP registry）
  virtualisation.containers.registries.insecure = [
    "localhost:5000"
    "zot.zot.svc.cluster.local:5000"
    "10.144.144.4:30000"
  ];

  # 让 zen14 作为目标集群的 k0s worker（build/proxy 角色）
  system.activationScripts.k0sWritableEtc = {
    deps = [ "specialfs" ];
    text = ''
      if [ -L /etc/k0s ]; then
        rm -f /etc/k0s
      elif [ -e /etc/k0s ] && [ ! -d /etc/k0s ]; then
        rm -f /etc/k0s
      fi
      mkdir -p /etc/k0s
      chmod 0755 /etc/k0s
    '';
  };
  system.activationScripts.etc.deps = lib.mkForce [
    "users"
    "groups"
    "specialfs"
    "k0sWritableEtc"
  ];
  environment.etc."k0s/k0s.yaml".enable = lib.mkForce false;

  services.k0s = {
    enable = false;
    package = inputs.k0s-nix.packages.${system}.k0s;
    role = "worker";
    # 首次 join 需要提前放置 token 文件到 /var/lib/k0s/k0stoken
    tokenFile = "/var/lib/k0s/k0stoken";
    dataDir = "/var/lib/k0s";
    extraArgs = ''--kubelet-extra-args="--node-ip=10.144.200.2 --node-labels=wants-role/build=,wants-role/proxy="'';
    spec.api.address = "0.0.0.0";
    spec.workerProfiles = [{
      name = "default";
      values = {
        evictionHard = {
          "memory.available" = "100Mi";
          "nodefs.available" = "5%";
          "nodefs.inodesFree" = "5%";
          "imagefs.available" = "5%";
        };
      };
    }];
  };

  systemd.tmpfiles.rules = [
    "d /etc/k0s 0755 root root -"
    "d /opt/local-path-provisioner 0777 root root -"
  ];

  environment.systemPackages = with pkgs; [
    inputs.k0s-nix.packages.${system}.k0s
    kubectl
    k9s
    (writeShellScriptBin "k0s-join-via-ali" ''
      set -euo pipefail

      systemctl restart k0sworker.service
      systemctl --no-pager --full status k0sworker.service || true
    '')
  ];

  # sudo 免密码
  security.sudo.extraRules = [
    {
      users = [ "jojo" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

}
