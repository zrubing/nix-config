{
  config,
  pkgs,
  inputs,
  system,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system; # for agenix pkg
  username = config.snowfallorg.user.name;
  mysecrets = inputs.mysecrets;
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };
  mystuff = pkgs.writeShellScriptBin "echo-secret" ''
    ${pkgs.coreutils}/bin/cat ${config.age.secrets.authinfo.path} > /home/${username}/.authinfo
    ${pkgs.coreutils}/bin/chmod 0600 /home/${username}/.authinfo
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/rclone
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."rclone.conf".path} > /home/${username}/.config/rclone/rclone.conf
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/topsap
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."topsap/env.ini".path} > /home/${username}/.config/topsap/env.ini

    ${pkgs.coreutils}/bin/cat ${config.age.secrets.netrc.path} > /home/${username}/.netrc

    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.kube

    # ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/milvzn.kube".path} > /home/${username}/.kube/config
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/sinopec.milv.kube".path} > /home/${username}/.kube/config

    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.claude
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."claude.settings.json".path} > /home/${username}/.claude/settings.json


    conf=$HOME/.claude.json

    # 1. 如果主配置不存在，先写一个空对象进去
    [[ -f $conf ]] || echo '{}' > "$conf"

    # 使用jq将claude.settings.json中的mcpServers合并到~/.claude.json

    ${pkgs.jq}/bin/jq \
      --arg chrome "${pkgs-unstable.google-chrome}/bin/google-chrome-stable" \
      '.mcpServers["chrome-devtools"].args[2] = $chrome' \
      /home/${username}/.claude/settings.json > /tmp/settings.json && \
    ${pkgs.jq}/bin/jq --slurpfile mcp /tmp/settings.json \
      '.mcpServers = ((.mcpServers // {}) * ($mcp[0].mcpServers // {}))' \
      /home/${username}/.claude.json > /tmp/.claude.json.tmp && \
    ${pkgs.coreutils}/bin/mv /tmp/.claude.json.tmp /home/${username}/.claude.json

    # 将 MCP 配置也替换到 ECA 配置中
    eca_config="$HOME/.config/eca/config.json"
    claude_config="$HOME/.claude.json"
    
    # 如果 ECA 配置不存在，创建一个基础配置
    if [[ ! -f "$eca_config" ]]; then
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/eca"
      echo '{}' > "$eca_config"
    fi
    
    # 如果 Claude 配置存在且包含 MCP 服务器配置，则完全替换到 ECA 配置
    if [[ -f "$claude_config" ]]; then
      ${pkgs.jq}/bin/jq --slurpfile claude "$claude_config" \
        '.mcpServers = ($claude[0].mcpServers // {})' \
        "$eca_config" > "$eca_config.tmp" && \
      ${pkgs.coreutils}/bin/mv "$eca_config.tmp" "$eca_config"
    fi
    
    echo "ECA configuration updated with MCP servers from Claude configuration (full replacement)"

  '';
in
{

  config = {

    age.identityPaths = [ "/home/${username}/.ssh/id_ed25519" ];
    age.secrets.authinfo.file = "${mysecrets}/authinfo.age";
    age.secrets."rclone.conf".file = "${mysecrets}/rclone.conf.age";
    age.secrets."topsap/env.ini".file = "${mysecrets}/topsap/env.ini.age";
    age.secrets."ssh/topsap-config".file = "${mysecrets}/ssh/topsap-config.age";
    age.secrets."ssh/work-config".file = "${mysecrets}/ssh/work-config.age";
    age.secrets."ssh/default-config".file = "${mysecrets}/ssh/default-config.age";

    age.secrets.netrc.file = "${mysecrets}/netrc.age";
    age.secrets."work/k8s/milvzn.kube".file = "${mysecrets}/work/k8s/milvzn.kube.age";
    age.secrets."work/k8s/sinopec.milv.kube".file = "${mysecrets}/work/k8s/sinopec.milv.kube.age";

    age.secrets."claude.settings.json".file = "${mysecrets}/claude.settings.json.age";

    home.packages = [
      #inputs.agenix.packages.${system}.agenix
      mystuff # so now in the terminal running `echo-secret` runs the above command
    ];

    systemd.user.services."agenix-echo-secret" = {
      Unit = {
        Description = "agenix in home";
        After = [ "agenix.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${mystuff}/bin/echo-secret";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

}
