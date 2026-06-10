{
  lib,
  fetchurl,
  appimageTools,
  makeWrapper,
}:

let
  pname = "multica-desktop";
  version = "0.3.19";

  src = fetchurl {
    url = "https://github.com/multica-ai/multica/releases/download/v${version}/multica-desktop-${version}-linux-x86_64.AppImage";
    hash = "sha512-k1s9UW6Zb20llIuopUwbf3D38OP1F+Nkgf3wGWwsXPwoQfhuiR89+VF3Rrf7YF20fN3tG4/3jZSC3apiHbQ6NA==";
  };

  appimageContents = appimageTools.extractType2 {
    inherit pname version src;
  };
in
appimageTools.wrapType2 {
  inherit pname version src;

  nativeBuildInputs = [ makeWrapper ];

  extraInstallCommands = ''
    desktop_file="$(find ${appimageContents} -name '*.desktop' | head -n1)"
    if [ -n "$desktop_file" ]; then
      install -Dm444 "$desktop_file" "$out/share/applications/${pname}.desktop"
      substituteInPlace "$out/share/applications/${pname}.desktop" \
        --replace-fail 'Exec=AppRun --no-sandbox %U' 'Exec=${pname} %U' \
        --replace-fail 'Icon=multica' 'Icon=${pname}'
    fi

    icon_file="$(find ${appimageContents} \( -name '.DirIcon' -o -name '*.png' -o -name '*.svg' \) | head -n1)"
    if [ -n "$icon_file" ]; then
      install -Dm444 "$icon_file" "$out/share/icons/hicolor/512x512/apps/${pname}.''${icon_file##*.}"
    fi

    wrapProgram "$out/bin/${pname}" \
      --add-flags "--no-sandbox"
  '';

  meta = with lib; {
    description = "Multica desktop AppImage package";
    homepage = "https://github.com/multica-ai/multica";
    license = licenses.unfree;
    mainProgram = pname;
    platforms = [ "x86_64-linux" ];
  };
}
