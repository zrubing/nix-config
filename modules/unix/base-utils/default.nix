{ namespace, pkgs, ... }: {
  environment = {
    # Some tools that we need on every host
    systemPackages = with pkgs; [
      helix
      htop
      ripgrep
      git
      jq
      nushell
      ruby_3_3
      pkgs.${namespace}.wake-on-lan
      magic-wormhole-rs
    ];

    variables.EDITOR = "${pkgs.emacs}/bin/emacsclient -c -a \'emacs\'";
  };
}
