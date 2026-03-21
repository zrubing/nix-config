{
  config,
  inputs,
  lib,
  system,
  ...
}:
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  hostName = config.networking.hostName;
  easytierIpByHost = {
    zen14 = "10.144.200.2";
    nova13 = "10.144.200.3";
  };
  easytierIp = easytierIpByHost.${hostName} or null;
  easytierInstanceName = "easytier-net-${hostName}";
in
{

  # # 导入不稳定版本的 模块
  # imports = [
  #   "${inputs.nixpkgs-unstable}/nixos/modules/services/networking/easytier.nix"
  # ];

  sops.templates."easytier-config" = lib.mkIf (easytierIp != null) {
    content = ''
      instance_name = "${hostName}"

      [network_identity]
      network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
      network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/ali/peer"}"
    '';
  };

  services.easytier = lib.mkIf (easytierIp != null) {
    enable = true;
    package = pkgs-unstable.easytier;
    instances.${easytierInstanceName} = {
      extraArgs = [
        "-i"
        easytierIp
        "--accept-dns"
        "true"
      ];
      configFile = "${config.sops.templates."easytier-config".path}";
    };
  };
}
