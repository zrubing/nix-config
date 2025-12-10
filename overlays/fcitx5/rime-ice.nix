{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation (_: rec {
  pname = "rime-ice";
  version = "2025.12.08";

  src = fetchFromGitHub {
    owner = "iDvel";
    repo = "rime-ice";
    rev = version;
    # 获取正确的哈希值：
    # nix-prefetch-url https://github.com/iDvel/rime-ice/archive/refs/tags/2025.12.08.tar.gz
    # 然后将输出替换下面的 hash
    hash = "sha256-GyiOlTr1Nw2ANTE7/fdyrPQkvRFWOyal3oAcDvsqF5A=";
  };

  installPhase = ''
    mkdir -p $out/share/rime-data
    cp -r *  $out/share/rime-data
  '';

  meta = {
    description = "雾凇拼音，功能齐全，词库体验良好，长期更新修订";
    homepage = "https://github.com/iDvel/rime-ice";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.all;
    maintainers = with lib.maintainers; [ chen ];
  };
})
