---
name: woodpecker-ci
description: 用于创建、审查和维护 Woodpecker CI 流水线，涵盖 .woodpecker.yml 设计、步骤编排、secrets 使用、分支/标签条件、运行时变量转义与 CLI 排障。
---

# Woodpecker CI

当用户要求创建、更新或排查 Woodpecker CI 流水线时，使用此技能。

## 目标

产出可工作的 `.woodpecker.yml`（或 `.woodpecker/*.yml`），并确保流水线具备以下特性：

- 执行速度快
- 结果可复现
- 配置安全
- 出错时易于定位

## 工作流

1. 写 YAML 前先检查仓库：
   - 识别语言与包管理器。
   - 查找现有 CI 配置（GitHub Actions、GitLab CI 等）用于对齐阶段划分。
   - 确认本仓库的标准校验命令。
2. 设计清晰的流水线阶段：
   - 推荐顺序：`lint` -> `test` -> `build`（若仓库没有对应阶段则按实际裁剪）。
   - 用 `depends_on` 明确执行依赖。
   - 仅在目标事件触发（如 `push`、`pull_request`、`tag`）。
3. 正确处理 secrets：
   - 使用 `from_secret` 注入凭据与 token。
   - 严禁在 YAML 中硬编码敏感信息。
4. 保持步骤可复现：
   - 固定镜像版本，避免 `latest`。
   - 以项目文档中的命令为唯一真值来源。
5. 遵循 Woodpecker 变量转义规则：
   - 在 `.woodpecker.yml` 的 shell 命令中，运行时变量写成 `$${VAR}`。
   - 原因：`${VAR}` 可能在 Woodpecker 模板阶段被提前展开，导致运行时为空。
6. 使用 CLI 做验证与排障：
   - 推送前先执行 `woodpecker-cli lint .woodpecker.yml`。
   - 推送后用 `woodpecker-cli pipeline ls`、`woodpecker-cli pipeline ps`、`woodpecker-cli pipeline log show` 排查。
   - 输出结论时包含失败 step 编号与关键日志行。

## Woodpecker CLI 排障清单

每次修改 CI 文件后，按以下顺序执行：

```bash
woodpecker-cli lint .woodpecker.yml
git push origin <branch>
woodpecker-cli pipeline ls <repo-id|repo-full-name> --branch <branch> --limit 5
woodpecker-cli pipeline ps <repo-id|repo-full-name> <pipeline-number>
woodpecker-cli pipeline log show <repo-id|repo-full-name> <pipeline-number> <step-number>
```

变量展开异常的典型日志特征：

- `if [ "" = "master" ]`
- `OUTPUT_NAMES=":"`
- `mkdir -p ""`

若出现上述现象，将 `${VAR}` 改为 `$${VAR}` 后重试。

URL 与 CLI 参数映射示例：

- CI 页面：`https://ci.example.net/repos/7/pipeline/26/3`
- CLI 命令：`woodpecker-cli pipeline log show 7 26 3`

## 质量标准

优秀的 Woodpecker 流水线应满足：

- 失败要尽早，日志要可行动。
- 避免重复安装和重复构建。
- 分支/标签过滤策略清晰且有意图。
- 非必要不使用特权模式。
- 配置结构清晰，便于团队长期维护。

## 输出要求

实施时需明确给出：

1. 新增或修改的文件路径。
2. 每个 step 的设计原因。
3. 所需的仓库 secrets 或环境设置。
4. 本地与 CI 侧用于验证/排障的命令。