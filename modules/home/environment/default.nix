{
  config,
  pkgs,
  inputs,
  system,
  ...
}:
let
  username = config.snowfallorg.user.name;

in
{

  config = {

    home.sessionVariables = {

      # used by browser for wireshark
      SSLKEYLOGFILE = "/home/${username}/.ssl-key.log";

      # Force apps to use wayland
      NIXOS_OZONE_WL=1;

    };

  };

}
