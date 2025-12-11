{
  pkgs,
  lib,
  stdenv,
  fetchurl,
  dpkg,
}:

let
  version = "3.1.18";

  src = fetchurl {
    url = "https://cdn.isealsuite.com/linux/FeiLian_Linux_amd64_v${version}_r6560_8a2fab.deb";
    sha256 = "1nzvwcxmwl072w4sik2ivfydi4hdwg6dbv74qm7j2434s98sdmqa";
  };

  feilian-unpacked = stdenv.mkDerivation {
    pname = "feilian-unpacked";
    inherit version src;
    nativeBuildInputs = [ dpkg ];
    unpackPhase = "true";
    installPhase = ''
      mkdir -p $out
      dpkg-deb -x $src $out
      find $out -type f -name "corplink*" -exec chmod +x {} \;
    '';
  };

  fhsEnv = pkgs.buildFHSEnv {
    name = "feilian-fhs";

    # 依然保留 multiPkgs 以处理 glibc/gcc 等基础库
    multiPkgs = pkgs: with pkgs; [
      mesa
      libglvnd
      libdrm
      glibc
      gcc.cc.lib
    ];

    targetPkgs = pkgs: with pkgs; [
      # 常用依赖
      gtk3
      glib
      nss
      nspr
      xorg.libX11
      xorg.libxcb
      xorg.libXcomposite
      xorg.libXcursor
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXi
      xorg.libXrender
      xorg.libXtst
      xorg.libXrandr
      xorg.libXScrnSaver
      alsa-lib
      dbus
      at-spi2-core
      pango
      cairo
      gdk-pixbuf
      libnotify
      libappindicator-gtk3
      libsecret
      systemd
      udev
      libxkbcommon
      curl
      iproute2
      iptables
      kmod
      dnsmasq
      procps
      nettools
      which
      binutils # for ldd
    ];

    # 【关键修改】
    # 创建一个独立的目录 /feilian-libs，避免被 /usr/lib 的挂载遮挡
    extraBuildCommands = ''
      # 1. 修复加载器
      mkdir -p lib
      if [ ! -e lib/ld-linux-x86-64.so.2 ]; then
        ln -s /lib64/ld-linux-x86-64.so.2 lib/ld-linux-x86-64.so.2
      fi

      # 2. 创建自定义库目录
      mkdir -p feilian-libs

      # 3. 强制链接 libgbm 和 libdrm 到自定义目录
      ln -sf ${pkgs.mesa}/lib/libgbm.so.1 feilian-libs/libgbm.so.1
      ln -sf ${pkgs.mesa}/lib/libgbm.so feilian-libs/libgbm.so
      ln -sf ${pkgs.libdrm}/lib/libdrm.so.2 feilian-libs/libdrm.so.2

      # 4. 链接 libudev (有时 systemd 路径也会有问题)
      ln -sf ${pkgs.systemd}/lib/libudev.so.1 feilian-libs/libudev.so.1
      ln -sf ${pkgs.systemd}/lib/libudev.so feilian-libs/libudev.so
    '';

    extraBwrapArgs = [
      "--bind" "${feilian-unpacked}/opt" "/opt"
    ];

    # 【关键修改】
    # 将 /feilian-libs 加入 LD_LIBRARY_PATH 的最前面
    profile = ''
      export LD_LIBRARY_PATH=/feilian-libs:/usr/lib:/usr/lib64:/lib:/lib64:$LD_LIBRARY_PATH
      export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS
    '';

    runScript = "bash";
  };

  feilian-bin = pkgs.writeShellScriptBin "feilian" ''
    exec ${fhsEnv}/bin/feilian-fhs -c "/opt/apps/com.volcengine.feilian/files/corplink --no-sandbox"
  '';

  feilian-service-bin = pkgs.writeShellScriptBin "feilian-service" ''
    mkdir -p /etc/NetworkManager/dnsmasq.d
    exec ${fhsEnv}/bin/feilian-fhs -c "/opt/apps/com.volcengine.feilian/files/corplink-service"
  '';

  feilian-debug-bin = pkgs.writeShellScriptBin "feilian-debug" ''
    echo "Entering FeiLian FHS environment..."
    exec ${fhsEnv}/bin/feilian-fhs -c "
      echo '--- Checking custom libs directory ---'
      ls -l /feilian-libs
      echo '--- Checking LD_LIBRARY_PATH ---'
      echo \$LD_LIBRARY_PATH
      echo '--- Checking ldd again ---'
      ldd /opt/apps/com.volcengine.feilian/files/corplink | grep 'not found'
      bash
    "
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "FeiLian";
    desktopName = "FeiLian";
    genericName = "飞连客户端";
    exec = "${feilian-bin}/bin/feilian";
    icon = "${feilian-unpacked}/opt/apps/com.volcengine.feilian/entries/icons/hicolor/256x256/apps/com.volcengine.feilian.png";
    categories = [ "Network" ];
  };

  systemdService = pkgs.writeText "corplink.service" ''
    [Unit]
    Description=FeiLian Service
    After=network.target

    [Service]
    Type=simple
    ExecStart=${feilian-service-bin}/bin/feilian-service
    Restart=on-failure
    RestartSec=3s
    User=root
    Group=root
    CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
    AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN

    [Install]
    WantedBy=multi-user.target
  '';

in
stdenv.mkDerivation {
  pname = "feilian";
  inherit version;

  src = feilian-unpacked;

  installPhase = ''
    mkdir -p $out/bin
    mkdir -p $out/share/applications
    mkdir -p $out/lib/systemd/system
    mkdir -p $out/share/icons/hicolor/256x256/apps

    cp ${feilian-bin}/bin/feilian $out/bin/
    cp ${feilian-service-bin}/bin/feilian-service $out/bin/
    cp ${feilian-debug-bin}/bin/feilian-debug $out/bin/

    cp ${desktopItem}/share/applications/* $out/share/applications/
    cp ${systemdService} $out/lib/systemd/system/feilian.service
    cp ${feilian-unpacked}/opt/apps/com.volcengine.feilian/entries/icons/hicolor/256x256/apps/corplink.png $out/share/icons/hicolor/256x256/apps/
  '';

  meta = with lib; {
    description = "飞连客户端";
    platforms = [ "x86_64-linux" ];
  };
}
