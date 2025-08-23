{ pkgs, config, ... }:
{

  home.file = {
    home.file.".mozilla/native-messaging-hosts/com.github.browserpass.native.json".source =
      "${pkgs.browserpass}/lib/mozilla/native-messaging-hosts/com.github.browserpass.native.json";
  };
}
