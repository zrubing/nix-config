{
  config,
  pkgs,
  inputs,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  home = config.home.homeDirectory;
  M = "0600"; # 这些全是凭据，统一 0600

  # 把 age secret 稳定地暴露到某个 app 硬编码的 dotfile 路径上。
  # symlink 默认 true → 明文只在 $XDG_RUNTIME_DIR，<path> 是个软链接。
  place = file: target: mode: {
    file = file;
    path = "${home}${target}";
    mode = mode;
  };

  # app 硬编码路径 → 声明式放置，不再拷贝
  placed = {
    "authinfo"                  = place "${mysecrets}/authinfo.age"                 "/.authinfo"                    M;
    "rclone.conf"               = place "${mysecrets}/rclone.conf.age"              "/.config/rclone/rclone.conf"   M;
    "topsap/env.ini"            = place "${mysecrets}/topsap/env.ini.age"           "/.config/topsap/env.ini"       M;
    "netrc"                     = place "${mysecrets}/netrc.age"                    "/.netrc"                       M;
    "work/k8s/milvzn.kube"      = place "${mysecrets}/work/k8s/milvzn.kube.age"     "/.kube/config-milv-default.yml" M;
    "work/k8s/sinopec.milv.kube" = place "${mysecrets}/work/k8s/milvzn.sinopec.kube.age" "/.kube/config-milv-sinopec.yml" M;
    "work/k8s/k0s.kube"         = place "${mysecrets}/work/k8s/k0s.kube.age"        "/.kube/config-k0s.yml"         M;
    "codex/auth.json"           = place "${mysecrets}/codex/auth.json.age"          "/.codex/auth.json"             M;
    "ccr.config.json"           = place "${mysecrets}/ccr.config.age"               "/.claude-code-router/config.json" M;
    "agents/pi/auth.json"       = place "${mysecrets}/agents/pi/auth.json.age"      "/.pi/agent/auth.json"          M;
  };

  # 其余 secret 仍走默认 tmpfs 路径，交给别的模块消费（ssh、claude-code），
  # 以及必须「合并」而非直接拷贝的 pi models.json
  plain = {
    "ssh/topsap-config".file = "${mysecrets}/ssh/topsap-config.age";
    "ssh/work-config".file = "${mysecrets}/ssh/work-config.age";
    "ssh/default-config".file = "${mysecrets}/ssh/default-config.age";
    "claude.settings.json".file = "${mysecrets}/claude.settings.json.age";
    "agents/pi/models.json".file = "${mysecrets}/agents/pi/models.json.age";
  };

  # pi/models.json 是「age 密钥 ⊕ 明文 overlay」的合并，不是简单拷贝，
  # 这是唯一真正需要一步生成的 case，保留一个最小的生成 unit。
  piModels = pkgs.writeShellScriptBin "agenix-pi-models" ''
    set -euo pipefail
    secret=${config.age.secrets."agents/pi/models.json".path}
    overlay=${home}/.config/pi/models-overlay.json
    out=${home}/.pi/agent/models.json
    mkdir -p "$(dirname "$out")"
    if [ -f "$overlay" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$secret" "$overlay" > "$out"
    else
      ${pkgs.coreutils}/bin/cp -- "$secret" "$out"
    fi
    chmod 0600 "$out"
  '';
in
{
  config = {
    age.identityPaths = [ "${home}/.ssh/id_ed25519" ];
    age.secrets = placed // plain;

    home.packages = [ piModels ];

    systemd.user.services."agenix-pi-models" = {
      Unit = {
        Description = "merge agenix pi models into ~/.pi/agent/models.json";
        Requires = [ "agenix.service" ];
        After = [ "agenix.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${piModels}/bin/agenix-pi-models";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
