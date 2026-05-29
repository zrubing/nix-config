{ config, inputs, lib, pkgs, ... }:
let
  cfgFile = config.age.secrets.caddy-conf.path;
  mysecrets = inputs.mysecrets;
in
{

  age.secrets.caddy-conf = {
    file = "${mysecrets}/caddy-conf.age";
    owner = "caddy";
    group = "users";
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [
        "github.com/mholt/caddy-l4@v0.1.0"
      ];
      hash = "sha256-y/6EG9SK40KNpi8isCfNPtwjwN4X2a1H40GTFw9AaQk=";
    };
    configFile = cfgFile;
  };

}
