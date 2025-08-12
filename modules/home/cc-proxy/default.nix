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
  cfg = config.${namespace}.cc-proxy;
  mysecrets = inputs.mysecrets;
  uid = toString 1000;
in
{
  options.${namespace}.cc-proxy = with lib; {
    enable = mkEnableOption "Enable cc-proxy";
  };

  config = mkIf cfg.enable {

    age.secrets."ccp-self-bailian.kimi-qwen3.env".file =
      "${mysecrets}/env/cc-proxy-self-bailian.kimi-qwen3.env.age";

    age.secrets."ccp-work-volcengine.kimi.env".file =
      "${mysecrets}/env/cc-proxy-work-volcengine.kimi.env.age";

    age.secrets."ccp-self-zhipu.glm.env".file = "${mysecrets}/env/cc-proxy-self-zhipu.glm.env.age";

    systemd.user.services."cc-proxy@${uid}" = {
      Unit = {
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Environment = "XDG_RUNTIME_DIR=/run/user/%i";
        EnvironmentFile = "/run/user/%i/agenix/ccp-self-bailian.kimi-qwen3.env";
        ExecStart = "${pkgs.${namespace}.claude-code-proxy}/bin/claude-code-proxy";
      };
    };

    systemd.user.services."cc-zhipu-proxy@${uid}" = {
      Unit = {
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
