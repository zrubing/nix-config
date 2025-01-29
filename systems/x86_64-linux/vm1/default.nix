{
  config,
  pkgs,
  lib,
  ...
}: {

  # 我用的一些内核参数
  boot.kernelParams = [
    # 关闭内核的操作审计功能
    "audit=0"
    # 不要根据 PCIe 地址生成网卡名（例如 enp1s0，对 VPS 没用），而是直接根据顺序生成（例如 eth0）
    "net.ifnames=0"
  ];

  # 我用的 Initrd 配置，开启 ZSTD 压缩和基于 systemd 的第一阶段启动
  boot.initrd = {
    compressor = "zstd";
    compressorArgs = ["-19" "-T0"];
    systemd.enable = true;
  };

  # 安装 Grub
  boot.loader.grub = {
    enable = !config.boot.isContainer;
    default = "saved";
    devices = ["/dev/vda"];
  };

  # 时区，根据你的所在地修改
  time.timeZone = "America/Los_Angeles";

  # Root 用户的密码和 SSH 密钥。如果网络配置有误，可以用此处的密码在控制台上登录进去手动调整网络配置。
  users.mutableUsers = false;
  users.users.root = {
    hashedPassword = "$6$9iybgF./X/RNsRrQ$h7Zlk//loJDPg7yCCPT/9jVU0Tvep6vEA1FvPBT.kqJUA5qlzhDJEYnBFlpBZmTXuUXjF0qgmDWmGkXIMC9JD/";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMcWoEQ4Mh27AV3ixcn9CMaUK/R+y4y5TqHmn2wJoN6i lantian@lantian-lenovo-archlinux"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCulLscvKjEeroKdPE207W10MbZ3+ZYzWn34EnVeIG0GzfZ3zkjQJVfXFahu97P68Tw++N6zIk7htGic9SouQuAH8+8kzTB8/55Yjwp7W3bmqL7heTmznRmKehtKg6RVgcpvFfciyxQXV/bzOkyO+xKdmEw+fs92JLUFjd/rbUfVnhJKmrfnohdvKBfgA27szHOzLlESeOJf3PuXV7BLge1B+cO8TJMJXv8iG8P5Uu8UCr857HnfDyrJS82K541Scph3j+NXFBcELb2JSZcWeNJRVacIH3RzgLvp5NuWPBCt6KET1CCJZLsrcajyonkA5TqNhzumIYtUimEnAPoH51hoUD1BaL4wh2DRxqCWOoXn0HMrRmwx65nvWae6+C/7l1rFkWLBir4ABQiKoUb/MrNvoXb+Qw/ZRo6hVCL5rvlvFd35UF0/9wNu1nzZRSs9os2WLBMt00A4qgaU2/ux7G6KApb7shz1TXxkN1k+/EKkxPj/sQuXNvO6Bfxww1xEWFywMNZ8nswpSq/4Ml6nniS2OpkZVM2SQV1q/VdLEKYPrObtp2NgneQ4lzHmAa5MGnUCckES+qOrXFZAcpI126nv1uDXqA2aytN6WHGfN50K05MZ+jA8OM9CWFWIcglnT+rr3l+TI/FLAjE13t6fMTYlBH0C8q+RnQDiIncNwyidQ== lantian@LandeMacBook-Pro.local"
    ];
  };

  # 使用 systemd-networkd 管理网络
  systemd.network.enable = true;
  services.resolved.enable = false;

  # 配置网络 IP 和 DNS
  # systemd.network.networks.eth0 = {
  #   address = ["123.45.678.90/24"];
  #   gateway = ["123.45.678.1"];
  #   matchConfig.Name = "eth0";
  # };
  networking.nameservers = [
    "8.8.8.8"
  ];

  # 开启 SSH 服务端，监听 2222 端口
  services.openssh = {
    enable = true;
    ports = [2222];
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = lib.mkForce "prohibit-password";
    };
  };

  # 关闭 NixOS 自带的防火墙
  networking.firewall.enable = false;

  # 关闭 DHCP，手动配置 IP
  # networking.useDHCP = false;

  # 主机名，随意设置即可
  networking.hostName = "bootstrap";

  # 首次安装系统时 NixOS 的最新版本，用于在大版本升级时避免发生向前不兼容的情况
  system.stateVersion = "24.11";

  # QEMU（KVM）虚拟机需要使用的内核模块
  boot.initrd.postDeviceCommands = lib.mkIf (!config.boot.initrd.systemd.enable) ''
    # Set the system time from the hardware clock to work around a
    # bug in qemu-kvm > 1.5.2 (where the VM clock is initialised
    # to the *boot time* of the host).
    hwclock -s
  '';

  boot.initrd.availableKernelModules = [
    "virtio_net"
    "virtio_pci"
    "virtio_mmio"
    "virtio_blk"
    "virtio_scsi"
  ];
  boot.initrd.kernelModules = [
    "virtio_balloon"
    "virtio_console"
    "virtio_rng"
  ];

}
