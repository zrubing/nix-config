{ config, lib, namespace, ... }:
let cfg = config.${namespace}.user;
in {
  options.${namespace}.user = with lib; {
    name = mkOption {
      description = "Username of the main user";
      type = types.str;
    };
    fullName = mkOption {
      description = "Full name of the main user";
      type = types.str;
      default = cfg.name;
    };
    # email = mkOption {
    #   description = "Email of the main user";
    #   type = types.str;
    # };
  };

  config.users.users.${cfg.name} = {
    uid = 1000;
    isNormalUser = true;
    description = cfg.fullName;
    extraGroups = [
      "wheel"
      "dialout" # Enable access to serial devices
    ] ++ lib.optional config.programs.wireshark.enable "wireshark"
      #      ++ lib.optional config.programs.gamemode.enable "gamemode"
      ++ lib.optional config.networking.networkmanager.enable "networkmanager"
      ++ lib.optional config.virtualisation.docker.enable "docker";
  };
}
