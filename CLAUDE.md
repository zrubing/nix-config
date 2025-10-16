# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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