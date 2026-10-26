{
  description = "A template that shows all standard flake outputs";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # CachyOS 内核（xddxdd/nix-cachyos-kernel）。rev 显式钉死、与 nix-config-vps
    # 的 flake.lock 相同：内核派生由这份 flake 自带的 nixpkgs 决定（见下方
    # overlays 里的 overlays.pinned），rev 不同 = 派生不同 = zrubing.cachix.org
    # 里已推的那份用不上，zen14 得重编整颗内核。
    # 升级内核时改这里的 rev，并同步两边的 override。
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/dbae8dc454556968710401643aa2c6867d166440";

    clan-core.url = "github:clan-lol/clan-core";

    claude-code.url = "github:sadjow/claude-code-nix";

    llm-agents.url = "github:numtide/llm-agents.nix";

    # cargo-nix-plugin input 于 2026-10 移除：它只在全局注入 plugin-files 时有意义，
    # 而全局注入会让任何外来 nix（clan 自带 2.31.5、nixpkgs 的 2.34.9）ABI 崩掉。
    # 本仓库已无消费方。要恢复 crate 级构建，按上游方式「插件与 nix 成对」使用，
    # 参考 nix-config-vps 仓库的 apps.nix-cargo。

    # deepseek-harness 源码。npm 上 @deepseek-ai/dsh 长期滞后（llm-agents 只打包
    # npm 版），想提前用就得从源码构建。flake=false 让 flake.lock 锁住 rev；
    # nix flake update deepseek-harness-src 可拉新。
    # 消费方 = modules/home/dsh 的 dsh-blackhole 构建（esbuild 打 pi-blackhole
    # 适配器所需的 workspace 检查，见 plugins/dsh-blackhole/build.nix）。
    # 构建 dsh 本体已改走上游打包仓库（见下方 deepseek-harness input）。
    deepseek-harness-src = {
      url = "github:deepseek-ai/deepseek-harness?ref=dsh-v0.1.7-rc.1";
      flake = false;
    };

    # 社区 Nix 打包层（Moraxyc/deepseek-harness.nix）。
    #
    # 2026-10-22 起**只用作装配层的 Nix 代码**，不再从它构建 dsh 本体：
    #   · kernel 换成 llm-agents 打包的 npm 产物（见 pkgs/dsh-local 顶部注释）；
    #   · base/headless/web-app/tui 与 12 个 experimental bundle 改为
    #     「npm 包目录 → bundle 布局」的搬运，同样零编译。
    # 仍然依赖它的是三样纯 Nix 的东西：
    #   1. pkgs/dsh 的装配逻辑（symlinkJoin + profile 播种 + launcher）；
    #   2. lib/resolve-dsh-bundles.mjs（dshBundleResolver，生成 bundle 清单）；
    #   3. pkgs/dsh-workspace/optional-bundles.json（可选 bundle 的 attr 名映射）。
    #
    # 为什么当初引它而不是 vendored（2026-09-29 决策）：本仓库此前把它的
    # pkgs/ + lib/ 复制进 pkgs/dsh-moraxyc*（26 个文件），只能手工跟上游。
    # 它的官方 cachix 实测是空的（kernel/bundle/pnpm-deps/src 全 404），
    # 所以「不 follows 本仓库 nixpkgs」这条约束已无意义 —— 反正也不构建了。
    # 消费方式见 modules/home/dsh 与 pkgs/dsh-local。
    deepseek-harness = {
      url = "github:Moraxyc/deepseek-harness.nix";
    };

    pi-guardrails-src = {
      url = "github:zrubing/pi-guardrails?rev=712a2ae0b5150a867414bfcb99049128339dc44a";
      flake = false;
    };

    # RunInfra 的策划数据（models.json / patch.json / custom-models.json）。
    # 只作 dsh 路由的 seed 与 compat 覆盖来源：pi 侧 2026-09-30 起不再跑这个
    # 上游扩展（它内嵌清单且永不删 id），改读 dsh autosync 发布的 catalog。
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

    # ⚠️ 不要把 rime 的 .gram 做成 flake input（曾经有过 `rime-3gram`）。
    # 上游（RIME-LMDG 的 LTS release）**原地覆盖**同一个 tag + 同名 asset，
    # 内容一变 flake.lock 的 narHash 就失效；而 flake input 的求值是**全局**的
    # —— 连不装 fcitx5 的机器，`nixos-rebuild` 都会在 eval 阶段直接失败
    # （2026-10-26 实测 nova13 被一个 home 模块的数据文件卡死，同一 URL 前后三
    #  次抓到的 narHash 各不相同）。它现在是普通 fetchurl，见
    #  modules/home/fcitx5 里的 hash 与升级流程。

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
    #   url = "github:noctalia-dev/noctalia-shell/cachix";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    #   inputs.noctalia-qs.follows = "noctalia-qs-patched";
    # };
    #
    # noctalia 的 nixpkgs 必须与它自己 flake.lock 里锁的那份**完全一致**。
    # 上游 CI（.github/workflows/cachix.yml）就是在那个 nixpkgs 下构建并推到
    # noctalia.cachix.org 的；nixpkgs 一变，bash/stdenv/wayland 等输入的 store
    # path 全变，noctalia 派生 hash 随之改变，缓存必然 404、只能源码重建。
    #
    # 所以这里 follows 到 noctalia-nixpkgs，而不是跟随本仓库的 nixpkgs-unstable
    # （那条路只有和上游锁撞在同一 rev 上时才碰巧命中）。代价是多一份 nixpkgs
    # 求值；收益是只要 rev 对得上就 100% 替代，不编译。
    #
    # 升 noctalia 时两处一起改：
    #   1) 下面 noctalia 的 rev；
    #   2) noctalia-nixpkgs 的 rev = 新 rev 仓库里 flake.lock 的
    #      `nodes.nixpkgs.locked.rev`（用 rev 形式而不是 channels.nixos.org
    #      的 tarball URL，后者会被 nix flake update 重新解析成当天最新）。
    noctalia-nixpkgs = {
      url = "github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell/c42ffe51fa45087faeae29e5cf00ef2df623abcb";
      inputs.nixpkgs.follows = "noctalia-nixpkgs";
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
          # cachyosKernels：必须用 pinned 变体。它把内核派生固定在
          # nix-cachyos-kernel 自带的 nixpkgs 上，本仓库 nixpkgs 升版不会改变
          # 内核派生；default 变体用本仓库 nixpkgs，会让内核随 nixpkgs 漂移、
          # 每升一次 nixpkgs 就 cache miss 一次。
          inputs.nix-cachyos-kernel.overlays.pinned
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
          #
          # duckdb-engine 0.17.0 同理，但根因是墙钟断言：test_simple_string 带
          # @settings(deadline=1s)，并行构建时实测 1.28s → DeadlineExceeded，
          # 同一份源码在空载机器上又能过。这种时序测试不该决定派生构建成败，
          # 同样整套 pytest 检查关掉。
          #
          # langsmith 的测试会真的往 api.smith.langchain.com 发数据，沙箱里没网，
          # test_process_inputs_outputs 的断言取决于后台上传有没有跑完 —— 同一份
          # drv zen14 能过、nova13 挂。同属"测试不该决定构建结果"。
          (final: prev: {
            python312Packages = prev.python312Packages.overrideScope (self: super: {
              curl-cffi = super.curl-cffi.overrideAttrs (old: {
                doCheck = false;
                dontUsePytestCheck = true;
              });
              duckdb-engine = super.duckdb-engine.overrideAttrs (old: {
                doCheck = false;
                dontUsePytestCheck = true;
              });
              langsmith = super.langsmith.overrideAttrs (old: {
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
          # pnpm 9.15.9 (openspec) 在新 nixpkgs 中被标记为 insecure。
          permittedInsecurePackages = [ "pnpm-9.15.9" ];
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
      # （与另一私有仓库锁同一 clan-core rev，CLI 二进制一致）
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
