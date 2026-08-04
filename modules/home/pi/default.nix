{
  config,
  lib,
  inputs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.pi;
  flakeLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  guardrailsRev = flakeLock.nodes."pi-guardrails-src".locked.rev;
  guardrailsPackage = "git:github.com/zrubing/pi-guardrails#${guardrailsRev}";
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
    ];
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
