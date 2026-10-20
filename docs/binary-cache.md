# 二进制缓存（cachix）

状态：已上线
日期：2026-10-20
涉及：`modules/unix/nix-settings/default.nix`、`clan/zen14.nix`、`modules/home/sops/default.nix`

## 1. 结论摘要

- 缓存：`https://zrubing.cachix.org`（cachix 账号 zrubing，**公开可读**，推送要 auth token）。
  口语里说的「cachenix」就是指它；缓存名是 cachix 那边的 `zrubing`，命令里必须写这个名字。
- 用途：只放本仓库自有的派生包（nixpkgs 里没有的东西，如 `cliphist-gui`），让另一台机器直接替代，不必重建。
- 推送是手动的：`nix build` 之后 `cachix push`，一条管道搞定。
- nixpkgs 里已有的依赖不用推（它们来自 `cache.nixos.org`），推了白占配额。

## 2. 凭据

token 存 clan vars，**不要**用 `cachix authtoken`（它把明文写进 `~/.config/cachix/cachix.dhall`，脱离声明式管理）。

| 项 | 值 |
| --- | --- |
| clan vars 路径 | `vars/per-machine/zen14/cachix-auth-token/token/secret` |
| 定义处 | `clan/zen14.nix` 的 `clan.core.vars.generators.cachix-auth-token` |
| 渲染到 | `~/.config/default.env`（终端）、`~/.config/dsh.env`（dsh-web 宿主） |
| 环境变量 | `CACHIX_AUTH_TOKEN` |

换 token（在 `app.cachix.org` → Account → Auth Tokens 生成）：

```bash
cd ~/nix-config && clan vars set zen14 cachix-auth-token/token
home-manager switch --flake .#
```

验证 token 有效（200 + 账号信息，token 不落屏）：

```bash
( source ~/.config/default.env
  curl -sS -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" https://cachix.org/api/v1/user | head -c 120; echo )
```

## 3. 客户端配置（拉取侧）

在 `modules/unix/nix-settings/default.nix` 里声明，两台机器都生效：

- `nix.settings.substituters` 追加 `https://zrubing.cachix.org`（放末位，热路径仍先问 `cache.nixos.org`）。
- `nix.settings.trusted-public-keys` 追加 `zrubing.cachix.org-1:UhoPG6Vn30/rA1Wb5CB8dWMHH6rnk64J31SSibqxVcA=`。

缓存是公开的，所以拉取侧**不需要** token；token 只用于推送。

## 4. 推送流程

`cachix` 没装进系统，用 `nix run` 即可。token 从渲染好的 env 文件里取，避免明文进 shell 历史：

```bash
cd ~/nix-config

# 1) 先构建，拿到输出路径
out=$(nix build .#cliphist-gui --no-link --print-out-paths)

# 2) 推送（token 只在这个子进程里可见）
CACHIX_AUTH_TOKEN=$(grep -oP 'CACHIX_AUTH_TOKEN="\K[^"]+' ~/.config/default.env) \
  nix run nixpkgs#cachix -- push zrubing "$out"
```

一条管道写法（多包一起推）：

```bash
nix build --no-link --print-out-paths .#pkg-a .#pkg-b \
  | CACHIX_AUTH_TOKEN=$(grep -oP 'CACHIX_AUTH_TOKEN="\K[^"]+' ~/.config/default.env) \
    xargs nix run nixpkgs#cachix -- push zrubing
```

实测（`cliphist-gui`）：361 条路径的闭包只上传了 1 条、760 KiB，其余 cachix 判定已存在；
缓存里查不到依赖的 narinfo，但它们本来就在 `cache.nixos.org`，所以不影响替代。
重复推送是幂等的，会直接打印 `Nothing to push - all store paths are already on Cachix.`。

## 5. 验证

```bash
# narinfo 必须 200，且带 zrubing 的签名
curl -sS https://zrubing.cachix.org/<store-hash>.narinfo | sed -n '1,3p;/^Sig:/p'

# NAR 本体可下载
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' \
  "https://zrubing.cachix.org/$(curl -sS https://zrubing.cachix.org/<store-hash>.narinfo | sed -n 's/^URL: //p')"
```

## 6. 配额与边界

- 账号是 Community 档：**5 GiB** 上限（建好时约 109 MB 已用）。
- 只推自建包：nixpkgs 依赖不必推。一次自建包的增量通常 < 1 MB。
- 自建包**依赖另一个自建包**时，另一个也得能取到——推完用第 5 节的办法逐个确认；缺失时在目标机上会连带重建。
- 每个 flake 输入更新（`nixpkgs` 变了）后，之前推的产物哈希全变，需要重新推；这是内容寻址的固有代价。

## 7. 自动化（未做）

目前是手动推。需要自动化时两条路，按代价排序：

1. `cachix watch-store zrubing` 常驻（systemd user service）：本地任何新构建自动推。
   token 走 `EnvironmentFile` 或从 clan vars 渲染，别写死在 unit 里。
2. CI 里 `cachix-action`（或 `cachix push`）推构建产物：适合以后有远程构建/CI 时。

## 8. 故障排查

| 现象 | 处理 |
| --- | --- |
| `cachix push` 报认证失败 | 重新跑第 2 节的 token 验证；401 说明 token 失效或缓存名写错 |
| 替代不生效（仍本地重建） | 确认目标机已 rebuild 拿到新的 `substituters`/`trusted-public-keys`：`nix show-config \| grep -E "substituters\|public-keys"` |
| 缓存里 404 但 push 说成功 | 查的是依赖路径（不在缓存里，走 `cache.nixos.org`）；查顶层路径的 narinfo 才有意义 |
| 忘了缓存名 | 账号页面 `app.cachix.org`；本仓库用的是 `zrubing` |
