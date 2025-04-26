{ ... }:
{
  # --------------------------
  # 高分辨率环境变量
  # --------------------------
  environment.variables = {
    # 全局光标大小
    XCURSOR_SIZE = "32";

    # GTK/Qt 缩放（覆盖应用级设置）
    # 使用xwayland xrdb merge xresource，暂时不用下面的gdk设置
    # GDK_SCALE = "2";
    # GDK_DPI_SCALE = "0.75"; # 防止字体过大
    # QT_SCALE_FACTOR = "0.75";
    # QT_AUTO_SCREEN_SCALE_FACTOR = "0"; # 禁用自动检测
  };

}
