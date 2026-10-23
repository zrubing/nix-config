{
  config,
  lib,
  namespace,
  ...
}:
{
  imports = [
    ./zen14.nix
    ./nova13.nix
  ];

  options.${namespace}.networking = with lib; {
    wifi.enable = mkEnableOption "Enable wifi";
  };

  config = {

    networking.firewall.enable = false;

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
        PermitRootLogin = "no"; # disable root login
        # PasswordAuthentication = false; # disable password login
      };
      openFirewall = true;
    };

    # 启用 systemd-resolved。
    # 上游 DNS 不在这里写死：它取决于当前用哪个代理，由 miho/sib/dae 三个模块
    # 各自声明（miho/sib 指向自己的 127.0.0.1:53；dae 指向外网地址，因为 dae
    # 不监听 :53，只能靠截获出网查询）。写死在这里既会和代理模块的声明打架，
    # 也会在没启用任何代理时留下一个没人监听的 127.0.0.1。
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNSSEC = false;
        FallbackDNS = [ "8.8.8.8" ];
      };
    };

    # 1. NM 只管连接，不管 DNS
    networking.networkmanager.enable = true;
    networking.networkmanager.dns = lib.mkForce "none";
    networking.dhcpcd.enable = false;

    # 2. wlp1s0 继续 DHCP 拿地址，但 DNS 不走 DHCP
    networking.useDHCP = false;
    networking.interfaces.wlp1s0.useDHCP = true;
  };
}
