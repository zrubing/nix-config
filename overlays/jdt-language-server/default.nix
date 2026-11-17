{ ... }:
self: super:
let
  version = "1.63.0";
  timestamp = "202610191322";
in
{
  # eclipse.jdt.ls 发布节奏快于 nixpkgs（26.05 是 1.58.0），这里只钉版本。
  # 构建逻辑沿用 nixpkgs：postPatch 已把 jdtls.py 的 base path 和 java 可执行
  # 文件写死，installPhase 负责 plugins/features/config_linux 布局；JDK 走
  # jdk 参数换成 jdk25，不需要在 overlay 里再 wrapProgram 一遍。
  jdt-language-server = (super.jdt-language-server.override { jdk = super.jdk25; }).overrideAttrs (_: {
    inherit version;
    src = super.fetchurl {
      url = "https://download.eclipse.org/jdtls/milestones/${version}/jdt-language-server-${version}-${timestamp}.tar.gz";
      hash = "sha256-sfKr4LPMy0Ys9k+0pVh8fQnfYM+L53SLFSy9idAYvcQ=";
    };
  });
}
