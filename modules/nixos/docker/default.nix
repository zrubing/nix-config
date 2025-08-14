{

  lib,
  pkgs,
  ...

}:
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
    pkgs.docker-compose
    pkgs.podman-tui
    pkgs.dive
  ];

  virtualisation = {
    containers.enable = true;
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
