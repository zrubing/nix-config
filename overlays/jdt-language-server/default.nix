{
  channels,
  inputs,
  lib,
  ...
}:
self: super: {
  jdt-language-server = super.jdt-language-server.overrideAttrs (old: rec {
    version = "1.47.0";
    timestamp = "202505151856";

    src = super.fetchurl {
      url = "https://download.eclipse.org/jdtls/milestones/${version}/jdt-language-server-${version}-${timestamp}.tar.gz";
      sha256 = "sha256-NUJCaUk2AWzUhjWWfLKM1LBzV3na/pYwdxOdKCPM2jo="; # 需要替换为实际hash
    };

    postPatch = ''
      # We store the plugins, config, and features folder in different locations
      # than in the original package. In addition, hard-code the path to the jdk
      # in the wrapper, instead of searching for it in PATH at runtime.
      substituteInPlace bin/jdtls.py \
        --replace-fail "jdtls_base_path = Path(__file__).parent.parent" "jdtls_base_path = Path(\"$out/share/java/jdtls/\")"
    '';

  });
}
