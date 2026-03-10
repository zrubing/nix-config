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
  piBin = "${inputs.llm-agents.packages.${system}.pi}/bin/pi";
in
{
  snowfallorg.users.jojo = {
    home.config = {
      home.sessionVariables.KUBECONFIG = "/home/jojo/.kube/config-k0s.yml";
    };
  };
  snowfallorg.users.hiar = {
    home.config = lib.mkMerge [
      config.${namespace}.home.extraOptions
      {
        ${namespace}.programs.wechat-uos.enable = true;
      }
    ];
  };

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
        "docker"
        "podman"
      ];
      initialPassword = "test";
    };

    agent = {
      isSystemUser = true;
      group = "agent";
      home = "/var/lib/agent";
      createHome = true;
      shell = "/run/current-system/sw/bin/nologin";
    };
  };

  users.groups.agent = { };

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
    miho = {
      enable = true;
      extraConfig = import ./miho-extra-config.nix;
    };
    ollama.enable = false;
    desktop-programs.enable = false;

    restic.enable = true;
  };

  networking.networkmanager.enable = true;

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "pi-as-agent" ''
      exec sudo -u agent ${piBin} "$@"
    '')
  ];

  # 本地通过 SSH 隧道推送到集群内 Zot（HTTP registry）
  virtualisation.containers.registries.insecure = [
    "localhost:5000"
    "zot.zot.svc.cluster.local:5000"
    "10.144.144.4:30000"
  ];

  # 让 zen14 作为集群的 k0s worker（build/proxy 角色）
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
  environment.etc."k0s/containerd.d/mirrors.toml".text = ''
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."zot.zot.svc.cluster.local:5000"]
      endpoint = ["http://10.144.144.4:30000", "http://10.144.144.1:30000"]

    [plugins."io.containerd.grpc.v1.cri".registry.configs."zot.zot.svc.cluster.local:5000".tls]
      insecure_skip_verify = true
  '';

  services.k0s = {
    enable = true;
    package = inputs.k0s-nix.packages.${system}.k0s;
    role = "worker";
    # 首次 join 需要提前放置 token 文件到 /var/lib/k0s/k0stoken
    tokenFile = "/var/lib/k0s/k0stoken";
    dataDir = "/var/lib/k0s";
    extraArgs = ''--kubelet-extra-args="--node-ip=10.144.200.2 --node-labels=wants-role/build=,wants-role/proxy= --register-with-taints=dedicated=zen14:NoSchedule"'';
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
    "d /var/lib/pi-shared 0750 root agent -"
    "d /var/lib/pi-shared/agent 0750 root agent -"
    "d /var/lib/agent/.pi 0750 agent agent -"
    "d /var/lib/agent/.pi/agent 0750 agent agent -"
    "L+ /var/lib/agent/.pi/agent/skills - - - - /var/lib/pi-shared/agent/skills"
    "L+ /var/lib/agent/.pi/agent/extensions - - - - /var/lib/pi-shared/agent/extensions"
    "L+ /var/lib/agent/.pi/agent/models.json - - - - /var/lib/pi-shared/agent/models.json"
  ];

  system.activationScripts.agentPiSharedConfig = {
    deps = [ "users" "groups" ];
    text = ''
      set -eu
      src_base=/home/jojo/.pi/agent
      dst_base=/var/lib/pi-shared/agent

      ${pkgs.coreutils}/bin/mkdir -p "$dst_base"

      if [ -d "$src_base/skills" ]; then
        ${pkgs.coreutils}/bin/rm -rf "$dst_base/skills"
        ${pkgs.coreutils}/bin/cp -rT "$src_base/skills" "$dst_base/skills"
        ${pkgs.coreutils}/bin/chown -R root:agent "$dst_base/skills"
        ${pkgs.coreutils}/bin/chmod -R u=rwX,g=rX,o= "$dst_base/skills"
      fi

      if [ -d "$src_base/extensions" ]; then
        ${pkgs.coreutils}/bin/rm -rf "$dst_base/extensions"
        ${pkgs.coreutils}/bin/cp -rT "$src_base/extensions" "$dst_base/extensions"
        ${pkgs.coreutils}/bin/chown -R root:agent "$dst_base/extensions"
        ${pkgs.coreutils}/bin/chmod -R u=rwX,g=rX,o= "$dst_base/extensions"
      fi

      if [ -f "$src_base/models.json" ]; then
        ${pkgs.coreutils}/bin/install -D -m 0640 -o root -g agent "$src_base/models.json" "$dst_base/models.json"
      fi
    '';
  };


  # sudo 免密码
  security.sudo.extraRules = [
    {
      users = [ "jojo" ];
      runAs = "agent";
      commands = [
        {
          command = piBin;
          options = [ "NOPASSWD" ];
        }
      ];
    }
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
