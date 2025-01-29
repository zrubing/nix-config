{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:
stdenvNoCC.mkDerivation (_: {
  pname = "rime-ice";
  version = "nightly";

  src = fetchFromGitHub {
    owner = "iDvel";
    repo = "rime-ice";
    rev = "2a2bb24367ba9948c840fec599710006dcb1e9ca";
    hash = "sha256-vB1dXAiFNMAGywq42Waiyhf7ctAM3Vp+/e5y1ntm++c=";
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
