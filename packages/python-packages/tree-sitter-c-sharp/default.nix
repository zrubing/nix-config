{
  python312Packages,
  fetchPypi,
}:
python312Packages.buildPythonPackage rec {
  pname = "tree-sitter-c-sharp";
  version = "0.23.1";
  format = "wheel";
  src = fetchPypi {
    inherit version format;
    pname = "tree_sitter_c_sharp";
    hash = "sha256-qAJORmsvVhHG3JAyHyMthYSJPH+4i3XkqDGZL4d2FtI=";
    abi = "abi3";
    platform = "manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64";
    python = "cp39";
    dist = "cp39";

  };
  doCheck = false;

}
