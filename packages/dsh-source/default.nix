{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (inputs) deepseek-harness-src;

  # Moraxyc 移植：importPnpmLock 把 pnpm-lock.yaml(JSON) 转成 fetchPnpmDeps 可用的源；
  importPnpmLock = (import ../../pkgs/dsh-moraxyc/importPnpmLock/package.nix {
    inherit lib;
    inherit (pkgs) stdenvNoCC fetchurl fetchgit fetchPnpmDeps runCommand pnpm writers;
  });

  dshWorkspacePatchHook = pkgs.callPackage ../../pkgs/dsh-moraxyc/dshWorkspacePatchHook/package.nix { };

  # dsh-workspace 与 dsh-landlock-run 相互引用（后者只取前者的 version 元数据、
  # 前者复制后者的 landlock-run 二进制），用惰性 let 互相绑定。
  dsh-workspace = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-workspace/package.nix {
    inherit
      deepseek-harness-src
      importPnpmLock
      dshWorkspacePatchHook
      dsh-landlock-run
      ;
  };

  dsh-landlock-run = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-landlock-run/package.nix {
    inherit dsh-workspace;
  };

  # 自包含 kernel（lib/deepseek-harness + bin/dsh）。
  dsh-kernel = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-kernel/package.nix { inherit dsh-workspace; };
in
dsh-kernel
