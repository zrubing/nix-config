{ stdenv, lib, jq, fuzzel, niri, curl }:

stdenv.mkDerivation {
  pname = "niri-fuzzel-switcher";
  version = "1.0.0";

  src = ./niri_fuzzel_switcher;

  nativeBuildInputs = [ ];
  
  buildInputs = [ jq fuzzel curl ];
  
  dontUnpack = true;
  
  installPhase = ''
    install -Dm755 $src $out/bin/niri-fuzzel-switcher
    install -Dm755 ${./brave-tab-switcher-v2} $out/bin/brave-tab-switcher-v2
    install -Dm755 ${./niri-fuzzel-switcher-v3} $out/bin/niri-fuzzel-switcher-v3
    
    substituteInPlace $out/bin/niri-fuzzel-switcher \
      --replace "jq" "${lib.getBin jq}/bin/jq" \
      --replace "fuzzel" "${lib.getBin fuzzel}/bin/fuzzel" \
      --replace "niri" "${lib.getBin niri}/bin/niri"
      
    substituteInPlace $out/bin/brave-tab-switcher-v2 \
      --replace "jq" "${lib.getBin jq}/bin/jq" \
      --replace "fuzzel" "${lib.getBin fuzzel}/bin/fuzzel" \
      --replace "niri" "${lib.getBin niri}/bin/niri" \
      --replace "curl" "${lib.getBin curl}/bin/curl"
      
    substituteInPlace $out/bin/niri-fuzzel-switcher-v3 \
      --replace "jq" "${lib.getBin jq}/bin/jq" \
      --replace "fuzzel" "${lib.getBin fuzzel}/bin/fuzzel" \
      --replace "niri" "${lib.getBin niri}/bin/niri" \
      --replace "curl" "${lib.getBin curl}/bin/curl"
  '';

  meta = with lib; {
    description = "Fuzzel-based window and tab switcher for niri window manager with browser tab support";
    homepage = "https://github.com/armerpunkt/niri-fuzzel-switcher";
    license = licenses.unlicense;
    maintainers = with maintainers; [ ];
    platforms = platforms.linux;
  };
}
