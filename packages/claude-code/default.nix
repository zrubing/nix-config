{
  lib,
  pkgs,
  writeShellApplication,
  inputs,
}:

let
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
in
writeShellApplication {
  name = "claude";
  runtimeInputs = [
    claude-code
    pkgs.bashInteractive
  ];
  text = ''
    set -euo pipefail

    # Set shell to bash for Claude Code
    export SHELL=${pkgs.bashInteractive}/bin/bash

    # Add ~/.local/bin to PATH for user scripts to shut-up claude warnings
    export PATH="$HOME/.local/bin:$PATH"

    # Run the actual claude command
    exec claude "$@"
  '';
}
