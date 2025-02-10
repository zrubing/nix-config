let
  xiaoxinpro13 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx/6PhpyCzr4QWkw9Ou2iIuahQ0Zj70iGdaXnW0PiFy jojo@nixos";
  hiar = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPs2xUK0p54bSzKxu2RCwK+RUXld6LO8Rfj+SPmXl9Mi hiar@nova13";

in
{
  "miho-conf.age".publicKeys = [
    xiaoxinpro13
    hiar
  ];
  "authinfo.age".publicKeys = [
    xiaoxinpro13
    hiar
  ];
}
