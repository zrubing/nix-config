{ lib, namespace, ... }:
{
  options.${namespace}.shell = with lib; {
    enable = mkOption {
      type = types.enum [ "bash" "fish" ];
      default = "bash";
      description = "Default shell to use";
    };
    provider = lib.mkOption {
      type = lib.types.enum [ "GLM" "MiniMax" "Qwen" "Volc" ];
      default = "glm";
      description = "AI provider to use (GLM, MiniMax, Qwen, or Volc)";
    };
  };
}
