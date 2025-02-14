{
  pkgs,
  config,
  lib,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.password-store;
  passwordStoreDir = "${config.xdg.dataHome}/password-store";
in
{
  options.${namespace}.password-store = with types; {
    enable = mkBoolOpt false "Enable password store";
  };

  config = mkIf cfg.enable {

    programs.password-store = {
      enable = true;
      package = pkgs.pass.withExtensions (exts: [
        # support for one-time-password (OTP) tokens
        # NOTE: Saving the password and OTP together runs counter to the purpose of secondary verification!
        # exts.pass-otp

        exts.pass-import # a generic importer tool from other password managers
        exts.pass-update # an easy flow for updating passwords
      ]);
      # See the “Environment variables” section of pass(1) and the extension man pages for more information about the available keys.
      settings = {
        PASSWORD_STORE_DIR = passwordStoreDir;
        # Overrides the default gpg key identification set by init.
        # Hexadecimal key signature is recommended.
        # Multiple keys may be specified separated by spaces.
        PASSWORD_STORE_KEY = lib.strings.concatStringsSep " " [
          "A9ED195DC6C80559" # E -  (For pass & ssh only) <rubingem@gmail.com>
        ];
        # all .gpg-id files and non-system extension files must be signed using a detached signature using the GPG key specified by
        #   the full 40 character upper-case fingerprint in this variable.
        # If multiple fingerprints are specified, each separated by a whitespace character, then signatures must match at least one.
        # The init command will keep signatures of .gpg-id files up to date.
        PASSWORD_STORE_SIGNING_KEY = lib.strings.concatStringsSep " " [
          "5DBB8F120FFDAB66" # S -  (For pass & ssh only) <rubingem@gmail.com>
        ];
        PASSWORD_STORE_CLIP_TIME = "60";
        PASSWORD_STORE_GENERATED_LENGTH = "12";
        PASSWORD_STORE_ENABLE_EXTENSIONS = "true";
      };
    };

    # password-store extensions for browsers
    # you need to install the browser extension for this to work
    # https://github.com/browserpass/browserpass-extension
    programs.browserpass = {
      enable = true;
      browsers = [
        "chrome"
        "chromium"
        "firefox"
        "brave"
      ];
    };

  };

}
