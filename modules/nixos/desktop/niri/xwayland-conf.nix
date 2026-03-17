{ ... }:
{
  # --------------------------
  # 多屏 HiDPI 环境变量（mixed DPI workaround）
  # --------------------------
  environment.variables = {
    # 全局光标大小（与 xwayland-conf 的 cursorSize 保持一致）
    XCURSOR_SIZE = "32";

    # ── X11 Toolkit 缩放 ──
    # GDK_SCALE 只对 X11 GTK 应用生效（Wayland GTK 应用会自动处理）
    # 设为 1 让 Xft.dpi 来控制字体大小，避免双重缩放
    # GDK_SCALE = "1";

    # Qt X11 应用：禁用自动检测，让 Xft.dpi 来控制
    QT_AUTO_SCREEN_SCALE_FACTOR = "0";

    # Java X11 应用（如 DBeaver / JetBrains）：
    # GDK_SCALE 对 Java 无效，需要通过 _JAVA_OPTIONS 或应用参数设置
    # 见各应用的 .desktop 文件或 wrapper
  };

}
