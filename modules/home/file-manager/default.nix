{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.fileManager;

  # Yazi 没有 desktop entry，为其创建一个，这样 MIME 关联和 fuzzel 启动器都能找到它
  yaziDesktop = pkgs.makeDesktopItem {
    name = "yazi";
    desktopName = "Yazi";
    exec = "${lib.getExe pkgs.foot} -e ${lib.getExe pkgs.yazi} %U";
    mimeTypes = [ "inode/directory" ];
    terminal = false;
    categories = [ "System" "FileManager" ];
  };
in
{
  options.${namespace}.fileManager = {
    program = lib.mkOption {
      type = lib.types.enum [ "thunar" "yazi" ];
      default = "thunar";
      description = "默认文件管理器。切换后自动处理 MIME 关联、D-Bus 注册和 portal 路由。";
    };
  };

  config = lib.mkMerge [
    {
      # 暴露给 niri 快捷键等模块引用的可执行路径
      home.sessionVariables.FM_EXE = if cfg.program == "thunar" then
        "${lib.getExe pkgs.thunar}"
      else
        "${lib.getExe pkgs.foot} -e ${lib.getExe pkgs.yazi}";
    }

    (lib.mkIf (cfg.program == "thunar") {
      xdg.mimeApps.defaultApplications."inode/directory" = "thunar.desktop";
      # Thunar 的 org.freedesktop.FileManager1 D-Bus 服务由系统级
      # programs.thunar.enable 提供（包自带 org.xfce.Thunar.FileManager1.service，
      # Name=org.freedesktop.FileManager1，含 SystemdService=thunar.service）。
      # 这里不再重复写用户级服务文件，避免覆盖自带的标准注册。
    })

    (lib.mkIf (cfg.program == "yazi") {
      home.packages = [ yaziDesktop ];
      xdg.mimeApps.defaultApplications."inode/directory" = "yazi.desktop";
    })
  ];
}
