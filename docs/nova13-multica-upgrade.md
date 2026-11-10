---
name: nova13-multica-upgrade
description: 用于升级 nova13 上自托管的 Multica（podman 容器 + 本机 postgres），包括 CLI、backend/web 镜像 digest 与 nix hash，并通过 nixos-rebuild 完成可复现部署与验证。
---

# nova13 Multica 升级（podman 版）

当用户要求“升级 nova13 的 multica / Multica”、“更新 multica 版本”、“排查 multica 升级后版本不一致”时，使用此技能。

部署形态在 2026-11-11 从「k8s + Helm chart」改为「podman 容器 + 本机 postgres」。
原因：新集群全部 context 走 OIDC exec 认证，systemd oneshot 无法非交互登录；
multica 是单实例、固定跑在 nova13 的家用服务，用 k8s 只增加认证依赖，没有调度收益。

## 版本来源（必须同步的四件事）

1. `packages/multica/default.nix`：CLI。
2. `packages/multica-desktop/default.nix`：桌面端 AppImage（仅 zen14 用）。
3. `modules/nixos/multica-server/default.nix`：backend/web 镜像的 **digest 与 sha256**。
4. 同上文件里的 `finalImageTag`（只影响日志与标签，必须与 digest 对应同一版本）。

## 组件与端口

| 组件 | 形态 | 端口 | 说明 |
|---|---|---|---|
| postgres 17 + pgvector | 原生 `services.postgresql` | 127.0.0.1:5432 | 数据在 `/var/lib/postgresql`，每日 `pg_dump` 到 `/var/backup/postgresql` |
| backend | podman 容器，host 网络 | 30081 | Go API + WS + 迁移 |
| web | podman 容器，host 网络 | 30082 | Next.js，`REMOTE_API_URL` 指向 127.0.0.1:30081 |
| Caddy | 既有 | 80/443 | `multica.local → 10.144.200.3:30082`，`multica-api.local → 10.144.200.3:30081` |

沿用 30081/30082 是为了不改 `caddy-conf`（agenix 密文，在 mysecrets 仓库）。

## 升级流程

### 1. 取目标版本的两个镜像 digest

```bash
for img in multica-backend multica-web; do
  tok=$(curl -s "https://ghcr.io/token?scope=repository:multica-ai/$img:pull&service=ghcr.io" \
        | jq -r .token)
  printf '%s ' "$img"
  curl -sI -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/multica-ai/$img/manifests/v<目标版本>" \
    | grep -i docker-content-digest
done
```

### 2. 取 nix 侧 hash

```bash
nix run nixpkgs#nix-prefetch-docker -- \
  --image-name ghcr.io/multica-ai/multica-backend --image-tag v<目标版本> \
  --os linux --arch amd64 --json | jq -r .hash
```

`imageDigest` 与 `hash` 两个值都要与上一步的 digest 对应同一份镜像。

### 3. 改模块

文件：`modules/nixos/multica-server/default.nix`

```nix
imageDigest = "sha256:<上一步的 digest>";
sha256 = "sha256-<nix-prefetch-docker 的 hash>";
finalImageTag = "<目标版本，不带 v>";
```

同时把 `image = "multica-backend:<目标版本>";` / `image = "multica-web:<目标版本>";` 改成同值。

### 4. 改 CLI

文件：`packages/multica/default.nix`，改 `version`，用 `nix build .#multica` 拿到四个平台 hash。

### 5. 部署

```bash
nixos-rebuild switch --flake .#nova13 --target-host jojo@nova13 --use-remote-sudo
```

`nixos-rebuild` 是唯一收敛入口：镜像固化在 `/nix/store`，switch 后 `podman-multica-backend`
与 `podman-multica-web` 两个单元自动重建容器，后端启动时跑数据库迁移。

## 验证

```bash
# 容器
sudo podman ps --filter name=multica --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
# 后端健康
curl -s -o /dev/null -w '%{http_code}\n' http://10.144.200.3:30081/health
# 前端
curl -s -o /dev/null -w '%{http_code}\n' http://multica.local/
# 数据库
sudo -u postgres psql -d multica -c 'select count(*) from schema_migrations;' 2>/dev/null || true
```

## 排障

### 容器起不来：角色密码或扩展缺失

```bash
systemctl status multica-db-init.service --no-pager
journalctl -u multica-db-init.service -n 50 --no-pager
```

该一次性单元负责 `ALTER ROLE multica PASSWORD`（密码来自 sops）与 `CREATE EXTENSION vector`。

### 容器起不来：镜像

```bash
journalctl -u podman-multica-backend -n 100 --no-pager
nix build .#nixosConfigurations.nova13.config.system.build.toplevel --dry-run
```

镜像来自 store，不需要 registry 可达；若报 `pull access denied` 说明 `imageFile` 没生效。

### 登录不进去

当前实例账户（2026-11-11 重建，新库新用户）：

- 账号：`jojo@local.net`（无邮件通道，验证码固定 `888888`）
- workspace：`jojo`（slug `jojo`）
- CLI 配置：`~/.multica/config.json`（`server_url` / `app_url` / `workspace_id` / `token`，0600）

在浏览器打开 `http://multica.local`，输入邮箱与 `888888` 即可。CLI 侧如果需要重新登录，
用 `multica login --token mul_...`（PAT 在网页 Settings 里生成）。


自托管没有邮件通道，登录用固定验证码 `888888`（`MULTICA_DEV_VERIFICATION_CODE`）。
CLI 侧 `~/.multica/config.json` 必须由 CLI 自己可写；home 模块已不再用 `home.file` 托管该文件。

## 回滚

把 `modules/nixos/multica-server/default.nix` 的 digest/hash/tag 与 `packages/multica/default.nix`
的版本改回上一个可用版本，重新 switch 即可。数据库迁移只前进不回退，跨大版本回滚前先 `pg_dump` 留档。

## 输出要求

回复用户时包含：改了哪些文件、目标版本与旧版本、Nix 自检结果、是否已部署、以及上面的验证命令。
