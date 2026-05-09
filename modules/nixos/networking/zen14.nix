{
  config,
  lib,
  ...
}:
{
  # Do not put sops placeholders directly into networking.extraHosts.
  # /etc/hosts is generated at build/switch time and sops-nix placeholder
  # substitution only happens in sops.templates, not in arbitrary NixOS options.
  config = lib.mkIf (config.networking.hostName == "zen14") { };
}
