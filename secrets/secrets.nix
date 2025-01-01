let
  xiaoxinpro13 =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEx/6PhpyCzr4QWkw9Ou2iIuahQ0Zj70iGdaXnW0PiFy jojo@nixos";

in { "miho-conf.age".publicKeys = [ xiaoxinpro13 ]; }
