{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.multica-server;

  # 版本唯一来源：改版本时只改这一行 + 下面两个镜像的 imageDigest/sha256。
  # 三者必须指向同一份镜像，否则 pullImage 会因为 digest 与实际内容不符而构建失败
  # （失败比静默跑旧镜像好，这是刻意的）。
  version = "0.11.1";

  # 镜像按 digest 固化并用 dockerTools 预取进 /nix/store：
  #   · 部署可复现 —— 同一份 nix 配置在任何时候 build 出同一批字节；
  #   · 启动不依赖 registry —— 断网/上游删 tag 也能起；
  #   · 回滚 = git revert + switch，不需要记 shell 历史。
  # digest 来自 `docker buildx imagetools inspect`/registry HEAD，版本变化时同步改。
  backendImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/multica-ai/multica-backend";
    imageDigest = "sha256:49db0b3d2b1a711fd92c440fd564c79d85a660f59b834bc6917382c86c1e32f7";
    finalImageName = "multica-backend";
    finalImageTag = version;
    sha256 = "sha256-jTGO4z+IHetQEr3+kSRlHxCFIRmEccT369hqwot/nhk=";
    os = "linux";
    arch = "amd64";
  };

  webImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/multica-ai/multica-web";
    imageDigest = "sha256:037d3fada7cfc6150f7262d874346910cf12a7226549480539977da599593e92";
    finalImageName = "multica-web";
    finalImageTag = version;
    sha256 = "sha256-BsVNWZRWJDka6RSmZOD5GB2rcbxgUX12tEPV+i0QaBA=";
    os = "linux";
    arch = "amd64";
  };

  uploadsDir = "/var/lib/multica/uploads";
in
{
  options.${namespace}.multica-server = with lib; {
    enable = mkEnableOption "Self-hosted Multica server (podman + local postgres)";

    backendPort = mkOption {
      type = types.port;
      default = 30081;
      description = ''
        Host port the Go backend listens on. 默认沿用旧 k8s NodePort，
        这样 Caddy 里 <code>reverse_proxy 10.144.200.3:30081</code> 不用改。
      '';
    };

    webPort = mkOption {
      type = types.port;
      default = 30082;
      description = "Host port the Next.js frontend listens on（同上，沿用旧 NodePort）。";
    };
  };

  config = lib.mkIf cfg.enable {
    # 单机服务：直接用 podman + host 网络，容器内端口即宿主端口，
    # 不需要 pod / 自定义 network / 端口映射这一层。
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    # Postgres 跑成原生服务而不是容器：版本由 nix 管、pg_dump 备份可用、
    # 不依赖容器卷，也避开了「容器里改数据目录权限」这类坑。
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);
      ensureDatabases = [ "multica" ];
      ensureUsers = [
        {
          name = "multica";
          ensureDBOwnership = true;
        }
      ];
    };

    services.postgresqlBackup = {
      enable = true;
      databases = [ "multica" ];
    };

    # ensureUsers 只能建角色，不能设密码。密码来自 sops，用一次性单元对齐。
    # 顺便预建 pgvector 扩展：迁移脚本以普通角色执行，没有 CREATE EXTENSION 权限。
    systemd.services.multica-db-init = {
      description = "Set multica DB role password and ensure pgvector extension";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.util-linux
        config.services.postgresql.package
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # sops 解出来的文件是 root 0400，所以单元以 root 跑，再用 runuser 切到
      # postgres 连库；密码用 psql 变量传，避免出现在进程命令行里。
      script = ''
        set -euo pipefail
        psql=${config.services.postgresql.package}/bin/psql
        password=$(cat ${config.sops.secrets."multica/POSTGRES_PASSWORD".path})
        runuser -u postgres -- "$psql" -v ON_ERROR_STOP=1 --no-psqlrc -v pw="$password" <<'SQL'
        ALTER ROLE multica WITH PASSWORD :'pw';
        SQL
        runuser -u postgres -- "$psql" -v ON_ERROR_STOP=1 --no-psqlrc \
          -d multica -c "CREATE EXTENSION IF NOT EXISTS vector"
      '';
    };

    sops.templates."multica-backend.env" = {
      owner = "root";
      mode = "0400";
      content = ''
        JWT_SECRET=${config.sops.placeholder."multica/JWT_SECRET"}
        DATABASE_URL=postgres://multica:${config.sops.placeholder."multica/POSTGRES_PASSWORD"}@127.0.0.1:5432/multica?sslmode=disable
        # Lark/Feishu Bot 凭据的落库加密键（base64 32 字节）。未设置时后端
        # 直接禁用该集成，UI 不出现「Bind to Lark」入口。
        MULTICA_LARK_SECRET_KEY=${config.sops.placeholder."multica/LARK_SECRET_KEY"}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${uploadsDir} 0750 - - -"
    ];

    virtualisation.oci-containers.containers = {
      multica-backend = {
        # image 只用于日志/标签，真正加载的是 imageFile（store 里的固化物）。
        image = "multica-backend:${version}";
        imageFile = backendImage;
        environmentFiles = [ config.sops.templates."multica-backend.env".path ];
        environment = {
          PORT = toString cfg.backendPort;
          # 自托管没有邮件通道，登录靠固定验证码；后端只在非 production 时
          # 才接受 MULTICA_DEV_VERIFICATION_CODE（见 server 的 isDevVerificationCode）。
          # 与旧 k8s 部署（values.yaml 里 appEnv: development）保持一致。
          APP_ENV = "development";
          MULTICA_APP_URL = "http://multica.local";
          FRONTEND_ORIGIN = "http://multica.local";
          GOOGLE_REDIRECT_URI = "http://multica.local/auth/callback";
          LOCAL_UPLOAD_BASE_URL = "http://multica-api.local";
          ALLOW_SIGNUP = "true";
          # 自托管默认没有邮件通道，用固定验证码登录（与旧 k8s 部署一致）。
          MULTICA_DEV_VERIFICATION_CODE = "888888";
        };
        volumes = [ "${uploadsDir}:/app/data/uploads" ];
        extraOptions = [ "--network=host" ];
      };

      multica-web = {
        image = "multica-web:${version}";
        imageFile = webImage;
        environment = {
          HOSTNAME = "0.0.0.0";
          PORT = toString cfg.webPort;
          # host 网络下前后端同机，直接走回环，不依赖容器名解析。
          REMOTE_API_URL = "http://127.0.0.1:${toString cfg.backendPort}";
        };
        extraOptions = [ "--network=host" ];
      };
    };

    # oci-containers 生成的单元：backend 必须等 DB 初始化完成，
    # 否则首次启动会在迁移阶段因为角色没密码而失败重试。
    systemd.services."podman-multica-backend" = {
      after = [ "multica-db-init.service" ];
      requires = [ "multica-db-init.service" ];
    };
    systemd.services."podman-multica-web" = {
      after = [ "podman-multica-backend.service" ];
    };

    networking.firewall.allowedTCPPorts = [
      cfg.backendPort
      cfg.webPort
    ];
  };
}
