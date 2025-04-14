{
  python312Packages,
  fetchPypi,
}:

python312Packages.buildPythonPackage rec {
  pname = "tree-sitter-yaml";
  version = "0.6.0";
  format = "wheel";
  src = fetchPypi {
    inherit version format;
    pname = "tree_sitter_yaml";
    hash = "sha256-QeoswoV5gsTiECAy+t8YbZyNW1Nwb1ljxUcCNOrDn8Q=";
    abi = "abi3";
    platform = "manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64";
    python = "cp38";
    dist = "cp38";

  };
  doCheck = false;

}
