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
      hash = "sha256-W9dc/UT0AhrWrnQyUBDrb3OuuKIgd7+2a7fHu1w7NIM=";
    };
    configFile = cfgFile;
  };

}
