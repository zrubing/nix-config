{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.pi;
  flakeLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  guardrailsRev = flakeLock.nodes."pi-guardrails-src".locked.rev;
  guardrailsPackage = "git:github.com/zrubing/pi-guardrails#${guardrailsRev}";
  # pi-runinfra-provider：RunInfra 网关 provider（DeepSeek V4 / Nemotron 3.5 / Qwen3.8）
  # rev 由 flake input pi-runinfra-provider-src pin，flake.lock 更新时自动同步
  # 注意：pi 的 git 包 pin ref 用 @ref 后缀（见 pi 文档 packages.md）
  runinfraRev = flakeLock.nodes."pi-runinfra-provider-src".locked.rev;
  runinfraPackage = "git:github.com/monotykamary/pi-runinfra-provider@${runinfraRev}";

  # ── pi-deepseek-cache：禁用其 P3（cache-friendly compaction）后本地加载 ──
  # 冲突事实（2026-09-08 实证）：该扩展与 pi-blackhole 都注册 session_before_compact，
  # 而 pi 的 runner 对 session_before_* 事件是「覆盖」语义、非合并——
  # core/extensions/runner.js 的 isSessionBeforeEvent 分支里 `result = handlerResult`
  # （仅 cancel 会短路）。扩展按包名字母序加载（旧 pi-debug.log 的 [Extensions] 段可验：
  # @aliou/… → context-mode → monotykamary/… → pi-blackhole → pi-deepseek-search →
  # pi-mcp-adapter），故 pi-blackhole 先注册、pi-deepseek-cache 后注册并覆盖，
  # blackhole 的 OM 折叠内容（`summary + "\n\n" + omContent`）被整段丢弃，
  # details.compactor/sections/om.folded 一并丢失；/blackhole 手动路径同样被覆盖
  # （该扩展不检查 customInstructions）。
  # 上游 0.2.1 已是最新且无任何开关（源码无 config/env 读取），故从 npm tarball
  # 构建一份禁用 P3 的副本，经本地扩展目录加载（pi 支持 ~/.pi/agent/extensions/*/index.ts，
  # 且 loader.js 的 _aliases 表对本地扩展同样生效，裸导入 @earendil-works/* 可解析），
  # 保留 P1 命中率遥测与 P2 前缀守卫。
  # patch 手法：把 session_before_compact 的注册改成 `if (false) …`（单行、版本无关），
  # 该 handler 从此不注册 → 对 compaction 结果弃权 → blackhole 的返回值存活。
  # 上游若加开关，改回 settings.json 的 packages 引用并删掉本段即可。
  deepseekCacheVersion = "0.2.1";
  deepseekCacheTarball = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pi-deepseek-cache/-/pi-deepseek-cache-${deepseekCacheVersion}.tgz";
    hash = "sha256-biTininOQyEQrdTq40+7ojlpTnVnO+DuRkffm2Ykg3Y=";
  };
  deepseekCacheExt = pkgs.runCommand "pi-deepseek-cache-nocompact-${deepseekCacheVersion}" { } ''
    mkdir -p $out
    tar xzf ${deepseekCacheTarball} -C $out --strip-components=1
    substituteInPlace $out/index.ts --replace-fail \
      '  pi.on("session_before_compact", async (event, ctx) => {' \
      '  if (false) pi.on("session_before_compact", async (event, ctx) => {'
  '';

  # pi-blackhole 三个 memory worker 共用的模型（deepseek-v4-flash 便宜快，适合后台任务）
  # contextWindow 显式声明 1M，OM pipeline 会在调用前检查输入是否放得下
  # 注意：provider 与 id 是分开的字段，id 只写模型名（不带 provider 前缀），
  # 否则 modelRegistry.find(provider, id) 匹配不到，会报 "provider/provider/id not found"
  blackholeWorkerModel = {
    provider = "opencode-go";
    id = "deepseek-v4-flash";
    thinking = "low";
    contextWindow = 1000000;
  };
  piSettings = builtins.toJSON {
    packages = [
      "npm:pi-mcp-adapter@2.18.0"
      "npm:@howaboua/pi-codex-conversion@2.2.7"
      "npm:pi-blackhole@0.4.3"
      "npm:context-mode@1.0.169"
      "npm:@aliou/pi-processes@0.9.5"
      "npm:pi-deepseek-search@1.0.15"
      # pi-deepseek-cache 不在此声明：其 P3 compaction 与 pi-blackhole 冲突（覆盖语义），
      # 改用 deepseekCacheExt 经本地扩展目录加载，理由见上方 deepseekCacheExt 注释。
      runinfraPackage
      # NVIDIA NIM 网关 provider（integrate.api.nvidia.com/v1，100+ 模型，
      # 运行时 live discovery）。dsh 侧对应 data/nvidia-nim-models.json 静态
      # 快照（见 modules/home/dsh），升级时两边一起动。
      "npm:pi-nvidia-nim@1.1.23"
    ];
    # —— settings.json 不支持 `providers` 键（pi 源码 Settings 接口无此字段），
    #    modelOverrides 已移到下方 piModelsOverlayJson，经 agenix merge 进 models.json
  };
  # models.json overlay：非机密模型配置，与 agenix secrets(agents/pi/models.json) 深合并生成最终 models.json
  #（merge 逻辑见 modules/home/agenix/default.nix）。settings.json 不能放 providers，只能放这里。
  # runinfra 是扩展注册 provider，models.json 里没有，故经此 overlay 叠加：
  # 仅改 deepseek-v4-flash 的 maxTokens，其余字段保留、未知 id 静默忽略。
  piModelsOverlayJson = builtins.toJSON {
    providers = {
      runinfra = {
        modelOverrides = {
          "deepseek-v4-flash" = { maxTokens = 65536; };
        };
      };
    };
  };
  # pi-blackhole 独立配置文件（不读 settings.json 的 observational-memory 块）
  # 阈值按 1M 上下文窗口调优：compactAfterTokens = 60% 窗口（官方建议 60-70%），
  # 其余按 high-context preset（~200k+）档位配置
  blackholeConfig = builtins.toJSON {
    observerModel = blackholeWorkerModel;
    reflectorModel = blackholeWorkerModel;
    dropperModel = blackholeWorkerModel;
    observeAfterTokens = 20000;
    reflectAfterTokens = 40000;
    compactAfterTokens = 600000;
    observerChunkMaxTokens = 80000;
    observationsPoolMaxTokens = 40000;
    reflectorInputMaxTokens = 160000;
    dropperInputMaxTokens = 160000;
    dropperPressureThreshold = 0.70;
  };
in
{

  options.${namespace}.modules.pi = {
    enable = lib.mkEnableOption "pi agent configuration (settings, skills, extensions)";

    superpowers.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable superpowers skills (brainstorming, etc.) in pi agent.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".pi/agent/settings.json" = {
      text = piSettings;
      force = true;
    };
    home.file.".config/pi/models-overlay.json" = {
      text = piModelsOverlayJson;
    };
    home.file.".pi/agent/pi-blackhole/pi-blackhole-config.json" = {
      text = blackholeConfig;
      force = true;
    };
    # pi-deepseek-cache：本地 patched 副本（P3 已禁用），不再经 settings.json 的 packages。
    # 该目录同时是扩展自身的 STATS_DIR（stats.json / history.json / summary-cache.json），
    # 故只 link index.ts，不动目录内其余运行时文件。
    home.file.".pi/agent/extensions/deepseek-cache/index.ts".source =
      "${deepseekCacheExt}/index.ts";
    # skills 声明已移到 modules/home/skills（共享 skill 模块）：同一份清单同时投放到
    # ~/.agents/skills（pi / DSH / Codex）与 ~/.claude/skills（Claude Code）。
    # git 权威源仍是 .pi/skill-sources/*；此处不再单独声明。
    home.file.".pi/agent/extensions/guardrails.json".source = ../../../.pi/extensions/guardrails.json;

    # nvidia-nim key：clan vars（nvidia-nim-api-key generator）→ home sops
    # （nvidia-nim/api_key）→ 合并进 ~/.pi/agent/auth.json。pi-nvidia-nim
    # 扩展 resolveRequiredNimApiKey 先查 pi 的 auth 注册表（auth.json），再回退
    # NVIDIA_NIM_API_KEY/NVIDIA_API_KEY env；dsh 侧走 dsh.env 的 env 路径，两者
    # 同源同一个 clan secret。幂等：只更新 nvidia-nim 条目，保留其他 provider。
    # 顺序坑（2026-08-27 实证）：sops-nix home 的原始 secret 渲染不是 activation
    # 直做，而是 sops-nix user systemd oneshot 服务按 manifest 跑
    # sops-install-secrets；user unit 文件 symlink 在 linkGeneration 才换，
    # 早于它的 activation 里 restart sops-nix 只会重放旧 unit（旧 manifest）→
    # 新 secret 永远渲染不出。故必须 entryAfter linkGeneration 并自己触发渲染
    # （与 sops-nix 同名 entry 同操作，幂等）；user systemd 离线（boot 时）
    # 则跳过并 WARN，不阻 activation。
    home.activation.configurePiNvidiaNimAuth = config.lib.dag.entryAfter [ "linkGeneration" ] ''
      set -euo pipefail
      export PATH='/etc/profiles/per-user/${config.snowfallorg.user.name}/bin:/run/current-system/sw/bin:$PATH'
      secret=${config.sops.secrets."nvidia-nim/api_key".path}
      if systemctl --user is-system-running 2>/dev/null | grep -qE '^(running|degraded)$'; then
        # daemon-reload 必须先行：linkGeneration 刚换过 unit symlink，
        # systemd 可能还在缓存旧 unit（旧 manifest），直接 restart 会重放
        # 旧脚本（2026-08-27 实证：14:22 两次 restart 都跑了旧脚本，
        # 新 secret 没渲染，本 activation 被 guard 跳过）
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user restart sops-nix
      fi
      if [ ! -f "$secret" ]; then
        echo "WARN: nvidia-nim secret not rendered yet (user systemd offline?); skipping auth.json update"
        exit 0
      fi
      auth_file="$HOME/.pi/agent/auth.json"
      mkdir -p "$HOME/.pi/agent"
      key="$(cat "$secret")"
      if [ -f "$auth_file" ]; then
        tmp="$(mktemp)"
        jq --arg k "$key" '.["nvidia-nim"] = {"type": "api_key", "key": $k}' "$auth_file" > "$tmp"
        mv "$tmp" "$auth_file"
      else
        printf '{\n  "nvidia-nim": {"type": "api_key", "key": "%s"}\n}\n' "$key" > "$auth_file"
      fi
      chmod 600 "$auth_file"
    '';

    # home.activation.configurePiGuardrailsFork = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    #   settings_file="$HOME/.pi/agent/settings.json"
    #   ${pkgs.coreutils}/bin/mkdir -p "$HOME/.pi/agent"
    #
    #   if [ ! -f "$settings_file" ]; then
    #     cat > "$settings_file" <<'EOF'
    #   {
    #     "packages": []
    #   }
    #   EOF
    #   fi
    #
    #   ${pkgs.jq}/bin/jq \
    #     --arg forkPkg '${guardrailsPackage}' \
    #     '
    #     .packages = (
    #       ((.packages // [])
    #         | map(select(. != "npm:@aliou/pi-guardrails" and (. | startswith("git:github.com/zrubing/pi-guardrails") | not))))
    #       + [$forkPkg]
    #       | unique
    #     )
    #     ' "$settings_file" > "$settings_file.tmp"
    #
    #   ${pkgs.coreutils}/bin/mv "$settings_file.tmp" "$settings_file"
    # '';
  };

}
