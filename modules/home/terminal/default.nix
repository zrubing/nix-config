{ lib, namespace, ... }: {
  options.${namespace}.terminal = with lib; mkOption { type = types.str; };
}
