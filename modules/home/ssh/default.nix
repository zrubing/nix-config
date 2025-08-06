{ config, lib, namespace, ... }:
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
      # support for fish shell
      (lib.replaceStrings ["$\{XDG_RUNTIME_DIR}"] ["/run/user/1000"] config.age.secrets."ssh/topsap-config".path)
      (lib.replaceStrings ["$\{XDG_RUNTIME_DIR}"] ["/run/user/1000"] config.age.secrets."ssh/work-config".path)
      (lib.replaceStrings ["$\{XDG_RUNTIME_DIR}"] ["/run/user/1000"] config.age.secrets."ssh/default-config".path)
    ];
  };

}
