{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.nix-ld;
in
{
  options.${namespace}.nix-ld.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable nix-ld runtime loader and compatibility libraries.";
  };

  config = lib.mkIf cfg.enable {
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc
    openssl
    pkgs.libxcomposite
    pkgs.libxtst
    pkgs.libxrandr
    pkgs.libxext
    pkgs.libx11
    pkgs.libxfixes
    libGL
    libva
    #pipewire.lib
    pkgs.libxcb
    pkgs.libxdamage
    pkgs.libxshmfence
    pkgs.libxxf86vm
    libelf

    # Required
    glib
    gtk3
    gtk2
    bzip2

    # Without these it silently fails
    pkgs.libxinerama
    pkgs.libxcursor
    pkgs.libxrender
    pkgs.libxscrnsaver
    pkgs.libxi
    pkgs.libsm
    pkgs.libice
    gnome2.GConf
    nspr
    nss
    cups
    libcap
    SDL2
    libusb1
    dbus-glib
    ffmpeg
    # Only libraries are needed from those two
    libudev0-shim

    # Verified games requirements
    pkgs.libxt
    pkgs.libxmu
    libogg
    libvorbis
    SDL
    SDL2_image
    glew_1_10
    libidn
    tbb

    # Other things from runtime
    flac
    freeglut
    libjpeg
    libpng
    libpng12
    libsamplerate
    libmikmod
    libtheora
    libtiff
    pixman
    speex
    SDL_image
    SDL_ttf
    SDL_mixer
    SDL2_ttf
    SDL2_mixer
    libappindicator-gtk2
    libdbusmenu-gtk2
    libindicator-gtk2
    libcaca
    libcanberra
    libgcrypt
    libvpx
    librsvg
    pkgs.libxft
    libvdpau
    pango
    cairo
    atk
    gdk-pixbuf
    fontconfig
    freetype
    dbus
    alsa-lib
    expat
    # Needed for electron
    libdrm
    mesa
    libxkbcommon

      libgbm
    ];
  };
}
