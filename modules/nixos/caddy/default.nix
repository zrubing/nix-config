{ config, inputs, lib, pkgs, ... }:
let
  cfgFile = config.age.secrets.caddy-conf.path;
  mysecrets = inputs.mysecrets;
  hostName = config.networking.hostName;
in
{

  age.secrets.caddy-conf = {
    file = lib.mkDefault "${mysecrets}/caddy-conf-${hostName}.age";
    owner = "caddy";
    group = "users";
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [
        "github.com/mholt/caddy-l4@v0.1.0"
      ];
      hash = "sha256-+XzV0RM43oqK4thXsJhDPA0uc2oTONG8T2RfccYzzi0=";
    };
    configFile = cfgFile;
  };

  # agenix 更新 caddy-conf 内容时路径不变，NixOS 的 reloadTriggers 感知不到
  # （它只比较声明路径），导致改 Caddy 配置后不会自动 reload。加 --watch 让
  # Caddy 原生监听配置文件变化自动重载。
  systemd.services.caddy.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${pkgs.caddy}/bin/caddy run --config /etc/caddy/caddy_config --adapter caddyfile --watch"
  ];
}
