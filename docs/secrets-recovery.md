# Secrets 与灾难恢复

> 本文只记录「哪把钥匙开哪把锁、怎么开」，**不含任何密钥内容**。
> 出事时按第 5 节走。

## 1. 体系总览

本机（zen14）上有三套互不覆盖的 secrets 体系，钥匙和锁的对应关系如下：

| 体系 | 密文位置 | 解密用的 key | 谁在用 |
|---|---|---|---|
| NixOS 级 sops | `nix-secrets/secrets/env.yaml` 等 | `/etc/ssh/ssh_host_ed25519_key` | `modules/nixos/sops`：easytier 等系统服务 |
| home 级 sops | `nix-secrets/**/*.age`、本仓库 `systems/x86_64-linux/zen14/secrets/AGENTS.md` | `~/.ssh/id_ed25519` | `modules/home/sops`：dsh.env、default.env 等 |
| clan vars | `vars/per-machine/zen14/<generator>/<file>/secret` | host key **或** `~/.ssh/id_ed25519` | `clan/zen14.nix` 定义的 18 组变量 |
| nix-secrets 通用 | `~/codeWorkspace/nix-secrets/*.age` | 5 把 SSH key 中任意一把 | agenix 手动解密 |
| GPG / pass | `~/.local/share/password-store`（56 条） | GPG subkey | pass 命令 |

## 2. 钥匙的派生关系

SSH 私钥可以直接转换成 age 身份，转换公式是 `ssh-to-age`：

| SSH 私钥 | 派生的 age 公钥（前 16 位） | 备注 |
|---|---|---|
| `/etc/ssh/ssh_host_ed25519_key` | `age1wy5lwhs0s5kj` | 主机身份，随机器生成 |
| `~/.ssh/id_ed25519` | `age18punjd2wdz9s` | 个人身份，`.sops.yaml` 里的 zen14 admin |
| nova13 的对应 key | `age1hdh4aq9dhsnk` | `.sops.yaml` 里的 nova13 |

自查命令（只读公钥，安全）：

```bash
nix run nixpkgs#ssh-to-age -- -i /etc/ssh/ssh_host_ed25519_key.pub
nix run nixpkgs#ssh-to-age -- -i ~/.ssh/id_ed25519.pub
```

## 3. 各体系怎么解

### 3.1 NixOS 级 sops

由 `sops-nix` 在 activation 阶段自动完成，key 配置在 `modules/nixos/sops/default.nix`：

```nix
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

手工确认某个值（会输出明文，注意环境）：

```bash
sops -d --extract '["easytier/ali/network_secret"]' \
  ~/codeWorkspace/nix-secrets/secrets/env.yaml
```

### 3.2 home 级 sops

key 配置在 `modules/home/sops/default.nix`：

```nix
sops.age.sshKeyPaths = [ "/home/jojo/.ssh/id_ed25519" ];
```

### 3.3 clan vars

`clan/zen14.nix` 里每个 generator 对应 `vars/per-machine/zen14/<generator>/<file>/secret`，sops 元数据里有 **3 个 recipient**：

1. `age1wy5lwhs0s5kj`（host key）
2. `age18punjd2wdz9s`（`~/.ssh/id_ed25519`）
3. `age1hdh4aq9dhsnk`（nova13）

所以 host key 丢了还能用个人 key 解。

```bash
# 读某个变量（会输出明文）
nix run .#clan -- vars get zen14 deepseek-api-key/api-key

# 换值
nix run .#clan -- vars set zen14 cloudflare-r2/access-key-id
```

`vars set` 会自动 git commit（`vars: update xxx for machine zen14`），不需要手动 add。

### 3.4 nix-secrets 通用文件

`secrets.nix` 里 `publicKeys` 定义了 5 个 SSH 公钥，覆盖 zen14 / nova13 / bootstrap，任意一把私钥都能解。

```bash
# -d 需要同目录有 secrets.nix 才能定位 recipients
nix run nixpkgs#age -- -d -i ~/.ssh/id_ed25519 -o /tmp/out \
  ~/codeWorkspace/nix-secrets/secrets/env.yaml  # env.yaml 是 sops 格式，用 sops -d
```

### 3.5 GPG 私钥的双层 age 加密

`zrubing-primary-key.priv.age.age` 和 `zrubing-gpg-subkeys.priv.age.age` 是**双层 age**，设计来自
[个人数据安全不完全指南](https://thiscute.world/posts/an-incomplete-guide-to-data-security/)：
GPG 自身导出的备份强度不够，所以先做一次 passphrase 对称加密，再用 agenix 非对称加密。

| 层 | 加密方式 | 解密需要 |
|---|---|---|
| 内层 `.priv.age` | `age -p`（scrypt + ChaCha20-Poly1305） | 你设的 **age passphrase** |
| 外层 `.priv.age.age` | agenix/age，SSH 公钥 | `~/.ssh/id_ed25519` |

解密（第一层用 key，第二层交互输入 passphrase）：

```bash
cd ~/codeWorkspace/nix-secrets

# 第一层：SSH key
nix run nixpkgs#age -- -d -i ~/.ssh/id_ed25519 -o /tmp/step1 \
  zrubing-primary-key.priv.age.age

# 第二层：passphrase（会提示输入，不回显）
nix run nixpkgs#age -- -d -o /tmp/primary.asc /tmp/step1

# 导入 GPG
gpg --import /tmp/primary.asc

# 清理明文
shred -u /tmp/step1 /tmp/primary.asc
```

验证第一层确实是双层结构（解密后仍应以 `age-encryption.org/v1` 开头）：

```bash
head -c 22 /tmp/step1
```

## 4. 必须记住的凭据

这几个密码**不能存在任何机器上**，只能靠记忆或离线纸质备份：

| 凭据 | 作用 | 丢失后果 |
|---|---|---|
| age passphrase | 解 GPG 备份的内层 | GPG 私钥无法恢复 → pass 全库作废 |
| GPG 主密钥 passphrase | 使用 GPG（含 pass） | 同上 |
| LUKS passphrase | 开机解密系统盘 | 系统盘数据不可读 |
| SSH key passphrase | 使用 `~/.ssh/id_ed25519` 等 | 需重新生成 key 并 rekey 所有 secrets |

## 5. 灾难恢复流程

### 5.1 场景 A：host key 丢失

影响：NixOS 级 sops 解不开；clan vars 仍可用 `~/.ssh/id_ed25519` 解。

```bash
# 1) 确认个人 key 能解 clan vars
nix run .#clan -- vars get zen14 deepseek-api-key/api-key

# 2) 解出所有需要的值，或者
#    把 host key 的公钥换成新生成的，然后对 nix-secrets rekey
agenix -r -i ~/.ssh/id_ed25519

# 3) 更新 .sops.yaml 与 secrets.nix 里的 host key 公钥
```

### 5.2 场景 B：id_ed25519 丢失

影响：home 级 sops、nix-secrets 通用文件、clan vars（部分）解不开；host key 仍能解 NixOS sops 与 clan vars。

```bash
# 1) 用 host key 导出 clan vars 里需要的东西
nix run .#clan -- vars get zen14 cloudflare-api-token/token

# 2) 重新生成个人 key，公钥加回 secrets.nix 的 publicKeys 与 .sops.yaml
ssh-keygen -t ed25519 -a 256 -C "jojo@zen14"
agenix -r -i /etc/ssh/ssh_host_ed25519_key
```

### 5.3 场景 C：整机重装

前提：`~/.ssh/id_ed25519` 或 host key 至少有一把在手（离线备份）。

1. 装系统，生成 host key（`ssh-keygen -A`）。
2. 把新 host key 的公钥发到一台还能解 secrets 的机器。
3. 在那边把它加进 `secrets.nix` 的 `publicKeys` 和 `.sops.yaml`，跑 `agenix -r`，commit & push。
4. 新机器 `git clone` 配置仓库，`nixos-rebuild switch`，agenix 自动解密。
5. 用 `~/.ssh/id_ed25519` + age passphrase 解出 GPG 私钥，恢复 pass。

### 5.4 场景 D：pass 解不开

1. 先确认 GPG 私钥在不在：`gpg --list-secret-keys`。
2. 不在就从 `zrubing-gpg-subkeys.priv.age.age` 按 3.5 解出来导入。
3. 主密钥是 `sec#`（离线），只有 subkey 在本地 —— 解密 pass 只需要 subkey。

## 6. 当前缺口

1. **`/etc/ssh/ssh_host_ed25519_key` 没有备份**：不在 `/persistent`（本机无 impermanence），仓库里没有，密码管理器里没有。
2. **`~/.ssh/id_ed25519` 没有备份**：同样是单点。
3. 这两把是全部链条的根。nix-secrets 里的 GPG 备份、clan vars、sops 文件都只能间接恢复，前提是至少一把根 key 还活着。

建议（未执行）：

1. 把两把 key 离线备份：密码管理器 + 加密 U 盘，各一份。
2. host key 可以存进 `pass`（`pass insert -m ssh/zen14-host-ed25519`），因为 pass 本身可由 GPG 备份恢复。
3. `~/.ssh/id_ed25519` **不能**存进 pass（循环依赖），必须离线。

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `modules/nixos/sops/default.nix` | NixOS 级 sops key 与 secrets 声明 |
| `modules/home/sops/default.nix` | home 级 sops key 与模板 |
| `clan/zen14.nix` | clan vars generator 定义（18 组） |
| `~/.sops.yaml` | sops 的 creation_rules（zen14 / nova13 的 recipient） |
| `~/codeWorkspace/nix-secrets/secrets.nix` | agenix 的 recipients 映射 |
