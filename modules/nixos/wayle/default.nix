{
  config,
  lib,
  namespace,
  ...
}:
{
  options.${namespace}.wayle.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable Wayle shell (system-level toggle).";
  };

  config = lib.mkIf config.${namespace}.wayle.enable {
    # Wayle is a per-user shell; the actual enablement is handled by the
    # home-manager module at modules/home/wayle/. This NixOS module exists
    # only to provide the option anchor so that NixOS-level configs can
    # set ${namespace}.wayle.enable without triggering "option does not exist".
  };
}
