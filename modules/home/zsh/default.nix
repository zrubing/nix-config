{
  config,
  lib,
  pkgs,
  ...
}:
let
  overrides = (builtins.fromTOML (builtins.readFile ./rust-toolchain.toml));
  RUSTC_VERSION = overrides.toolchain.channel;
in
{

  home.packages = with pkgs; [

    oh-my-zsh
  ];

  programs.zsh = {
    enable = true;

    zplug = {
      enable = true;
      plugins = [
        { name = "zsh-users/zsh-autosuggestions"; } # Simple plugin installation
        { name = "joshskidmore/zsh-fzf-history-search"; }

      ];
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "pass"
        "zoxide"
        "spring"
        "docker"
        "docker-compose"
        "dotenv"
        "history-substring-search"
      ];
      theme = "robbyrussell";
    };

    #autosuggestion.enable = true;
    autocd = true;
    dirHashes = {
      dl = "$HOME/Downloads";
      docs = "$HOME/Documents";
      code = "$HOME/Documents/code";
      dots = "$HOME/Documents/code/dotfiles";
      pics = "$HOME/Pictures";
      vids = "$HOME/Videos";
      nixpkgs = "$HOME/Documents/code/git/nixpkgs";
    };
    dotDir = ".config/zsh";
    history = {
      expireDuplicatesFirst = true;
      path = "${config.xdg.dataHome}/zsh_history";
    };

    initExtra = ''
      # search history based on what's typed in the prompt
      autoload -U history-search-end
      zle -N history-beginning-search-backward-end history-search-end
      zle -N history-beginning-search-forward-end history-search-end
      bindkey "^[OA" history-beginning-search-backward-end
      bindkey "^[OB" history-beginning-search-forward-end

      # C-right / C-left for word skips
      bindkey "^[[1;5C" forward-word
      bindkey "^[[1;5D" backward-word

      # C-Backspace / C-Delete for word deletions
      bindkey "^[[3;5~" forward-kill-word
      bindkey "^H" backward-kill-word

      # Home/End
      bindkey "^[[OH" beginning-of-line
      bindkey "^[[OF" end-of-line


      # history search substring
      bindkey '^[[A' history-substring-search-up
      bindkey '^[[B' history-substring-search-down

      # open commands in $EDITOR with C-e
      # autoload -z edit-command-line
      # zle -N edit-command-line
      # bindkey "^e" edit-command-line

      # case insensitive tab completion
      zstyle ':completion:*' completer _complete _ignored _approximate
      zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
      zstyle ':completion:*' menu select
      zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
      zstyle ':completion:*' verbose true

      # use cache for completions
      zstyle ':completion:*' use-cache on
      zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/.zcompcache"
      _comp_options+=(globdots)

      # Allow foot to pipe command output
      function precmd {
      if ! builtin zle; then
      print -n "\e]133;D\e\\"
      fi
      }

      function preexec {
      print -n "\e]133;C\e\\"
      }

      alias urlencode='python3 -c "import sys, urllib.parse as ul; \
          print (ul.quote_plus(sys.argv[1]))"'

      export PATH=$PATH:''${CARGO_HOME:-~/.cargo}/bin
      export PATH=$PATH:''${RUSTUP_HOME:-~/.rustup}/toolchains/$RUSTC_VERSION-x86_64-unknown-linux-gnu/bin

    '';

    shellAliases = {
      g = "git";
      grep = "grep --color";
      ip = "ip --color";
      l = "eza -l";
      la = "eza -la";
      md = "mkdir -p";
      ppc = "powerprofilesctl";
      pf = "powerprofilesctl launch -p performance";

      restore-roam = "echo \"restic -r rclone:ali:org-roam-backup restore latest --target ~/org-roam-dir \"";
      restore-pass = "echo \"restic -r rclone:ali:password-store restore latest --target ~/.local/share/password-store \"";

      us = "systemctl --user"; # mnemonic for user systemctl
      rs = "sudo systemctl"; # mnemonic for root systemctl
    } // lib.optionalAttrs config.programs.bat.enable { cat = "bat"; };
    shellGlobalAliases = {
      eza = "eza --icons --git";
    };
  };
}
