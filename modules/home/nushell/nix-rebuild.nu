def configurations [output: string] -> list<string> {
  do { nix eval $".#($output)" --apply builtins.attrNames --json }
  | complete
  | get stdout
  | from json
}

def "nu-complete nix rebuild" [] {
  [
    (configurations nixosConfigurations)
    (configurations darwinConfigurations)
    (configurations homeConfigurations)
  ] | flatten
}

def "rebuild nixos" [system: string, mode: string] {
  echo $"sudo nixos-rebuild switch --flake .#($system)"
  sudo nixos-rebuild $mode --flake $".#($system)"
}

def "rebuild darwin" [system: string, mode: string] {
  echo $"darwin-rebuild switch --flake .#($system)"
  darwin-rebuild $mode --flake $".#($system)"
}

def "rebuild home" [system: string, mode: string] {
  echo $"home-manager switch --flake .#($system)"
  home-manager $mode --flake $".#($system)"
}

def "nu-complete mode" [] {
  [switch boot build]
}

# Run nixos-rebuild switch, darwin-rebuild switch or home-manager switch for the current flake depending on the system.
export def "nix rebuild" [
  --mode: string@"nu-complete mode" = "switch"
  system?: string@"nu-complete nix rebuild"
  # If not set, default to $HOSTNAME or $USER@$HOSTNAME.
] {
  if not ("flake.nix" in (ls | get name)) {
    error make -u { msg: "could not find a flake.nix file in the current directory" }
  }

  if not ($system == null) {
    if ($system | str contains "@") {
      if $system in (configurations homeConfigurations) {
        rebuild home $system $mode
      } else {
        error make -u { msg: $"could not find home-manager configuration: ($system)" }
      }
    } else {
      if $system in (configurations nixosConfigurations) {
        rebuild nixos $system $mode
      } else if $system in (configurations darwinConfigurations) {
        rebuild darwin $system $mode
      } else {
        error make -u { msg: $"could not find system configuration: ($system)" }
      }
    }
  } else {
    let hostname = (sys host).hostname

    if $hostname in (configurations nixosConfigurations) {
      rebuild nixos $hostname $mode
    } else if $hostname in (configurations darwinConfigurations) {
      rebuild darwin $hostname $mode
    } else {
      let host = $"($env.USER)@($hostname)"

      if $host in (configurations homeConfigurations) {
        rebuild home $host $mode
      } else {
        error make -u { msg: $"no configuration found for the current system" }
      }
    }
  }
}
