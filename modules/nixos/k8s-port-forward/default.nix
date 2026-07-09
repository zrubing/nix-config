{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.k8s-port-forward;
  mysecrets = inputs.mysecrets;
in
{
  options.${namespace}.k8s-port-forward = {
    enable = lib.mkEnableOption "declarative kubectl port-forward rules stored in SOPS secrets";

    user = lib.mkOption {
      type = lib.types.str;
      default = "jojo";
      description = "System user that runs kubectl (must have valid kubeconfig in home).";
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      default = "k8s_port_forward/commands";
      description = "SOPS secret key in env.yaml containing one kubectl port-forward command per line.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = "${mysecrets}/secrets/env.yaml";
      defaultText = lib.literalExpression ''"''${inputs.mysecrets}/secrets/env.yaml"'';
      description = "Path to the SOPS-encrypted YAML file.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.secretName} = {
      sopsFile = cfg.sopsFile;
    };

    # Template: decrypt the command list at runtime
    sops.templates."k8s-port-forward-commands" = {
      owner = cfg.user;
      group = "users";
      mode = "0400";
      content = config.sops.placeholder.${cfg.secretName};
    };

    systemd.services.k8s-port-forwards = {
      description = "K8s port-forward rules (from SOPS)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "run-secrets.d.mount"
      ];
      requires = [ "run-secrets.d.mount" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = "users";
        Restart = "always";
        RestartSec = 10;
        SuccessExitStatus = [ 0 1 ];
      };

      path = with pkgs; [ kubectl bash coreutils ];

      script =
        let
          runner = pkgs.writeShellScript "k8s-port-forward-runner" ''
            set -euo pipefail

            CMD_FILE="${config.sops.templates."k8s-port-forward-commands".path}"

            if [ ! -f "$CMD_FILE" ]; then
              echo "ERROR: command file not found: $CMD_FILE" >&2
              exit 1
            fi

            echo "=== k8s-port-forward starting ==="

            pids=()
            while IFS= read -r line; do
              # strip inline comments and trim
              line="''${line%%#*}"
              line="''${line//$'\r'/}"
              line="''${line#"''${line%%[![:space:]]*}"}"
              line="''${line%"''${line##*[![:space:]]}"}"

              if [ -z "$line" ]; then
                continue
              fi

              echo "→ launching: $line"
              eval "$line" &
              pids+=($!)
            done < "$CMD_FILE"

            if [ ''${#pids[@]} -eq 0 ]; then
              echo "WARNING: no commands found in $CMD_FILE" >&2
              exit 1
            fi

            echo "→ all ''${#pids[@]} forwards launched, waiting..."

            # Wait for first child to exit → restart everything
            wait -n 2>/dev/null || true
            echo "→ a forward exited, restarting all..." >&2
            for pid in "''${pids[@]}"; do
              kill "$pid" 2>/dev/null || true
            done
            wait 2>/dev/null || true
            exit 1
          '';
        in
        "${runner}";
    };
  };
}
