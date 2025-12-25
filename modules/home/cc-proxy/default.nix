{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
let
  hm = config.lib;
  cfg = config.${namespace}.cc-proxy;
  mysecrets = inputs.mysecrets;
  # subagents = inputs.subagents;
  uid = toString 1000;
  username = config.snowfallorg.user.name;
in
{
  options.${namespace}.cc-proxy = with lib; {
    enable = mkEnableOption "Enable cc-proxy";
  };

  config = mkIf cfg.enable {
    ${namespace}.sops.enable = true;

    home.packages = with pkgs; [
      libnotify
    ];

    age.secrets."ccp-work-volcengine.kimi.env".file =
      "${mysecrets}/env/cc-proxy-work-volcengine.kimi.env.age";

    age.secrets."ccp-work-volcengine.deepseek.env".file =
      "${mysecrets}/env/cc-proxy-work-volcengine.deepseek.env.age";

    age.secrets."ccp-self-zhipu.glm.env".file = "${mysecrets}/env/cc-proxy-self-zhipu.glm.env.age";

    systemd.user.services."cc-work-volcengine-deepseek-proxy-@${uid}" = {
      Unit = {
        After = [ "agenix.service" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Environment = "XDG_RUNTIME_DIR=/run/user/%i";
        EnvironmentFile = "/run/user/%i/agenix/ccp-work-volcengine.deepseek.env";
        ExecStart = "${pkgs.${namespace}.claude-code-proxy}/bin/claude-code-proxy";
      };
    };

    systemd.user.services."cc-work-volcengine-kimi-proxy-@${uid}" = {
      Unit = {
        After = [ "agenix.service" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Environment = "XDG_RUNTIME_DIR=/run/user/%i";
        EnvironmentFile = "/run/user/%i/agenix/ccp-work-volcengine.kimi.env";
        ExecStart = "${pkgs.${namespace}.claude-code-proxy}/bin/claude-code-proxy";
      };
    };

    systemd.user.services."cc-self-zhipu-glm-proxy@${uid}" = {
      Unit = {
        After = [ "agenix.service" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Environment = "XDG_RUNTIME_DIR=/run/user/%i";
        EnvironmentFile = "/run/user/%i/agenix/ccp-self-zhipu.glm.env";
        ExecStart = "${pkgs.${namespace}.claude-code-proxy}/bin/claude-code-proxy";
      };
    };

  };
}
