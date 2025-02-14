let
  xiaoxinpro13 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx/6PhpyCzr4QWkw9Ou2iIuahQ0Zj70iGdaXnW0PiFy jojo@nixos";
  hiar = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPs2xUK0p54bSzKxu2RCwK+RUXld6LO8Rfj+SPmXl9Mi hiar@nova13";
  xiaoxinpro13etc = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILNqk7fBgU5OGJtG5H+jKMtVCts6zcvrgWgpuP1R3o14 root@nixos";

in
{
  "miho-conf.age".publicKeys = [
    xiaoxinpro13
    xiaoxinpro13etc
    hiar
  ];
  "authinfo.age".publicKeys = [
    xiaoxinpro13
    xiaoxinpro13etc
    hiar
  ];
}
