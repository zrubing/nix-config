{
  config,
  inputs,
  system,
  ...
}:
let

  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
in
{

  # 导入不稳定版本的 模块
  imports = [
    "${inputs.nixpkgs-unstable}/nixos/modules/services/networking/easytier.nix"
  ];

  sops.templates."easytier-config".content = ''
    instance_name = "zen14"

    [network_identity]
    network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
    network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

    [[peer]]
    uri = "${config.sops.placeholder."easytier/ali/peer"}"
  '';

  services.easytier = {
    enable = true;
    package = pkgs-unstable.easytier;
    instances.easytier-net-zen14 = {

      extraArgs = [
        "-i"
        "10.144.144.2"
      ];
      configFile = "${config.sops.templates."easytier-config".path}";
    };
  };
}
