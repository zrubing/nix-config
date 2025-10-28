{

  lib,
  pkgs,
  inputs,
  system,
  ...

}:
let

  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
in
{
  # environment.systemPackages = [ pkgs.docker-compose ];

  # virtualisation = {
  #   docker = {
  #     enable = true;
  #     daemon.settings = {
  #       bip = "172.120.0.1/16";
  #       default-address-pools = [
  #         {
  #           base = "10.219.0.0/16";
  #           size = 24;
  #         }
  #       ];
  #     };
  #     rootless = {
  #       enable = true;
  #       setSocketVariable = true;
  #     };
  #   };

  # };

  environment.systemPackages = [
    pkgs.distrobox
    pkgs.podman-compose
    pkgs.podman-tui
    pkgs.slirp4netns
    pkgs.dive
    pkgs.netavark
    pkgs.podman-tui
    pkgs.passt
  ];

  users.groups.podman = {
    name = "podman";
  };

  # 给所有用户生效
  # https://github.com/containers/common/blob/main/docs/containers.conf.5.md
  virtualisation = {
    containers.enable = true;
    containers.containersConf.settings = {
      containers = {
        # netns = "bridge";
        default_capabilities = [
          "NET_RAW"
          "NET_BIND_SERVICE"
        ];

      };
    };

    podman = {
      dockerSocket.enable = true;
      enable = true;
      # Create a `docker` alias for podman, to use it as a drop-in replacement
      dockerCompat = true;
      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;

      # Periodically prune Podman resources
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
    };

    oci-containers = {
      backend = "podman";
    };
  };

  # # Useful other development tools
  # environment.systemPackages = with pkgs; [
  #   dive # look into docker image layers
  #   podman-tui # status of containers in the terminal
  #   docker-compose # start group of containers for dev
  #   #podman-compose # start group of containers for dev
  # ];
}
