# Snowfall Lib provides access to additional information via a primary argument of
# your overlay.
{
  # Channels are named after NixPkgs instances in your flake inputs. For example,
  # with the input `nixpkgs` there will be a channel available at `channels.nixpkgs`.
  # These channels are system-specific instances of NixPkgs that can be used to quickly
  # pull packages into your overlay.
  channels,

  # Inputs from your flake.
  inputs,
  ... }:

  final: prev: let
    rime-ice-pkg = prev.callPackage ./rime-ice.nix {};
  in{


    rime-ice = rime-ice-pkg;

    # # 小鹤音形配置，配置来自 flypy.com 官方网盘的鼠须管配置压缩包「小鹤音形“鼠须管”for macOS.zip」
    # # 我仅修改了 default.yaml 文件，将其中的半角括号改为了直角括号「 与 」。
    # rime-data = ./rime-data-flypy;
    fcitx5-rime = prev.fcitx5-rime.override {rimeDataPkgs = [rime-ice-pkg];};

    # # used by macOS Squirrel
    # flypy-squirrel = ./rime-data-flypy;

  }
