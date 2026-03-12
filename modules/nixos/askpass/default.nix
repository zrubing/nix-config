{ config, lib, pkgs, namespace, ... }:

let
  cfg = config.${namespace}.askpass;
  
  # 创建一个使用 pinentry-gnome3 的 askpass 脚本
  askpassScript = pkgs.writeShellScriptBin "sudo-askpass" ''
    # SUDO_ASKPASS 需要输出密码到 stdout
    # 使用 pinentry-gnome3 获取密码
    
    # 设置 GUI 显示环境变量
    export DISPLAY="''${DISPLAY:-:0}"
    export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-}"
    export XAUTHORITY="''${XAUTHORITY:-$HOME/.Xauthority}"
    
    # 使用 pinentry-gnome3 获取密码
    # pinentry 协议：发送命令，接收响应
    ${pkgs.pinentry-gnome3}/bin/pinentry <<EOF | ${pkgs.gawk}/bin/awk '/^D / {print substr($0, 3)}'
SETDESC sudo 密码验证
SETPROMPT 密码:
GETPIN
EOF
  '';
in
{
  options.${namespace}.askpass = with lib; {
    enable = mkEnableOption "sudo askpass with pinentry GUI";
  };

  config = lib.mkIf cfg.enable {
    # 安装 askpass 脚本到系统
    environment.systemPackages = [ askpassScript ];
    
    # 设置全局环境变量
    environment.sessionVariables = {
      SUDO_ASKPASS = "/run/current-system/sw/bin/sudo-askpass";
    };
  };
}
