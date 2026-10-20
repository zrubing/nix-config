


# Nix 配置仓库

基于 Snowfall Lib 的 Nix flake 配置仓库，用于管理 NixOS 和 Home Manager 配置。

## 快速开始

### 构建配置
```bash
# 构建 NixOS 配置
nix build .#nixosConfigurations.zen14.config.system.build.toplevel

# 构建 Home Manager 配置
nix build .#homeConfigurations.jojo.activationPackage

# 应用配置更改
sudo nixos-rebuild switch --flake .#
home-manager switch --flake .#jojo
```

## 二进制缓存（cachix）

自建包推到 `https://zrubing.cachix.org`（公开读，`cliphist-gui` 这类 nixpkgs 里没有的包），
另一台机器直接替代、不必重建。nixpkgs 依赖不用推。

```bash
cd ~/nix-config
nix build .#<pkg> --no-link --print-out-paths \
  | CACHIX_AUTH_TOKEN=$(grep -oP 'CACHIX_AUTH_TOKEN="\K[^"]+' ~/.config/default.env) \
    xargs nix run nixpkgs#cachix -- push zrubing
```

token 存 clan vars（`clan vars set zen14 cachix-auth-token/token`），客户端配置在
`modules/unix/nix-settings`。完整流程、验证方法和配额边界见
[docs/binary-cache.md](docs/binary-cache.md)。

## Nix 验证方法

### 1. 构建验证
```bash
# 验证系统配置构建
nix build .#nixosConfigurations.zen14.config.system.build.toplevel

# 检查 flake 配置
nix flake check

# 验证 Home Manager 配置
nix run nixpkgs#home-manager -- switch --flake .#jojo
```

### 2. 包冲突检测
```bash
# 搜索特定包的所有引用
grep -r "prettier" --include="*.nix" .

# 查找重复包定义
grep -r "nodePackages.prettier" --include="*.nix" .

# 检查构建环境冲突
nix build .#nixos-config 2>&1 | grep "conflicting subpath"
```

### 3. 配置测试
```bash
# 测试用户配置
nix build .#homeConfigurations.jojo.activationPackage

# 验证模块加载
home-manager switch --flake .#jojo --dry-run

# 检查配置语法
nix-instantiate --eval --expr 'import ./flake.nix'
```

