---
name: zli
description: 用于通过 zli 查询 zot registry 的仓库、镜像、标签和搜索结果；固定使用 zot.zot.svc.cluster.local:5000，并通过 ZOT_REGISTRY_USERNAME/ZOT_REGISTRY_PASSWORD 认证。
---

# zli (zot CLI)

当用户要求查询 zot registry 上的仓库/镜像信息，或需要用用户名密码做命令行访问时，使用此技能。

## 目标

提供可直接执行的 `zli` 命令，完成以下任务：

- 连通性确认（registry 可访问）
- 仓库列表查询
- 镜像/标签信息查询
- 关键字搜索
- 常见认证与网络故障排查

## 认证与连接参数

`zli` 常用全局参数：

- `--url <registry-url>`: 指定 zot 服务地址
- `-u, --user "username:password"`: Basic 认证凭据
- `-f, --format <text|json|yaml>`: 输出格式
- `--debug` / `--verbose`: 调试输出

固定连接与认证变量：

```bash
export ZOT_REGISTRY_URL="http://zot.zot.svc.cluster.local:5000"
AUTH="${ZOT_REGISTRY_USERNAME}:${ZOT_REGISTRY_PASSWORD}"
```

要求：

- 用户名必须来自 `ZOT_REGISTRY_USERNAME`
- 密码必须来自 `ZOT_REGISTRY_PASSWORD`
- registry 固定使用 `zot.zot.svc.cluster.local:5000`（默认 HTTP）

安全规则（强制）：

- 禁止在命令中明文写死用户名或密码。
- 禁止在文档、日志、截图、提交记录中暴露凭据。
- 仅允许通过环境变量组合凭据：`AUTH="${ZOT_REGISTRY_USERNAME}:${ZOT_REGISTRY_PASSWORD}"`。

## 常用查询命令

```bash
# 1) 列出所有仓库
zli repo --url "$ZOT_REGISTRY_URL" -u "$AUTH"

# 2) 列出镜像（按当前 zli 版本支持的子命令）
zli image list --url "$ZOT_REGISTRY_URL" -u "$AUTH"

# 3) 查询指定镜像/标签（示例）
zli image name myrepo/myimage:latest --url "$ZOT_REGISTRY_URL" -u "$AUTH"

# 4) 关键字搜索
zli search query nginx --url "$ZOT_REGISTRY_URL" -u "$AUTH"

# 5) 查看服务状态（若版本支持）
zli status --url "$ZOT_REGISTRY_URL" -u "$AUTH"
```

## 输出格式与自动化

需要脚本处理时优先 JSON：

```bash
zli repo --url "$ZOT_REGISTRY_URL" -u "$AUTH" -f json
zli search query alpine --url "$ZOT_REGISTRY_URL" -u "$AUTH" -f json
```

## 排障清单

1. **命令不存在**
   - 现象：`zli: command not found`
   - 处理：确认 Nix 包已安装并生效（`home-manager switch` 后重开 shell）

2. **认证失败**
   - 现象：401 / unauthorized
   - 处理：
     - 检查 `-u "username:password"` 是否正确
     - 密码含特殊字符时必须整体加引号

3. **地址不可达**
   - 现象：dial tcp / no such host / timeout
   - 处理：
     - `zot.zot.svc.cluster.local` 仅在 K8s 集群内可解析
     - 集群外请改用 Ingress / NodePort / Port-Forward 地址

4. **TLS/协议不匹配**
   - 现象：HTTP/HTTPS 握手错误
   - 处理：
     - 5000 端口常见是 HTTP：`http://...`
     - 若启用 TLS 再切 `https://...`

5. **子命令差异**
   - 不同 zli 版本子命令可能不同，先执行：

```bash
zli --help
zli repo --help
zli image --help
zli search --help
```

## 输出要求

实施时需明确给出：

1. 使用的 registry URL。
2. 使用的命令（至少包含 `zli repo`，且 `-u` 必须来自 `ZOT_REGISTRY_USERNAME/ZOT_REGISTRY_PASSWORD` 组合）。
3. 成功时给出关键输出摘要（例如仓库名）。
4. 失败时给出首个可行动错误与下一步修复建议。
