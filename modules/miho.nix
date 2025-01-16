{ pkgs, ... }: {

  age.secrets.miho-conf.file = ../secrets/miho-conf.age;
  age.identityPaths = [ "/home/jojo/.ssh/id_ed25519" ];

  services.mihomo = {
    enable = true;
    configFile = "/run/agenix/miho-conf";
    tunMode = true;
  };
}
