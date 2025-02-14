{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
with lib;
let

  username = config.snowfallorg.user.name;
  mysecrets = inputs.mysecrets;
  cfg = config.modules.secrets;
  #agenix = inputs.agenix;

  enabledServerSecrets =
    cfg.server.application.enable
    || cfg.server.network.enable
    || cfg.server.operation.enable
    || cfg.server.kubernetes.enable
    || cfg.server.webserver.enable
    || cfg.server.storage.enable;

  noaccess = {
    mode = "0000";
    owner = "root";
  };
  high_security = {
    mode = "0500";
    owner = "root";
  };
  user_readable = {
    mode = "0500";
    owner = username;
  };
in
{
  # imports = [
  #   agenix.nixosModules.default
  # ];

  options.modules.secrets = {
    desktop.enable = mkEnableOption "NixOS Secrets for Desktops";

    server.network.enable = mkEnableOption "NixOS Secrets for Network Servers";
    server.application.enable = mkEnableOption "NixOS Secrets for Application Servers";
    server.operation.enable = mkEnableOption "NixOS Secrets for Operation Servers(Backup, Monitoring, etc)";
    server.kubernetes.enable = mkEnableOption "NixOS Secrets for Kubernetes";
    server.webserver.enable = mkEnableOption "NixOS Secrets for Web Servers(contains tls cert keys)";
    server.storage.enable = mkEnableOption "NixOS Secrets for HDD Data's LUKS Encryption";

    impermanence.enable = mkEnableOption "whether use impermanence and ephemeral root file system";
  };

  config = mkIf (cfg.desktop.enable || enabledServerSecrets) (mkMerge [
    {

      # if you changed this key, you need to regenerate all encrypt files from the decrypt contents!
      age.identityPaths =
        if cfg.impermanence.enable then
          [
            # To decrypt secrets on boot, this key should exists when the system is booting,
            # so we should use the real key file path(prefixed by `/persistent/`) here, instead of the path mounted by impermanence.
            "/persistent/etc/ssh/ssh_host_ed25519_key" # Linux
          ]
        else
          [
            "/etc/ssh/ssh_host_ed25519_key"
          ];

      assertions = [
        {
          # This expression should be true to pass the assertion
          assertion = !(cfg.desktop.enable && enabledServerSecrets);
          message = "Enable either desktop or server's secrets, not both!";
        }
      ];
    }

    (mkIf cfg.desktop.enable {
      age.secrets = {
        # ---------------------------------------------
        # no one can read/write this file, even root.
        # ---------------------------------------------

        # .age means the decrypted file is still encrypted by age(via a passphrase)
        "zrubing-gpg-subkeys.priv.age" = {
          file = "${mysecrets}/zrubing-gpg-subkeys.priv.age.age";
        } // noaccess;

        # ---------------------------------------------
        # only root can read this file.
        # ---------------------------------------------

        # "rclone.conf" = {
        #   file = "${mysecrets}/rclone.conf.age";
        # } // high_security;

        "authinfo" = {
          file = "${mysecrets}/authinfo.age";
        } // high_security;


        "miho-conf" = {
          file = "${mysecrets}/miho-conf.age";
        } // high_security;


        # ---------------------------------------------
        # user can read this file.
        # ---------------------------------------------

      };

      # # place secrets in /etc/
      # environment.etc = {

      #   "agenix/rclone.conf" = {
      #     source = config.age.secrets."rclone.conf".path;
      #   };

      #   "agenix/zrubing-gpg-subkeys.priv.age" = {
      #     source = config.age.secrets."zrubing-gpg-subkeys.priv.age".path;
      #     mode = "0000";
      #   };

      # };
    })

    (mkIf cfg.server.network.enable {
      age.secrets = {

      };
    })

    (mkIf cfg.server.application.enable {
      age.secrets = {

      };
    })

    (mkIf cfg.server.operation.enable {
      age.secrets = {

      };
    })

    (mkIf cfg.server.kubernetes.enable {
      age.secrets = {
      };
    })

    (mkIf cfg.server.webserver.enable {
      age.secrets = {

      };
    })

    (mkIf cfg.server.storage.enable {
      age.secrets = {
      };

      # place secrets in /etc/
      # environment.etc = {
      # };
    })
  ]);
}
