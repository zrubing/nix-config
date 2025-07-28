{
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  lib,
  makeWrapper,
  xorg,
  libappindicator-gtk3,
  systemd,
  ncurses5,
  libxcrypt-legacy,
  nss,
  alsa-lib,
  pkgs,
  unzip,
  patchelf,
}:
let
  libcrypt-compat = stdenv.mkDerivation {
    name = "libcrypt-compat";
    buildInputs = [ libxcrypt-legacy ];
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/lib
      ln -s ${libxcrypt-legacy}/lib/libcrypt.so $out/lib/libcrypt.so.1
    '';
  };

  libwidevinecdm-compat = stdenv.mkDerivation rec {
    pname = "widevine-cdm";
    version = "4.10.2710.0";
    src = fetchurl {
      url = "https://dl.google.com/widevine-cdm/${version}-linux-x64.zip";
      sha256 = "sha256-wSDl0Dym61JD1MaaakNI4SEjOCSrJtuRJqU7qZcJ0VI=";
    };
    nativeBuildInputs = [ unzip ];
    unpackPhase = "unzip $src";
    installPhase = ''
      mkdir -p $out/lib
      cp libwidevinecdm.so $out/lib/
    '';
  };
in
stdenv.mkDerivation rec {
  pname = "sunloginclient";
  version = "15.2.0.63064";
  src = fetchurl {
    url = "https://dw.oray.com/sunlogin/linux/SunloginClient_${version}_amd64.deb";
    sha256 = "sha256-3a5dNk64tpQGoOGDSQRQ/S+R8HKXKzcI6VGOiFLLimM=";
  };

  nativeBuildInputs = [
    dpkg
    (autoPatchelfHook.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (pkgs.writeText "skip-invalid-elf.patch" ''
          diff --git a/bin/auto-patchelf b/bin/auto-patchelf
          index abc1234..def5678 100755
          --- a/bin/auto-patchelf
          +++ b/bin/auto-patchelf
          @@ -204,6 +204,9 @@ def auto_patchelf_file(
               return []

           try:
          +    if not os.path.isfile(path) or os.path.getsize(path) == 0:
          +        return []
          +
               elf = ELFFile(open(path, "rb"))
               if is_static_executable(elf):
                   return []
        '')
      ];
    }))
    makeWrapper
    patchelf
  ];

  buildInputs = [
    xorg.libX11
    xorg.libXtst
    xorg.libXrandr
    xorg.libXinerama
    xorg.libxcb
    xorg.libXext
    xorg.libXi
    xorg.libXrender
    xorg.libXau
    libappindicator-gtk3
    ncurses5
    libcrypt-compat
    nss
    alsa-lib
    xorg.libXScrnSaver
    pkgs.gnome2.GConf
    libwidevinecdm-compat
  ];

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    mkdir -p $out
    cp -r usr/local/sunlogin/* $out/
    mkdir -p $out/usr/local/sunlogin
    ln -s $out/res $out/usr/local/sunlogin/res
  '';

  postFixup = ''
    # 手动修补 ELF 文件
    find $out -type f -executable -exec sh -c '
      file -b "$1" | grep -q "ELF" && patchelf --set-rpath "${lib.makeLibraryPath buildInputs}:$out/lib" "$1"
    ' sh {} \;

    # 包装程序
    wrapProgram $out/bin/sunloginclient \
      --prefix LD_LIBRARY_PATH : "$out/lib:${lib.makeLibraryPath buildInputs}" \
      --set CEF_RESOURCES_DIR "$out/res" \
      --set CEF_LOCALES_DIR "$out/res"
  '';

  meta = with lib; {
    description = "Sunlogin Remote Control Client";
    homepage = "https://sunlogin.oray.com/";
    platforms = [ "x86_64-linux" ];
  };
}
