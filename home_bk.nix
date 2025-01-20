{ config, pkgs, ... }:
let home-manager-tag = "24.11";
in {
  imports = [

    "${
      builtins.fetchTarball {
        url =
          "https://ghgo.xyz/https://github.com/nix-community/home-manager/archive/release-${home-manager-tag}.tar.gz";
        sha256 = "0b41b251gxbrfrqplp2dkxv00x8ls5x5b3n5izs4nxkcbhkjjadz";
      }
    }/nixos"
  ];

  home-manager.users.jojo = { home.stateVersion = "${home-manager-tag}"; };

}
