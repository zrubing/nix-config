# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{
  imports = let agenix-tag = "0.15.0";
  in [ # Include the results of the hardware scan.
    ./hardware-configuration.nix
    "${
      builtins.fetchTarball {
        url =
          "https://kkgithub.com/ryantm/agenix/archive/refs/tags/${agenix-tag}.tar.gz";
        sha256 = "01dhrghwa7zw93cybvx4gnrskqk97b004nfxgsys0736823956la";
      }
    }/modules/age.nix"
    ./home.nix

  ];

  nix.settings = {

    experimental-features = [ "nix-command" "flakes" ];
    #substituters =
    #  lib.mkForce [ "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store" ];
  };
  # Use the systemd-boot EFI boot loader.
  #boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.loader.systemd-boot.enable = false;

  boot.loader = {
    grub = {
      device = "nodev";
      enable = true;
      efiSupport = true;
      gfxmodeEfi = "640x480";
    };
  };
  # networking.hostName = "nixos"; # Define your hostname.
  # Pick only one of the below networking options.
  #networking.wireless.enable =
  #  true; # Enables wireless support via wpa_supplicant.

  networking.networkmanager = { enable = true; };
  #networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "Asia/Shanghai";

  environment.sessionVariables = {
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_CACHE_HOME = "$HOME/.cache";
  };

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [ rime-data fcitx5-gtk fcitx5-rime ];
  };

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "${pkgs.terminus_font}/share/consolefonts/ter-u28n.psf.gz";
    keyMap = lib.mkForce "us";
    useXkbConfig = true; # use xkb.options in tty.
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  #services.xserver.dpi = 180;
  environment.variables = {
    NIX_BUILD_CORES = 16;
    EDITOR = "emacs";
    #  GDK_SCALE = "2";
    #  GDK_DPI_SCALE= "0.5";
    #  _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
  };

  # Configure keymap in X11
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.options = "ctrl:nocaps";

  services.emacs.defaultEditor = true;
  services.xserver = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    desktopManager.runXdgAutostartIfNone = true;
  };
  age.secrets.miho-conf.file = ./secrets/miho-conf.age;
  age.identityPaths = [ "/home/jojo/.ssh/id_ed25519" ];
  services.mihomo = {
    enable = true;
    configFile = "/run/agenix/miho-conf";
    tunMode = true;
  };
  environment.gnome.excludePackages = (with pkgs; [
    gnome-photos
    gnome-tour
    gedit
    cheese
    gnome-music
    epiphany
    geary
    evince
    gnome-characters
    totem
    iagno
    hitori
    atomix
  ]) ++ (with pkgs.gnome;
    [

    ]);
  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  #hardware.pulseaudio.enable = true;
  # OR
  #services.pipewire = {
  #   enable = false;
  #   pulse.enable = true;
  #};

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.jojo = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [ tree ];
    initialPassword = "test";
  };

  programs.firefox.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    emacs
    brave
    fd
    ripgrep
    nixfmt
    git
    localsend

  ];

  programs.localsend = {
    openFirewall = true;
    enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;
  networking.firewall = {
    logRefusedPackets = true;
    logRefusedConnections = true;
    enable = false;
  };

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "24.11"; # Did you read the comment?

}

