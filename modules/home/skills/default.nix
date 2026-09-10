{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.skills;

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

  # ── 共享 skill 清单（单一事实来源）─────────────────────────────────────
  # 声明一次，同时投放到两个用户级 skill 根：
  #
  #   ~/.agents/skills  ← pi / DSH / Codex 都扫这个根
  #                       （Codex 官方 skills 文档的 USER 级路径即 $HOME/.agents/skills）
  #   ~/.claude/skills  ← Claude Code 只扫这里，不读 ~/.agents/skills
  #
  # 单个 skill 可用 agents = false / claude = false 只投放一侧；默认两侧都投。
  # 源目录都在仓库内或 flake input（store 路径），密钥不进 skill 目录。
  #
  # 手工维护、未纳入本清单的：~/.agents/skills/agent-browser（真实目录，无 nix 源）、
  # ~/.codex/skills/design-doc-mermaid 与 ~/.claude/skills/design-doc-mermaid
  # （指向 ~/.cc-switch/skills，跨机器不存在，未声明）。
  sharedSkills =
    {
      tradingagents = {
        source = ../../../.pi/skill-sources/tradingagents;
        recursive = true;
      };
      # OpenSpec skills：构建时从 openspec 二进制生成，升级后自动重新生成
      openspec-propose.source = "${openspecSkills}/openspec-propose";
      openspec-explore.source = "${openspecSkills}/openspec-explore";
      openspec-apply-change.source = "${openspecSkills}/openspec-apply-change";
      openspec-archive-change.source = "${openspecSkills}/openspec-archive-change";
      caveman.source = "${inputs.caveman-skills}/skills/caveman";
      grill-me.source = "${inputs.mattpocock-skills}/skills/productivity/grill-me";
      # ADHD 系 skill（2026-09-09 从手动真实目录转为声明式，rev pin 在 flake.nix）：
      # adhd 自动触发（brainstorm/ideate/design/naming 等），单次约 10 次 Agent 调用；
      # i-have-adhd 的 SKILL.md 带 disable-model-invocation，只经用户显式调用
      # （pi: /skill:i-have-adhd；DSH: 输入框 / 的 Skills 分组）。
      # 二者与 caveman 同属输出风格压缩，不要与 caveman 同时启用。
      # i-have-adhd 目录含 agents/ 子目录（gemini.toml / openai.yaml），
      # 默认整目录 symlink 即覆盖，无需 recursive。
      adhd.source = "${inputs.adhd-skill}/skills/adhd";
      i-have-adhd.source = "${inputs.i-have-adhd-skill}/skills/i-have-adhd";
      anysearch = {
        source = "${inputs.anysearch-skill}";
        recursive = true;
      };
      # woodpecker-ci：源在 .pi/skill-sources/woodpecker-ci（git 权威源，与 pi 侧同源）。
      # force：~/.agents/skills/woodpecker-ci 历史上是普通目录，home-manager 默认
      # 拒绝覆盖非空真实目录，须显式 force 才允许替换为 symlink。
      woodpecker-ci = {
        source = ../../../.pi/skill-sources/woodpecker-ci;
        force = true;
      };
    }
    // lib.optionalAttrs config.${namespace}.modules.pi.superpowers.enable {
      brainstorming.source = "${inputs.superpowers}/skills/brainstorming";
    };

  fileEntries = root: attrs:
    lib.mapAttrs' (
      name: v: lib.nameValuePair "${root}/${name}" (builtins.removeAttrs v [ "agents" "claude" ])
    ) attrs;
in
{
  options.${namespace}.modules.skills = {
    enable = lib.mkEnableOption "共享 skill 声明（pi / DSH / Codex / Claude Code 同一份源）";
  };

  config = lib.mkIf cfg.enable {
    home.file =
      fileEntries ".agents/skills" (lib.filterAttrs (_: v: v.agents or true) sharedSkills)
      // fileEntries ".claude/skills" (lib.filterAttrs (_: v: v.claude or true) sharedSkills);

    home.activation.migrateOpenspecSkillDirectories = config.lib.dag.entryBefore [ "checkLinkTargets" ] ''
      # 旧版本是 openspec CLI 直接释放的真实目录（现在 skill 声明在 ~/.agents/skills），
      # 转为 nix 管理前先备份再删除，避免 linkGeneration 被真实目录挡住
      for skill in openspec-propose openspec-explore openspec-apply-change openspec-archive-change; do
        target="$HOME/.agents/skills/$skill"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          rm -rf "$target.pre-nix.bak"
          mv "$target" "$target.pre-nix.bak"
        fi
      done
    '';

    home.activation.migrateAdhdSkillDirectories = config.lib.dag.entryBefore [ "checkLinkTargets" ] ''
      # adhd / i-have-adhd 在 2026-09-09 之前是手动复制的真实目录，转 nix 管理前
      # 移到 ~/.agents/skill-backups/（该目录不在 skills/ 下，任何 agent 都不扫）。
      # 不能原地留 <skill>.pre-nix.bak：pi 的 loadSkillsFromDir 会递归发现子目录里的
      # SKILL.md，DSH 的目录包规则同理，frontmatter name 与父目录名不符会变成噪音。
      for skill in adhd i-have-adhd; do
        target="$HOME/.agents/skills/$skill"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          mkdir -p "$HOME/.agents/skill-backups"
          rm -rf "$HOME/.agents/skill-backups/$skill.realdir-2026-09-09"
          mv "$target" "$HOME/.agents/skill-backups/$skill.realdir-2026-09-09"
        fi
      done
    '';

    home.activation.migrateAnysearchSkillDirectory = config.lib.dag.entryBefore [ "linkGeneration" ] ''
      target="$HOME/.agents/skills/anysearch"

      # 旧版本是 anysearch CLI 直接释放的真实目录（现在声明在 ~/.agents/skills），
      # 若已是 nix-managed symlink 则移除旧的真实目录残留
      if [ -L "$target" ]; then
        linkTarget="$(readlink "$target")"
        case "$linkTarget" in
          /nix/store/*-home-manager-files/.agents/skills/anysearch)
            rm "$target"
            ;;
        esac
      fi
    '';
  };
}
