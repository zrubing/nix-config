{ lib, namespace, ... }: {
  options.${namespace}.host = with lib; {
    pubKey = mkOption {
      type = types.nullOr types.str;
      default = null;
    };

    ip = {
      local = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      remote = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      tailscale = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    ssh = { allowRootLogin = mkOption { type = types.bool; }; };
  };
}
