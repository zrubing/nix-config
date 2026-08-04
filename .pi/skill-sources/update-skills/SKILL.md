---
name: update-skills
description: 检查并同步 ~/.pi/agent/skills 与 nix-config 仓库的 skill-sources（git 权威源）。当用户要求"更新 skills"、"同步 skills"、"检查 skill 更新"、或修改 skill 后想回流仓库时使用。
disable-model-invocation: true
---

# Update Skills

将运行时 skill 目录 `~/.pi/agent/skills` 与 git 权威源 `nix-config/.pi/skill-sources`（在 nix-config 仓库内）双向同步，逐条 diff 确认后才应用。

## 配置

- 源目录：`/home/jojo/nix-config/.pi/skill-sources`
- live 目录：`~/.pi/agent/skills`
- 脚本：本 skill 的 `scripts/skill-sync.sh`

## 工作流

### 1. 检查差异

```bash
bash "$SKILL_DIR/scripts/skill-sync.sh" check
```

输出行协议：

| 前缀 | 含义 |
|---|---|
| `IN_SYNC:<name>` | 无差异 |
| `CHANGED:<name>` | 有差异，diff 展示直到 `END_DIFF`（diff 方向：live → 源） |
| `MISSING:<name>` | 源里有、live 缺失（可 pull） |
| `LOCAL_ONLY:<name>` | live 有、源没有 —— 本地私有 skill，**忽略，不处理** |
| `ALL_IN_SYNC` | 全部一致 |

### 2. 逐条确认

- 若 `ALL_IN_SYNC`：告知用户全部一致，结束。
- 对每个 `CHANGED` / `MISSING`：
  - 说明 skill 名与变更摘要（新增/删除/修改的文件）
  - 展示 diff（代码块）
  - 询问用户方向：
    - **pull**（源 → live）：源里的改动需要部署到运行时
    - **push**（live → 源）：live 里的本地迭代要回流 git（注意：push 会覆盖源，若用户不确定让用户先看 diff）
- 对 `LOCAL_ONLY` 只做汇报，不询问。

### 3. 应用

用户确认后执行：

```bash
bash "$SKILL_DIR/scripts/skill-sync.sh" pull <skill>
# 或
bash "$SKILL_DIR/scripts/skill-sync.sh" push <skill>
```

逐个汇报成功/失败。

### 4. 收尾

- 若做过 push，提醒用户把 nix-config 仓库的改动 commit。
- 若做过 pull，提醒用户执行 `/reload` 让 pi 重新加载 skills。
- 总结：更新了 N 个、跳过 M 个、一致 K 个。
