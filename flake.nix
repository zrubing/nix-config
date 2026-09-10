{
  description = "A template that shows all standard flake outputs";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    clan-core.url = "github:clan-lol/clan-core";

    claude-code.url = "github:sadjow/claude-code-nix";

    llm-agents.url = "github:numtide/llm-agents.nix";

    # deepseek-harness 源码。npm 上 @deepseek-ai/dsh 长期滞后（llm-agents 只打包
    # npm 版），想提前用就得从源码构建。flake=false 让 flake.lock 锁住 rev；
    # nix flake update deepseek-harness-src 可拉新。packages/dsh-src 消费它。
    # 当前固定在 tag dsh-v0.1.5-rc.1；想回主分支把 ref 去掉即可。
    deepseek-harness-src = {
      url = "github:deepseek-ai/deepseek-harness?ref=dsh-v0.1.5-rc.1";
      flake = false;
    };

    pi-guardrails-src = {
      url = "github:zrubing/pi-guardrails?rev=712a2ae0b5150a867414bfcb99049128339dc44a";
      flake = false;
    };

    pi-runinfra-provider-src = {
      url = "github:monotykamary/pi-runinfra-provider?rev=42c8ff4db0d039499daf81a8806819068bf1789c";
      flake = false;
    };

    # pi-blackhole (k0valik) @0.4.3 —— rev 与 npm 0.4.3 的 gitHead 一致（npm registry 实测），
    # 确定性 compile() + recall 检索核心。dsh 无法加载 pi extension，这里只取它的纯 JS 核心
    # （见 modules/home/dsh 的 dsh-blackhole 构建：esbuild 打 src/core + src/extract 子集），
    # dsh 侧以 to-pi.js 适配 Message 形状并薄封装。
    pi-blackhole-src = {
      url = "github:k0valik/pi-blackhole?rev=2246bca51f8fffc4d2b38949663ab1bf4b695120";
      flake = false;
    };

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    # Emacs Overlays
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
    };

    # doom-emacs is a configuration framework for GNU Emacs.
    # Doom Emacs v3: core framework + external modules.
    doomemacs = {
      url = "github:doomemacs/core";
      flake = false;
    };

    doom-modules = {
      url = "github:doomemacs/modules/28f09d8afe81fa47ab83020b072f0dfa2f79dbdb";
      flake = false;
    };

    flake-utils.url = "github:numtide/flake-utils";

    flake-utils-plus = {
      url = "github:gytis-ivaskevicius/flake-utils-plus";
      inputs.flake-utils.follows = "flake-utils";
    };

    flake-compat.url = "github:edolstra/flake-compat";

    # The name "snowfall-lib" is required due to how Snowfall Lib processes your
    # flake's inputs.
    snowfall-lib = {
      url = "github:snowfallorg/lib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri.url = "github:sodiboo/niri-flake";

    tree-sitter-grammars.url = "github:marsam/tree-sitter-grammars";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fast-nix-gc = {
      url = "github:Mic92/fast-nix-gc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    k0s-nix.url = "github:zrubing/k0s-nix/main";

    rime-3gram = {
      url = "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram";
      flake = false;
    };

    # subagents = {
    #   url = "git+ssh://git@github.com/wshobson/agents?ref=main";
    #   flake = false;
    # };

    # subagents2 = {
    #   url = "git+ssh://git@github.com/VoltAgent/awesome-claude-code-subagents";
    #   flake = false;
    # };

    # noctalia-qs-patched = {
    #   url = "path:./third_party/noctalia-qs-patched";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    # };

    # noctalia = {
    #   url = "github:noctalia-dev/noctalia-shell";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    #   inputs.noctalia-qs.follows = "noctalia-qs-patched";
    # };
    #
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    gpui-shell = {
      url = "github:zrubing/gpui-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    design-doc-mermaid = {
      url = "github:SpillwaveSolutions/design-doc-mermaid?rev=e13f987306d5cd7a34f541927a3228343dd90e45";
      flake = false;
    };

    caveman-skills = {
      url = "github:JuliusBrussee/caveman?rev=84cc3c14fa1e10182adaced856e003406ccd250d";
      flake = false;
    };

    anysearch-skill = {
      url = "github:anysearch-ai/anysearch-skill?rev=db3d76e5597aec7261257be5322dd211c9d9bb87";
      flake = false;
    };

    superpowers = {
      url = "github:obra/superpowers?rev=6fd4507659784c351abbd2bc264c7162cfd386dc";
      flake = false;
    };

    mattpocock-skills = {
      url = "github:mattpocock/skills?rev=9603c1cc8118d08bc1b3bf34cf714f62178dea3b";
      flake = false;
    };

    # ADHD 系 skill（2026-09-09 从手动真实目录转为声明式管理）
    # adhd：并行发散构思，description 含 brainstorm/design/naming 等触发词，会自动触发
    # i-have-adhd：输出风格整形，SKILL.md 带 disable-model-invocation，只经用户显式调用
    adhd-skill = {
      url = "github:UditAkhourii/adhd?rev=16dc239ff186b869372e75095cfa58fc0ee89927";
      flake = false;
    };

    i-have-adhd-skill = {
      url = "github:ayghri/i-have-adhd?rev=24d22f783e57cb73c957848b588c6f651b6f9cd8";
      flake = false;
    };

    process-compose = {
      url = "github:F1bonacc1/process-compose";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    ########################  My own repositories  #########################################
    # my private secrets, it's a private repository, you need to replace it with your own.
    # use ssh protocol to authenticate via ssh-agent/ssh-key, and shallow clone to save time
    mysecrets = {
      url = "git+ssh://git@github.com/zrubing/nix-secrets.git?ref=main";
      flake = false;
    };

  };
  outputs =
    { self, ... }@inputs:
    let
      lib = inputs.snowfall-lib.mkLib {
        inherit inputs;
        src = ./.;
      };
    in
    let
      snowfall = lib.mkFlake {

        # Add modules to all NixOS systems.
        systems.modules.nixos = with inputs; [
          agenix.nixosModules.default
          sops-nix.nixosModules.sops
          fast-nix-gc.nixosModules.default
          k0s-nix.nixosModules.default
        ];

        systems.modules.darwin = with inputs; [ ];

        homes.modules = with inputs; [
          noctalia.homeModules.default
          niri.homeModules.niri
          #niri.nixosModules.niri
          agenix.homeManagerModules.default
          sops-nix.homeManagerModules.sops
        ];

        # 顶级 overlays：snowfall 把它喂给 channels.nixpkgs.overlaysBuilder，
        # 应用到默认 nixpkgs channel。
        overlays = [
          inputs.k0s-nix.overlays.default
          inputs.process-compose.overlays.default
          # 复用 snowfall 已构造好的 nixpkgs-unstable channel（其 allowUnfree 等
          # nixpkgs 配置已由下方 channels-config 自动应用），注入为 pkgs.unstable，
          # 模块内可直接 pkgs.unstable.<pkg>。
          (final: _prev: {
            unstable = inputs.self.pkgs.${final.stdenv.hostPlatform.system}.nixpkgs-unstable;
          })
          # curl-cffi 0.14.0 的 pytest 套件（uvicorn/websockets/高并发）在 nix 构建沙箱里
          # SIGABRT（exit 134），导致 yfinance 1.3.0 → tradingagents 整条链构建失败。
          # pytest-check-hook 挂在 preDistPhases，不受 doCheckByDefault=false 控制，
          # 因此必须用 dontUsePytestCheck 关掉（doCheck=false 双保险）。
          (final: prev: {
            python312Packages = prev.python312Packages.overrideScope (self: super: {
              curl-cffi = super.curl-cffi.overrideAttrs (old: {
                doCheck = false;
                dontUsePytestCheck = true;
              });
            });
          })
        ];

        # channels-config 只用于设置 nixpkgs 的 config（如 allowUnfree），
        # 会被 flake-utils-plus 应用到 nixpkgs 与 nixpkgs-unstable 两个 channel。
        # 不要在此放 overlays：flake-utils-plus 的 channelsConfig 只接受 config 键，
        # overlays 会被静默忽略。
        channels-config = {
          # Allow unfree packages.
          allowUnfree = true;
          doCheckByDefault = false;
        };

      };
    in
    let
      # Clan 密钥管理：只声明 zen14 的 vars（generator），不接管系统构建。
      # vars 加密文件存 vars/per-machine/zen14/，由 snowfall 侧 zen14 的 sops 消费。
      # 注意：不能 inherit clan 的 nixosConfigurations——会覆盖 snowfall 的同名 zen14。
      clanConfig = inputs.clan-core.lib.clan {
        inherit self;
        meta.name = "jojo-clan";
        meta.domain = "local";
        inventory.machines.zen14 = {
          deploy.targetHost = "jojo@zen14";
          tags = [ "nixos" ];
        };
        machines.zen14 = { ... }: {
          imports = [ ./clan/zen14.nix ];
        };
      };
    in
    snowfall
    // {
      clan = clanConfig.config;
      clanInternals = clanConfig.config.clanInternals;

      # 官方形态通用入口：nix run .#clan -- secrets|vars|...
      # （与 system-manager-hinihao-net 锁同一 clan-core rev，CLI 二进制一致）
      apps.x86_64-linux = (snowfall.apps.x86_64-linux or { }) // {
        clan = {
          type = "app";
          program = "${inputs.clan-core.packages.x86_64-linux.clan-cli}/bin/clan";
        };
      };

      devShells.x86_64-linux.trading =
        let
          pkgs = import inputs.nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
        in
        pkgs.mkShell {
          packages = [
            (pkgs.python312.withPackages (ps: [
              snowfall.packages.x86_64-linux.tradingagents
            ]))
          ];
          shellHook = ''
            if [ -f .env ]; then
              echo "[trading] loading .env from $(pwd)"
              set -a && source .env && set +a
            elif [ -f "$HOME/.config/tradingagents/.env" ]; then
              echo "[trading] loading sops template"
              set -a && source "$HOME/.config/tradingagents/.env" && set +a
            else
              echo "[trading] no .env or template found, skipping"
            fi
          '';
        };
    };

}
