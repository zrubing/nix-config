{
  python312Packages,
  fetchPypi,
}:

python312Packages.buildPythonPackage rec {
  pname = "tree-sitter-language-pack";
  version = "0.6.1";
  format = "wheel";
  src = fetchPypi {
    inherit version;
    format = "wheel";
    pname = "tree_sitter_language_pack";
    hash = "sha256-JA8JMO8dtoYAksgXSBOb9Rkvjt38wOqKXm9WjLi7cOY=";
    abi = "abi3";
    platform = "manylinux2014_x86_64";
    python = "cp39";
    dist = "cp39";

  };
  doCheck = false;

}
