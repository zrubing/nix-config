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
      runinfraPackage
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
  # OpenSpec skills：构建时用 openspec CLI 按全局 workflows 生成到 store，
  # openspec 升级后自动重新生成（SKILL.md 带 generatedBy 版本标记），无需手动同步。
  # 沙箱里无全局配置，先写一份与 ~/.config/openspec/config.json 一致的 config 再 init。
  # 注意：nix 构建的 pty winsize 为 0x0（columns=0），ora 渲染会除零死循环，
  # 必须把 stdout/stderr 重定向到文件（非 TTY）让 spinner 静默。
  openspecSkills = pkgs.runCommand "openspec-skills" {
    nativeBuildInputs = [ inputs.llm-agents.packages.${pkgs.system}.openspec ];
  } ''
    export HOME=$TMPDIR
    # telemetry 上报在无网络沙箱里会挂起 init，构建期必须关闭
    export OPENSPEC_TELEMETRY=0
    mkdir -p $HOME/.config/openspec
    cat > $HOME/.config/openspec/config.json <<'EOF'
    {"profile":"custom","delivery":"both","workflows":["propose","explore","apply","archive"]}
    EOF
    mkdir -p $TMPDIR/proj
    cd $TMPDIR/proj
    # stdout/stderr 重定向到文件：否则 ora 在 pty（columns=0）下渲染死循环
    timeout 60 openspec init --tools pi --no-animation --no-copilot-cloud . > $TMPDIR/init.log 2>&1 || {
      echo "openspec init FAILED, log:" >&2
      tail -30 $TMPDIR/init.log >&2
      exit 1
    }
    mkdir -p $out
    cp -r $TMPDIR/proj/.pi/skills/* $out/
  '';
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
    home.file.".pi/agent/skills/woodpecker-ci".source = ../../../.pi/skill-sources/woodpecker-ci;
    home.file.".pi/agent/skills/zli".source = ../../../.pi/skill-sources/zli;
    home.file.".pi/agent/skills/sealed-secrets".source = ../../../.pi/skill-sources/sealed-secrets;
    home.file.".pi/agent/skills/tradingagents" = {
      source = ../../../.pi/skill-sources/tradingagents;
      recursive = true;
    };
    # GitButler skill：内容内嵌在 but 二进制，构建时用 `but skill install` 释放到 store，
    # but 升级后自动重新生成，无需手动同步。但启动时会 mkdir $HOME，沙箱里需指向可写目录
    home.file.".pi/agent/skills/gitbutler".source = pkgs.runCommand "gitbutler-skill" {
      nativeBuildInputs = [ inputs.llm-agents.packages.${pkgs.system}.but ];
    } ''
      export HOME=$TMPDIR
      but skill install --path $out >/dev/null
    '';
    # OpenSpec skills：构建时从 openspec 二进制生成，升级后自动重新生成
    home.file.".pi/agent/skills/openspec-propose".source = "${openspecSkills}/openspec-propose";
    home.file.".pi/agent/skills/openspec-explore".source = "${openspecSkills}/openspec-explore";
    home.file.".pi/agent/skills/openspec-apply-change".source = "${openspecSkills}/openspec-apply-change";
    home.file.".pi/agent/skills/openspec-archive-change".source = "${openspecSkills}/openspec-archive-change";

    # Pi skills
    home.file.".pi/agent/skills/caveman".source = "${inputs.caveman-skills}/skills/caveman";
    home.file.".pi/agent/skills/brainstorming" = lib.mkIf cfg.superpowers.enable {
      source = "${inputs.superpowers}/skills/brainstorming";
    };
    home.file.".pi/agent/skills/grill-me".source = "${inputs.mattpocock-skills}/skills/productivity/grill-me";
    home.file.".pi/agent/skills/grilling".source = "${inputs.mattpocock-skills}/skills/productivity/grilling";
    home.file.".pi/agent/skills/anysearch" = {
      source = "${inputs.anysearch-skill}";
      recursive = true;
    };
    home.file.".pi/agent/extensions/guardrails.json".source = ../../../.pi/extensions/guardrails.json;

    home.activation.migrateGitbutlerSkillDirectory = config.lib.dag.entryBefore [ "checkLinkTargets" ] ''
      target="$HOME/.pi/agent/skills/gitbutler"

      # 旧版本是 but CLI 直接释放的真实目录，转为 nix 管理前先备份再删除
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        rm -rf "$target.pre-nix.bak"
        mv "$target" "$target.pre-nix.bak"
      fi
    '';

    home.activation.migrateOpenspecSkillDirectories = config.lib.dag.entryBefore [ "checkLinkTargets" ] ''
      # 旧版本是 openspec CLI 直接释放的真实目录，转为 nix 管理前先备份再删除
      for skill in openspec-propose openspec-explore openspec-apply-change openspec-archive-change; do
        target="$HOME/.pi/agent/skills/$skill"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          rm -rf "$target.pre-nix.bak"
          mv "$target" "$target.pre-nix.bak"
        fi
      done
    '';

    home.activation.migrateAnysearchSkillDirectory = config.lib.dag.entryBefore [ "linkGeneration" ] ''
      target="$HOME/.pi/agent/skills/anysearch"

      if [ -L "$target" ]; then
        linkTarget="$(readlink "$target")"
        case "$linkTarget" in
          /nix/store/*-home-manager-files/.pi/agent/skills/anysearch)
            rm "$target"
            ;;
        esac
      fi
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
