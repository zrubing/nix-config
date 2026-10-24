# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 公开仓库约束（最重要）

本仓库公开在 GitHub，任何提交永久留痕，会泄露的内容不可撤回。

1. `docs/`、代码注释、commit message 只写**机制、路径、命令**，不写**标识符**：Cloudflare account id、R2 bucket 名与 endpoint、内网/公网 IP、各类 token、密钥指纹、主机名与账号的对应关系。
2. 具体值放 clan vars（`vars/per-machine/<host>/<generator>/<file>`，sops 加密）或 `pass`，文档里用 `<bucket>`、`<account-id>` 这类占位符。
3. 写任何文档前先问：这条信息被陌生人看到，能用来做什么？如果答案是「能定位、能冒充、能免密访问」，就不能写。
4. 加密后的 secrets（`vars/**/secret`、`.age`、sops 文件）可以入库；解密用的 key、passphrase、凭据一律不入库。

完整说明见 `docs/secrets-recovery.md`。

## Repository Overview

This is a Nix flake-based configuration repository using Snowfall Lib for managing NixOS and Home Manager configurations. The repository follows a modular structure with separate configurations for different systems and users.

## Architecture

### Core Structure
- **flake.nix**: Main flake definition using Snowfall Lib framework
- **homes/**: Home Manager configurations organized by platform and user
- **systems/**: NixOS system configurations
- **modules/**: Reusable modules for NixOS, Home Manager, and platform-specific configurations
- **packages/**: Custom package definitions
- **overlays/**: Package overlays for customizing nixpkgs

### Key Frameworks
- **Snowfall Lib**: Provides the organizational structure and module system
- **Home Manager**: Manages user-level dotfiles and packages
- **Agenix**: Secrets management
- **SOPS-nix**: Alternative secrets management

## Development Commands

### Building and Testing
```bash
# Build NixOS configuration
nix build .#nixos-config

# Build home configuration
nix build .#homeConfigurations.jojo.activationPackage

# Apply configuration changes
sudo nixos-rebuild switch --flake .#
home-manager switch --flake .#

# Check configuration without building
nix flake check
```

### Development Workflow
```bash
# Update flake inputs
nix flake update

# Enter development shell (if defined)
nix develop

# Search for packages
nix search nixpkgs <package-name>

# Show dependency tree
nix flake metadata
```

### Secrets Management
```bash
# Edit secrets with agenix
agenix -e <secret-file>.age

# Re-key secrets for new hosts
agenix --rekey
```

## Module System

The repository uses Snowfall Lib's module system for organization:

### Module Categories
- `modules/nixos/`: NixOS system modules
- `modules/home/`: Home Manager modules
- `modules/darwin/`: macOS-specific modules
- `modules/unix/`: Cross-platform Unix modules

### Module Structure
Modules are defined as Nix functions that accept `{ lib, config, pkgs, ... }` parameters and should follow standard Nix module conventions.

## Custom Packages

Custom packages are defined in `packages/` directory:
- Each package has its own subdirectory
- Packages can be referenced in configurations via `pkgs.<package-name>`
- Overlay definitions in `overlays/` customize existing packages

## Configuration Patterns

### Home Manager Configuration
User configurations are located in `homes/<platform>/<username>/default.nix` and enable various modules through the `internal` configuration attribute.

### System Configuration
System configurations follow Snowfall Lib patterns and are located in `systems/<platform>/`.

### Module Options
Custom modules should define options under `internal.<module-name>.enable` for consistency.

## Input Sources

The flake uses various external inputs including:
- nixpkgs (stable and unstable)
- home-manager
- emacs-overlay
- doomemacs
- niri-flake
- sops-nix
- agenix
- Various grammar and utility repositories

## Environment Setup

The repository uses direnv (`.envrc` file) for environment management. Ensure direnv is installed and enabled for automatic shell integration.