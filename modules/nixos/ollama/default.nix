{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  system,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  cfg = config.${namespace}.ollama;
in
{

  options.${namespace}.ollama = with lib; {
    enable = mkEnableOption "Enable ollama";
  };

  config = lib.mkIf cfg.enable {

    services.ollama = {
      enable = true;
      package = pkgs.unstable.ollama-vulkan;
      acceleration = "vulkan";
    };
  };

}
