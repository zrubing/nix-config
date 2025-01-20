{ config, lib, namespace, ... }: {
  options.home = lib.mkOption { type = lib.types.anything; };

  config = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
    };

    snowfallorg.users.${config.${namespace}.user.name}.home.config =
      config.home;
  };
}
