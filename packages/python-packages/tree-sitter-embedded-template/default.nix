{
  python312Packages,
  fetchPypi,
}:

python312Packages.buildPythonPackage rec {
  pname = "tree-sitter-embedded-template";
  version = "0.23.2";
  format = "wheel";
  src = fetchPypi {
    inherit version format;
    pname = "tree_sitter_embedded_template";
    hash = "sha256-vPoB9iuI1Q28tzbMI7rsjdv+CNqs/cYT7ujASrZe/Qk=";
    abi = "abi3";
    platform = "manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64";
    python = "cp39";
    dist = "cp39";

  };
  doCheck = false;

}
