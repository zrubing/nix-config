


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

