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
  hermesWrapped = pkgs.writeShellScriptBin "hermes" ''
    set -a
    . ${config.sops.templates."hermes-agent.env".path}
    set +a

    exec ${lib.getExe hermesPackage} "$@"
  '';
  piPackage = inputs.llm-agents.packages.${system}.pi;
  mysecrets = inputs.mysecrets;
  multicaPackage = pkgs.${namespace}.multica;
  tradingagentsPackage = pkgs.${namespace}.tradingagents;
  tradingagentsWrapped = pkgs.writeShellScriptBin "tradingagents" ''
    set -a
    . ${config.sops.templates."tradingagents.env".path}
    set +a

    exec ${lib.getExe tradingagentsPackage} "$@"
  '';
  multicaK8s = import ./k8s/helm/multica {
    inherit pkgs;
    hostname = "nova13";
  };
in
{
  snowfallorg.users.jojo = {
    home.config = lib.mkMerge [
      # 注意：${namespace}.home.extraOptions 已由 modules/nixos/home-manager 自动应用为
      # jojo 的 home.config，这里不能再 merge 一次，否则列表选项（如 dsh.web.trustedHosts）
      # 会被 concat 成双份（enable 等布尔幂等所以之前没暴露）。
      {
        home.sessionVariables.KUBECONFIG = "/home/jojo/.kube/config-k0s.yml";
        home.activation.configureMultica = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        config_file="$HOME/.multica/config.json"
        mkdir -p "$(dirname "$config_file")"
        tmp_file="$(mktemp "$HOME/.multica/config.json.XXXXXX")"

        if [ -f "$config_file" ]; then
          if ! ${pkgs.jq}/bin/jq \
            '. + {server_url: "http://multica-api.local", app_url: "http://multica.local"}' \
            "$config_file" > "$tmp_file"; then
            printf '{"server_url":"http://multica-api.local","app_url":"http://multica.local"}\n' > "$tmp_file"
          fi
        else
          printf '{"server_url":"http://multica-api.local","app_url":"http://multica.local"}\n' > "$tmp_file"
        fi

        chmod 600 "$tmp_file"
        mv -f "$tmp_file" "$config_file"
        '';
      }
    ];
  };
  snowfallorg.users.hiar = {
    home.config = config.${namespace}.home.extraOptions;
  };

  networking.hosts = {
    "10.144.200.3" = [
      "multica.local"
      "multica-api.local"
      "dsh.local"
    ];
  };

  time.timeZone = "Asia/Shanghai";

  imports = [ ./hardware.nix ];

  system.stateVersion = "25.11";

  # CapsLock 当 Ctrl 用，和 zen14 的 niri（ctrl:nocaps）一致。
  # 这是「CapsLock 也变 Ctrl」，左边那个 Ctrl 仍在原位；真要两者对调是 ctrl:swapcaps。
  # mkForce 是因为 modules/nixos/locale 全局设了 caps:escape。
  # 同一份值也会被 kmscon 读走（console 模块开了 useXkbConfig）。
  services.xserver.xkb.options = lib.mkForce "ctrl:nocaps,compose:rctrl,terminate:ctrl_alt_bksp";

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
        # console 模块把背光节点交给 video 组写，否则改亮度要 root。
        "video"
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

  # nova13 上 jojo 允许免密码 sudo，便于 SSH/自动化操作。
  security.sudo.extraRules = [
    {
      users = [ "jojo" ];
      commands = [
        {
          command = "ALL";
          options = [
            "NOPASSWD"
            "SETENV"
          ];
        }
      ];
    }
  ];

  ${namespace} = {
    user.name = "jojo";

    # 与 zen14 同一个 CachyOS 内核派生（同 rev + 同 override ⇒ 同 store 路径），
    # 换上来不需要重编内核，直接 nix copy 即可。BBR 作为默认拥塞控制。
    kernel.cachyos.enable = true;
    # 复用 zen14 同一套 tcp-forward 定义：loopback IP / .local 名字跨机器一致。
    # prod 写库默认不自启，需要时 systemctl start tcp-forward-prod-mysql。
    tcp-forward = {
      enable = true;
      forwards = {
        test-mysql = {
          listenIp = "127.0.0.2";
          listenPort = 3306;
          upstreamHostSecret = "mysql_proxy/test/target_host";
          upstreamPort = 3306;
          hostnames = [ "test.mysql.local" ];
        };
        prod-mysql = {
          listenIp = "127.0.0.3";
          listenPort = 3306;
          upstreamHostSecret = "mysql_proxy/prod/target_host";
          upstreamPort = 3306;
          hostnames = [ "prod.mysql.local" ];
          autoStart = false;
        };
      };
    };
    networking.wifi.enable = true;
    tailscale.headscaleAuthkeyFile = "headscale-authkey-nova13.age";
    nix-ld.enable = false;
    gpui-shell.enable = lib.mkForce false;
    wayle.enable = lib.mkForce false;
    noctalia.enable = lib.mkForce false;
    #builder.enable = true;
    desktop.niri.enable = lib.mkForce false;

    # 这台机器没有桌面环境，只有 tty。控制台换 kmscon（真字体/24 位色/中文），
    # 合盖只关背光不挂起（它是 k0s worker + 中转节点，必须常驻）。
    # 2560x1600 面板上 18px 太小，26px 约 160 列 x 50 行。
    console = {
      enable = true;
      fontSize = 26;
    };


    home.extraOptions = {
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
        modules.packages.tools.ai.ollama.enable = lib.mkForce false;
        ghostty.enable = lib.mkForce false;
        modules.fcitx5.enable = lib.mkForce false;
        programs.wechat.enable = lib.mkForce false;
        gpui-shell.enable = lib.mkForce false;
        wayle.enable = lib.mkForce false;
        noctalia.enable = lib.mkForce false;

        # 启用 multica home module：装 CLI + 把 daemon 作为 systemd user service 托管
        # （见 modules/home/multica/default.nix）。配合下面的 linger，daemon 不再寄生在
        # 某个 SSH session 里，且升级切二进制时 graceful drain 能真正生效。
        modules.multica.enable = true;

        # dsh（DeepSeek Harness）在 jojo 共享 home 已启用；访问走 nova13 的 Caddy 反代
        # （http://dsh.local → 127.0.0.1:3080）。注意：dsh 禁止 --host 0.0.0.0
        # （“intentionally not supported yet for safety”，会暴露 RCE），必须保持回环绑定。
        modules.dsh.web.trustedHosts = [ "dsh.local" ];
        modules.dsh.web.host = lib.mkForce "127.0.0.1";

        # 这台机器只有 tty：提示符与 tmux 状态栏各刷一行电量/负载/内存
        # （modules/home/sys-status，默认关闭）。zen14 有桌面，不启用以免重复。
        modules."sys-status".enable = true;

        # nova13 无桌面（无 dconf 服务），devconf 的 virt-manager dconf 设置会让
        # home-manager 激活在 dconfSettings 步骤失败（D-Bus 连不上 ca.desrt.dconf），
        # 进而连带 dsh-web 等 user service 都无法生成。这里显式关闭。
        modules.devconf.enable = lib.mkForce false;
      };

      # nova13 常通过 SSH 使用；不要继承桌面机的 `sudo -A` GUI askpass 习惯，
      # 否则无 TTY/无 askpass 环境下会报 “sudo: no askpass program specified”。
      programs.bash.shellAliases.sudo = lib.mkForce "command sudo";

      # SSLKEYLOGFILE 是桌面抓包调试用变量。nova13 上通过 SSH 使用 jojo 时不应强制
      # 走 GUI/桌面抓包配置，避免 sudo/su 到其他用户时继承 `/home/jojo/.ssl-key.log`。
      home.sessionVariables.SSLKEYLOGFILE = lib.mkForce "";
      home.sessionVariables.KUBECONFIG = "/home/jojo/.kube/config-k0s.yml";
    };

    # fakeip v6 闸门，段与 zen14 同源（段选择理由见 zen14 同处注释与
    # docs/net-invariants.md）。本机原生 v6 的国内路由质量明显优于对比机型，
    # 开闸后实际能用上 v6 的收益更大。关闭：设成 null 或删掉这行后 rebuild。
    netPolicy.fakeipInet6Range = "2001:db8:1::/48";
    # 旁路 socks 端口（7899）：固定走代理组，完全不看 rules。
    # 存在理由与 zen14 同处注释一致：rules 把代理服务器自身地址判成直连，
    # 节点某地址族被封时只能靠独立端口绕过。只绑 127.0.0.1。
    netPolicy.forcedProxySocksPort = 7899;

    # 代理客户端三选一：miho / sib / dae（互斥见各模块的断言）。
    #
    # nova13 用 sib（2026-10-27 决策）。依据是同一个 xhttp 节点在两套客户端下的
    # 对照测量（同网段、同时刻、跨主机交替请求）：
    #   · sib：6/6 成功，中位 0.42s
    #   · mihomo：2/4 成功，中位 1.58s
    # 机制上的原因不是「哪个客户端更快」，而是两家的 TUN 接管范围不同：
    #   · mihomo 只对 198.18.0.0/30 做策略路由，xray 的 mark 0x66 落到 main 表
    #     直连 CF 前置，绕开了节点
    #   · sib 用 nfqueue 抓全部流量，xray 的出站同样走节点转发
    # 回切代价：enable 互换即可，但要重跑 net-policy-check（里面有 tun DNS 断言）。
    miho = {
      enable = false;
      # build 节点共用配置（zen14 与 nova13 同源，避免两份漂移）。
      # 保留引用是为了回切时不多一步：mihomo 不启用时它不参与求值。
      extraConfig = import ../../../modules/nixos/miho/build-node-extra-config.nix;
    };
    sib.enable = true;
    dae.enable = false;
    # 主线组是 selector，成员固定、选择由探针写；没有探针就会一直停在
    # 配置里的第一个成员上。两台客户端用同一份 sib 密文，所以这里必须同步开。
    proxyQuality = {
      enable = true;
      interval = "10min";
      quickCheck = {
        enable = true;
        interval = "60s";
        fails = 2;
      };
    };
    # 同一个 miho-conf 两台机器共用，里面的中转节点指向本机 socks5，
    # 所以 nova13 也得起这个客户端，否则那个节点在 nova13 上是死的。
    tuic-client = {
      enable = true;
      instances = {
        us = {
          serverSecret = "relay/tuic-server";
          listen = "127.0.0.1:12190";
        };
        # 上游 B：mihomo 的一个 tuic 节点指向 12191（服务商/机房见密文）。
        jp = {
          serverSecret = "relay/tuic-server-jp";
          listen = "127.0.0.1:12191";
        };
      };
    };
    # 同理：miho-conf 里的两个 vless 节点（1086 / 1087）也是指向本机
    # xray-client 的 socks5。不启这个客户端，那两个节点在 nova13
    # 上就是无人监听的死节点（xhttp 是 Xray 的传输层，mihomo 不原生实现）。
    #
    # userId 取 987：本机 980-986 已被 tuic-client/wpa_supplicant/k0s 组件占满，
    # 983 尤其被 kube-apiserver 占用，不能和 zen14 用同一个值。
    xray-client = {
      enable = true;
      configSecretFile = "xray-client-conf.json.age";
      userId = 987;
    };
    desktop-programs.enable = false;
    # nova13 是 k0s worker（build/proxy 角色），不需要桌面虚拟化栈（libvirtd/qemu/virt-manager）。
    # virt 模块默认启用，这里显式关闭。
    virt.enable = false;

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
  sops.secrets."anthropic/base_url".sopsFile = "${mysecrets}/secrets/env.yaml";
  sops.secrets."anthropic/api_key".sopsFile = "${mysecrets}/secrets/env.yaml";
  sops.secrets."deepseek/api_key".sopsFile = "${mysecrets}/secrets/env.yaml";
  sops.secrets."zhipu/api_key".sopsFile = "${mysecrets}/secrets/env.yaml";
  sops.secrets."alphavantage/api_key".sopsFile = "${mysecrets}/secrets/env.yaml";
  sops.templates."tradingagents.env" = {
    owner = "jojo";
    group = "users";
    mode = "0400";
    content = ''
      DEEPSEEK_API_KEY=${config.sops.placeholder."deepseek/api_key"}
      ZHIPU_API_KEY=${config.sops.placeholder."zhipu/api_key"}
      ALPHA_VANTAGE_API_KEY=${config.sops.placeholder."alphavantage/api_key"}
    '';
  };

  sops.templates."hermes-agent.env" = {
    owner = "hermes-agent";
    group = "users";
    mode = "0440";
    content = ''
      DEEPSEEK_API_KEY=${config.sops.placeholder."deepseek/api_key"}
      GLM_API_KEY=${config.sops.placeholder."zhipu/api_key"}
    '';
  };

  environment.systemPackages = [
    hermesWrapped
    piPackage
    multicaPackage
    tradingagentsWrapped
    pkgs.kubernetes-helm
    pkgs.kubectl
  ];

  environment.etc."multica/values.yaml".source = multicaK8s.valuesFile;
  environment.etc."multica/extra-resources.yaml".source = multicaK8s.extraResourcesFile;
  environment.etc."multica/post-renderer".source = multicaK8s.postRenderer;

  systemd.services.multica-k0s-apply = {
    description = "Deploy Multica to k0s cluster via Helm";
    # k0s API（6443）从 2026-10-28 起 TLS 握手超时，这个 oneshot 无限重试，
    # 而它挂在 multi-user.target 下：每次 switch 的 activation 都会被拖住，
    # 并一直持有 /run/nixos/switch-to-configuration.lock，后续 rebuild 也会卡。
    # 集群恢复后把下面改回 [ "multi-user.target" ] 并手动 start 一次。
    wantedBy = lib.mkForce [ ];
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

  # 本地通过 SSH 隧道推送到集群内 registry（HTTP registry；zot 已退役 2026-08-14）。
  virtualisation.containers.registries.insecure = [
    "localhost:5000"
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
    # zot.zot mirror 已删（2026-08-14 zot 退役）

    # CI infra 镜像（kubectl-shell-runner / git-cache-clone-runner）。
    #
    # ⚠️ 2026-10-12 nova13 迁入新集群 acme-prod：mirror 从
    #    registry-bj-upstream(30003) 改为 registry-sg-upstream(30002)。
    #    改错的表现：pull 被转到本机一个**不存在的** NodePort → 连接被拒 →
    #    clone/deploy step ImagePullBackOff，而镜像名看起来完全正常。
    #    （zen14 同日迁移时踩过同一个点，见其 default.nix 的同类注释。）
    #
    # 节点无法解析 cluster.local（mihomo DNS 链路过 cilium BPF 黑洞，见
    # modules/nixos/miho/build-node-extra-config.nix 注释），故直接 mirror 到本机 NodePort
    # （upstream DaemonSet 与 build 节点同机，internalTrafficPolicy=Local
    #  ⇒ 只有本节点跑着 upstream pod 时该 NodePort 才应答）。
    #
    # ⚠️ 本文件**刻意不含 `registry.local:5000`**：build 节点只负责 build+push，
    #    不拉业务镜像（业务镜像由 test 节点从各区域桶拉、prod 节点从 SG COS 拉）。
    #
    # ⚠️ 插件路径必须是 containerd **v2** 形式 `io.containerd.cri.v1.images`：
    #    k0s 1.36 的 containerd 升到 2.x，启动前的 pre-flight check 会**拒绝**旧写法
    #      Rejected: configuration contains a [plugins."io.containerd.grpc.v1.cri"]
    #      section which is the containerd v1 CRI plugin format
    #    并直接拒绝启动（Error: pre-flight checks failed）。
    [plugins."io.containerd.cri.v1.images".registry.mirrors."registry-sg-upstream.registry.svc.cluster.local:5000"]
      endpoint = ["http://127.0.0.1:30002"]

    [plugins."io.containerd.cri.v1.images".registry.configs."registry-sg-upstream.registry.svc.cluster.local:5000".tls]
      insecure_skip_verify = true
  '';

  services.k0s = {
    enable = true;
    # ⚠️ 显式 pin 到 1.36（2026-10-12 随迁入新集群 acme-prod 从 1.35 升级）。
    #    k0s 要求 worker 与 controller 相差不超过 1 个 minor，且集群主体
    #    （老集群 net/world/test、新集群两节点、zen14）全是 **1.36.3+k0s**。
    #    不用 `inputs.k0s-nix.packages.${system}.k0s`：它的默认值当时是 k0s_1_35。
    package = inputs.k0s-nix.packages.${system}.k0s_1_36;
    role = "worker";
    # 首次 join 需要提前放置 token 文件到 /var/lib/k0s/k0stoken
    tokenFile = "/var/lib/k0s/k0stoken";
    dataDir = "/var/lib/k0s";
    # ⚠️ 2026-10-12 nova13 迁入新集群 acme-prod：
    #    · node-ip 从 10.144.200.3（老 Build ET）改为 **10.144.150.4**（新集群 ET）
    #      —— 该地址由 modules/nixos/easytier/default.nix 的 etNetworksByHost
    #      分配，两处必须一致，否则 kubelet 注册的 InternalIP 在 ET 网络里不可达。
    #    · 标签/tolerations 保持不变（新集群的 build 节点标签同为
    #      wants-role/build → promoter 派生成 node-role.kubernetes.io/build，
    #      故 buildkitd 能直接调度到本节点）。
    #
    # ⚠️ `--cluster-dns`（2026-10-12 加）：与 zen14 完全同因同值 ——
    #    本节点不在集群所在 VPC 内，集群 CoreDNS 会把对象存储域名解析成
    #    VPC 链路本地地址 `169.254.0.47`（不可达），必须让本节点所有 pod
    #    用本机的 build-local CoreDNS（10.119.194.33，internalTrafficPolicy:
    #    Local ⇒ 命中本机实例）；第二值 10.112.0.10 是兜底。
    #    完整理由、k0s 不支持 worker profile 覆盖 clusterDNS 的依据、
    #    以及另一仓库的对应声明，见 zen14/default.nix 同一处的注释。
    extraArgs = ''--kubelet-extra-args="--cluster-dns=10.119.194.33,10.112.0.10 --node-ip=10.144.150.4 --node-labels=wants-role/build=,wants-role/proxy= --register-with-taints=dedicated=nova13:NoSchedule --eviction-hard=memory.available<100Mi,nodefs.available<5%,nodefs.inodesFree<5%,imagefs.available<5% --image-gc-high-threshold=95 --image-gc-low-threshold=90 --eviction-pressure-transition-period=5m"'';
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
    # 开启 jojo 的 user lingering：user manager 常驻，multica-daemon 等 user service
    # 才能开机自启、且不随 SSH session 断开而被清理。等价于 `loginctl enable-linger jojo`。
    "f /var/lib/systemd/linger/jojo 0644 root root -"
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
      ExecStart = "${hermesWrapped}/bin/hermes gateway run";
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
