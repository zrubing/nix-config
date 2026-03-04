{
  config,
  ...
}:
let
  username = config.snowfallorg.user.name;

in
{

  config = {

    home.sessionVariables = {

      # used by browser for wireshark
      SSLKEYLOGFILE = "/home/${username}/.ssl-key.log";

      # Force apps to use wayland
      NIXOS_OZONE_WL = 1;

      SUDO_EDITOR = "emacsclient --create-frame";

      # Rust / Cargo
      CARGO_HOME = "/home/${username}/.cargo";
      RUSTUP_HOME = "/home/${username}/.rustup";
      RUSTUP_DIST_SERVER = "https://rsproxy.cn";
      RUSTUP_UPDATE_ROOT = "https://rsproxy.cn/rustup";
      CARGO_REGISTRIES_CRATES_IO_PROTOCOL = "sparse";
      CARGO_NET_GIT_FETCH_WITH_CLI = "true";
    };

    home.sessionPath = [ "/home/${username}/.cargo/bin" ];

    xdg.configFile."cargo/config.toml".text = ''
      [source.crates-io]
      replace-with = "rsproxy-sparse"

      [source.rsproxy-sparse]
      registry = "sparse+https://rsproxy.cn/index/"

      [registries.rsproxy]
      index = "sparse+https://rsproxy.cn/index/"

      [net]
      git-fetch-with-cli = true
    '';

  };

}
