# 飞连客户端包定义
{ config, pkgs, ... }:

pkgs.stdenv.mkDerivation rec {
  pname = "feilian";
  version = "3.1.18";

  # 直接从URL下载deb包
  src = pkgs.fetchurl {
    url = "https://cdn.isealsuite.com/linux/FeiLian_Linux_amd64_v3.1.18_r6560_8a2fab.deb";
    sha256 = "1nzvwcxmwl072w4sik2ivfydi4hdwg6dbv74qm7j2434s98sdmqa";
  };

  nativeBuildInputs = [ pkgs.dpkg ];

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    # 复制所有文件到输出目录
    cp -r . $out
    
    # 确保二进制文件可执行
    find $out -type f -name "*" -exec chmod +x {} \; 2>/dev/null || true
  '';

  meta = with pkgs.lib; {
    description = "飞连客户端";
    homepage = "https://isealsuite.com/";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
}
