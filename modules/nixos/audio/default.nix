{ config, lib, namespace, ... }:
let cfg = config.${namespace}.audio;
in {
  options.${namespace}.audio = with lib; {
    enable = mkEnableOption "Enable audio for this device";
  };

  config = lib.mkIf cfg.enable {
    # Use pipewire.
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      jack.enable = true;
    };

    # Allow Pipewire to acquire realtime priority.
    security.rtkit.enable = true;
  };
}
