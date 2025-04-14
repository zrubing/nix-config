{
  python312Packages,
  fetchPypi,
}:

python312Packages.buildPythonPackage rec {
  pname = "grep-ast";
  version = "0.8.1";
  format = "wheel";
  src = fetchPypi {
    inherit version format;
    pname = "grep_ast";
    hash = "sha256-IWVSB4u5xw5DveDFYQzqG43NyEmEH4X1432BDZi3Cts=";
    abi = "none";
    platform = "any";
    python = "py3";
    dist = "py3";

  };
  doCheck = false;

}
