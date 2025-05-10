{ config, namespace, ... }:
{

  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host github.com
        Hostname github.com
        IdentityFile ~/.ssh/id_ed25519
        # Specifies that ssh should only use the identity file explicitly configured above
        # required to prevent sending default identity files first.
        IdentitiesOnly yes
    '';

    includes = [
      "${config.age.secrets."ssh/topsap-config".path}"
      "${config.age.secrets."ssh/work-config".path}"
    ];
  };

}
