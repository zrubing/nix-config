{ config, namespace, ... }: {
  imports = [ ../../unix/home-manager ];

  home.home.stateVersion = config.system.stateVersion;
}
