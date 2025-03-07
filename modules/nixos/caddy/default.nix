{ config,inputs,... }:
let
  cfgFile = config.age.secrets.caddy-conf.path;
  mysecrets = inputs.mysecrets;
in
{

  age.secrets.caddy-conf={
    file = "${mysecrets}/caddy-conf.age";
    owner = "caddy";
    group = "users";
  };

  services.caddy = {
    enable = true;
    configFile = cfgFile;
  };

}
