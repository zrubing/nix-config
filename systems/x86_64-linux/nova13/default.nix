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
  codexPackage = inputs.llm-agents.packages.${system}.codex;
  piPackage = inputs.llm-agents.packages.${system}.pi;
  multicaPackage = pkgs.${namespace}.multica;
  multicaK8s = import ./k8s/helm/multica {
    inherit pkgs;
    hostname = "nova13";
  };
in
{
  snowfallorg.users.jojo = {
    home.config = {
      home.sessionVariables.KUBECONFIG = "/home/jojo/.kube/config-k0s.yml";
    };
  };
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
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMrn032wZrsH01z36zJLqXRIVDiXK9Xx0gNXVClMhbT rd@jojo"
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
    gpui-shell.enable = lib.mkForce true;
    noctalia.enable = lib.mkForce false;
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
        programs.wechat.enable = lib.mkForce false;
        gpui-shell.enable = lib.mkForce true;
        noctalia.enable = lib.mkForce false;
      };

      # nova13 常通过 SSH 使用；不要继承桌面机的 `sudo -A` GUI askpass 习惯，
      # 否则无 TTY/无 askpass 环境下会报 “sudo: no askpass program specified”。
      programs.bash.shellAliases.sudo = lib.mkForce "command sudo";

      # SSLKEYLOGFILE 是桌面抓包调试用变量。nova13 上通过 SSH 使用 jojo 时不应强制
      # 走 GUI/桌面抓包配置，避免 sudo/su 到其他用户时继承 `/home/jojo/.ssl-key.log`。
      home.sessionVariables.SSLKEYLOGFILE = lib.mkForce "";
      home.sessionVariables.KUBECONFIG = "/home/jojo/.kube/config-k0s.yml";
    };

    #dae.enable = true;
    miho = {
      enable = true;
      extraConfig = import ./miho-extra-config.nix;
    };
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

  sops.age.sshKeyPaths = [ "/home/jojo/.ssh/id_ed25519" ];
  sops.secrets."multica/JWT_SECRET".sopsFile = ./secrets/multica.yaml;
  sops.secrets."multica/POSTGRES_PASSWORD".sopsFile = ./secrets/multica.yaml;

  environment.systemPackages = [
    hermesPackage
    codexPackage
    piPackage
    multicaPackage
    pkgs.kubernetes-helm
    pkgs.kubectl
  ];

  environment.etc."multica/values.yaml".source = multicaK8s.valuesFile;
  environment.etc."multica/extra-resources.yaml".source = multicaK8s.extraResourcesFile;
  environment.etc."multica/post-renderer".source = multicaK8s.postRenderer;

  systemd.services.multica-k0s-apply = {
    description = "Deploy Multica to k0s cluster via Helm";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
      "k0sworker.service"
    ];
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    path = with pkgs; [
      kubectl
      kubernetes-helm
      coreutils
      bash
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      kubeconfig="/home/jojo/.kube/config-k0s.yml"

      if [ ! -s "$kubeconfig" ]; then
        echo "kubeconfig not ready: $kubeconfig"
        exit 1
      fi

      for _ in $(seq 1 60); do
        if ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" cluster-info >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      jwt_secret=$(tr -d '\n' < ${config.sops.secrets."multica/JWT_SECRET".path})
      postgres_password=$(tr -d '\n' < ${config.sops.secrets."multica/POSTGRES_PASSWORD".path})

      ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" create namespace ${multicaK8s.namespace} --dry-run=client -o yaml | \
        ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" apply -f -

      ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" -n ${multicaK8s.namespace} create secret generic ${multicaK8s.secretName} \
        --from-literal=JWT_SECRET="$jwt_secret" \
        --from-literal=POSTGRES_PASSWORD="$postgres_password" \
        --from-literal=MULTICA_DEV_VERIFICATION_CODE="888888" \
        --dry-run=client -o yaml | \
        ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" apply -f -

      ${pkgs.kubernetes-helm}/bin/helm upgrade --install ${multicaK8s.releaseName} ${multicaK8s.chart} \
        --kubeconfig "$kubeconfig" \
        --namespace ${multicaK8s.namespace} \
        --create-namespace \
        --values /etc/multica/values.yaml \
        --post-renderer /etc/multica/post-renderer \
        --wait \
        --timeout 10m

      ${pkgs.kubectl}/bin/kubectl --kubeconfig "$kubeconfig" apply -f /etc/multica/extra-resources.yaml
    '';
  };

  # 本地通过 SSH 隧道推送到集群内 Zot（HTTP registry）。
  virtualisation.containers.registries.insecure = [
    "localhost:5000"
    "zot.zot.svc.cluster.local:5000"
    "10.144.144.4:30000"
  ];

  # 让 nova13 作为集群的 k0s worker（build/proxy 角色），与 zen14 保持同类配置。
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
    extraArgs = ''--kubelet-extra-args="--node-ip=10.144.200.3 --node-labels=wants-role/build=,wants-role/proxy= --register-with-taints=dedicated=nova13:NoSchedule --eviction-hard=memory.available<100Mi,nodefs.available<5%,nodefs.inodesFree<5%,imagefs.available<5% --image-gc-high-threshold=95 --image-gc-low-threshold=90 --eviction-pressure-transition-period=5m"'';
    spec.api.address = "0.0.0.0";
    spec.workerProfiles = [
      {
        name = "default";
        values = {
          evictionHard = {
            "memory.available" = "100Mi";
            # 磁盘压力阈值：剩余 5% 时才触发，等价于 95% 使用率
            "nodefs.available" = "5%";
            "nodefs.inodesFree" = "5%";
            "imagefs.available" = "5%";
          };
          # 镜像 GC 默认阈值通常更早触发；显式提高到 95%，避免在 ~85% 使用率就进入磁盘回收/压力流程
          imageGCHighThresholdPercent = 95;
          imageGCLowThresholdPercent = 90;
        };
      }
    ];
  };

  environment.etc."profile.d/hermes-agent-sslkeylog.sh".text = ''
    if [ "''${USER:-}" = "hermes-agent" ]; then
      export SSLKEYLOGFILE=/home/hermes-agent/.ssl-key.log
    fi
  '';

  systemd.tmpfiles.rules = [
    "d /etc/k0s 0755 root root -"
    "d /opt/local-path-provisioner 0777 root root -"
    "d /opt/local-path-provisioner/woodpecker-cache 0777 root root -"
    "d /opt/local-path-provisioner/woodpecker-cache/buildkit-cache 0777 root root -"
    "d /opt/local-path-provisioner/woodpecker-cache/npm-cache 0777 root root -"
    "d /opt/local-path-provisioner/woodpecker-cache/mvn-cache 0777 root root -"
    "d /opt/local-path-provisioner/woodpecker-cache/maven-target-cache 0777 root root -"
    "d /home/hermes-agent/.hermes 0750 hermes-agent users -"
    "d /home/hermes-agent/.hermes/logs 0750 hermes-agent users -"
    "f /home/hermes-agent/.hermes/.env 0640 hermes-agent users -"
    "d /home/hermes-agent/.codex 0700 hermes-agent users -"
    "d /home/hermes-agent/.pi 0700 hermes-agent users -"
    "f /home/hermes-agent/.ssl-key.log 0600 hermes-agent users -"
    "d /var/log/hermes-gateway-hermes-agent 0700 hermes-agent users -"
    "f /var/log/hermes-gateway-hermes-agent/gateway.log 0600 hermes-agent users -"
  ];

  systemd.services.woodpecker-buildkit-cache-gc = {
    description = "GC old Woodpecker BuildKit local cache";
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [
      coreutils
      findutils
      util-linux
      gawk
    ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      cache_dir="/opt/local-path-provisioner/woodpecker-cache/buildkit-cache"
      retention_days=7
      high_watermark=85

      if [ ! -d "$cache_dir" ]; then
        echo "cache dir not found: $cache_dir, skip"
        exit 0
      fi

      chmod 0777 "$cache_dir" || true

      echo "gc old buildkit cache files older than $retention_days days"
      find "$cache_dir" -mindepth 1 -mtime +"$retention_days" -print -delete || true

      usage="$(df -P /opt/local-path-provisioner | awk 'NR==2{gsub("%","",$5); print $5}')"
      if [ "''${usage:-0}" -ge "$high_watermark" ]; then
        echo "disk usage ''${usage}% >= ''${high_watermark}%, wipe buildkit cache"
        find "$cache_dir" -mindepth 1 -print -delete || true
      fi
    '';
  };

  systemd.timers.woodpecker-buildkit-cache-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.services.hermes-gateway-hermes-agent = {
    description = "Hermes gateway daemon for hermes-agent";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [
      codexPackage
      piPackage
    ];
    serviceConfig = {
      Type = "simple";
      User = "hermes-agent";
      Group = "users";
      WorkingDirectory = "/home/hermes-agent";
      Environment = [
        "HOME=/home/hermes-agent"
        "HERMES_HOME=/home/hermes-agent/.hermes"
        "SSLKEYLOGFILE=/home/hermes-agent/.ssl-key.log"
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
