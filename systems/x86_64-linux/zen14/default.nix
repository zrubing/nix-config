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

  # 通过 ali(10.144.200.1) 转发到集群控制面网段(10.144.100.0/24)
  # 使用 oneshot 路由注入，避免不同网络后端下静态路由选项差异
  systemd.services.k0s-route-via-ali = {
    description = "Add route to k0s controller subnet via ali gateway";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "easytier-net-zen14.service" ];
    wants = [ "network-online.target" "easytier-net-zen14.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ iproute2 ];
    script = ''
      # 网关由 EasyTier 提供，接口就绪后写入路由
      ip route replace 10.144.100.0/24 via 10.144.200.1
    '';
  };

  # EasyTier 的 tun0 仅承载 10.144.200.0/24 链路，
  # 对 10.144.144.1:6443 走本机 OUTPUT DNAT 到 ali 中转入口。
  systemd.services.k0s-apiserver-via-ali-relay = {
    description = "Redirect k0s apiserver traffic to ali relay endpoint";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "easytier-net-zen14.service" ];
    wants = [ "network-online.target" "easytier-net-zen14.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ nftables ];
    script = ''
      nft delete table ip zen14_k0s_relay 2>/dev/null || true
      nft -f - <<'EOF'
      table ip zen14_k0s_relay {
        chain output {
          type nat hook output priority dstnat; policy accept;
          ip daddr 10.144.144.1 tcp dport 6443 dnat to 10.144.200.1:6443
        }
      }
      EOF
    '';
  };

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
    enable = true;
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
