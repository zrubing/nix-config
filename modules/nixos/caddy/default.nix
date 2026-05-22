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
      hash = "sha256-uYoYf1Xb/tp3MQA/+0zHdCczgiotuzRPdXA6pg2Ha40=";
    };
    configFile = cfgFile;
  };

}
