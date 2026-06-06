---
name: nova13-multica-upgrade
description: 用于升级 nova13 上的 Multica，包括 CLI、Helm chart、Kubernetes 镜像 tag，同步生成 Nix hash，并通过 nixos-rebuild 与 multica-k0s-apply 部署验证。
---

# nova13 Multica 升级

当用户要求“升级 Nova13 的 multica / Multica”、“更新 nova13 multica 版本”、“整理 multica 升级步骤”或排查 nova13 Multica 升级后版本不一致时，使用此技能。

## 目标

将 nova13 上 Multica 的所有版本来源保持一致，并完成可验证部署：

- `packages/multica/default.nix`：Multica CLI
- `systems/x86_64-linux/nova13/k8s/helm/multica/default.nix`：Helm chart 源码版本
- `systems/x86_64-linux/nova13/k8s/helm/multica/values.yaml`：backend/frontend 镜像 tag
- `systems/x86_64-linux/nova13/default.nix`：systemd 服务 `multica-k0s-apply`，负责实际 Helm 部署

原则：chart、镜像 tag、CLI 能同步就同步；不要只改 chart 而遗漏 `values.yaml` 的镜像覆盖。

## 当前基线

当前仓库基线版本：`v0.3.17`。

已知 nova13 部署参数：

- namespace：`multica`
- release：`multica`
- Secret：`multica-secrets`
- Frontend NodePort：`30082`
- Backend NodePort：`30081`
- Frontend URL：`http://multica.local`
- Backend URL：`http://multica-api.local`

## 工作流

### 1. 确认目标版本

优先查询 GitHub latest release：

```bash
python - <<'PY'
import json, urllib.request
url = 'https://api.github.com/repos/multica-ai/multica/releases/latest'
with urllib.request.urlopen(url, timeout=10) as r:
    print(json.load(r)['tag_name'])
PY
```

版本写法约定：

- Nix package `version`：不带 `v`，例如 `0.3.17`
- GitHub `rev` / Docker image tag：带 `v`，例如 `v0.3.17`

### 2. 修改 CLI 包

文件：`packages/multica/default.nix`

更新：

```nix
version = "目标版本，不带 v";
```

如果上游 release artifact hash 变化，先临时使用假 hash，再构建获得真实 hash：

```bash
nix build .#multica
```

按 Nix 报错中的 `got:` 更新各平台 hash。至少确保当前平台构建通过。

### 3. 修改 nova13 Helm chart

文件：`systems/x86_64-linux/nova13/k8s/helm/multica/default.nix`

更新：

```nix
rev = "v目标版本";
sha256 = "...";
```

如 `sha256` 变化，使用假 hash 触发真实 hash：

```bash
nix build .#nixosConfigurations.nova13.config.system.build.toplevel
```

按 Nix 输出更新 `sha256`。

### 4. 修改 nova13 镜像 tag

文件：`systems/x86_64-linux/nova13/k8s/helm/multica/values.yaml`

必须同步更新：

```yaml
images:
  backend:
    tag: v目标版本
  frontend:
    tag: v目标版本
```

常见根因：chart 已升级，但 `values.yaml` 仍覆盖旧 tag，导致 Pod 继续运行旧镜像。

### 5. 本地自检

先做快速 eval：

```bash
nix eval .#nixosConfigurations.nova13.config.systemd.services.multica-k0s-apply.description
```

再做 dry-run 或完整构建：

```bash
nix build .#nixosConfigurations.nova13.config.system.build.toplevel --dry-run
# 必要时：
nix build .#nixosConfigurations.nova13.config.system.build.toplevel
```

检查所有版本引用是否一致：

```bash
rg -n "multica|v0\\.3\\.|version = \"0\\.3\." \
  packages/multica \
  systems/x86_64-linux/nova13/k8s/helm/multica \
  systems/x86_64-linux/nova13/default.nix
```

注意：使用 `rg` / `grep` 时 timeout 不超过 10s。

### 6. 部署到 nova13

在 nova13 上执行：

```bash
sudo nixos-rebuild switch --flake .#nova13
```

`multica-k0s-apply` 是 oneshot systemd 服务，配置切换后会执行：

1. 创建/更新 namespace `multica`
2. 创建/更新 Secret `multica-secrets`
3. 执行 `helm upgrade --install multica ...`
4. 应用 `extra-resources.yaml`

必要时手动重跑：

```bash
sudo systemctl restart multica-k0s-apply.service
sudo systemctl status multica-k0s-apply.service --no-pager
```

## 验证清单

### Nix 侧

```bash
nix eval .#nixosConfigurations.nova13.config.systemd.services.multica-k0s-apply.description
nix build .#nixosConfigurations.nova13.config.system.build.toplevel --dry-run
```

### Kubernetes 侧

```bash
kubectl -n multica get pods -o wide
kubectl -n multica get deploy multica-backend multica-frontend \
  -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
kubectl -n multica rollout status deploy/multica-backend
kubectl -n multica rollout status deploy/multica-frontend
```

### 访问侧

访问：

- `http://multica.local`
- `http://multica-api.local`

如域名无法解析，检查 `/etc/hosts` 或 DNS：

```text
<nova13-ip> multica.local multica-api.local
```

## 排障

### chart 已升级但 Pod 仍是旧版本

检查 `values.yaml`：

```bash
rg -n "tag:" systems/x86_64-linux/nova13/k8s/helm/multica/values.yaml
```

如果仍是旧 tag，同步改成目标版本后重新 `nixos-rebuild switch`。

### Helm 没有自动应用

检查 systemd：

```bash
sudo systemctl status multica-k0s-apply.service --no-pager
journalctl -u multica-k0s-apply.service -n 200 --no-pager
```

### Pod Pending

nova13 的 Helm post-renderer 会把以下 Deployment 固定到 nova13，并添加 `dedicated=nova13:NoSchedule` toleration：

- `multica-backend`
- `multica-frontend`
- `multica-postgres`

检查节点状态：

```bash
kubectl get nodes --show-labels
kubectl describe node nova13 | rg -n "Taints|dedicated|Ready"
```

### 镜像拉取失败

检查实际镜像名与 tag：

```bash
kubectl -n multica describe pod <pod-name> | rg -n "Image:|Failed|BackOff|ErrImagePull|ImagePullBackOff"
```

如果 tag 不存在，回到 GitHub release / chart values 确认目标版本是否真的发布了 backend/frontend 镜像。

## 回滚

恢复以下文件到上一个可用版本：

- `packages/multica/default.nix`
- `systems/x86_64-linux/nova13/k8s/helm/multica/default.nix`
- `systems/x86_64-linux/nova13/k8s/helm/multica/values.yaml`

重新部署：

```bash
sudo nixos-rebuild switch --flake .#nova13
sudo systemctl restart multica-k0s-apply.service
```

回滚后必须验证镜像 tag 与 rollout 状态。

## 输出要求

执行此技能后，回复用户时包含：

1. 修改的文件路径。
2. 目标版本与旧版本。
3. Nix 自检命令及结果。
4. 是否已部署到 nova13；如果未部署，给出需要在 nova13 执行的命令。
5. Kubernetes 验证命令。
