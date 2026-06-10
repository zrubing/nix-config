{
  lib,
  python312Packages,
  fetchFromGitHub,
  fetchPypi,
}:

let
  backtrader = python312Packages.buildPythonPackage rec {
    pname = "backtrader";
    version = "1.9.78.123";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      python = "py2.py3";
      dist = "py2.py3";
      hash = "sha256-mgelFrDekVVTmjXFbpQE2HEd1wILPTezBJXoPhudXf0=";
    };

    doCheck = false;
  };

  stockstats = python312Packages.buildPythonPackage rec {
    pname = "stockstats";
    version = "0.6.8";
    pyproject = true;

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-X3RiFip8xHJ5p3yOAVwFBKqv2INemdGhSCJC5NNobFE=";
    };

    build-system = with python312Packages; [
      setuptools
      setuptools-scm
    ];

    dependencies = with python312Packages; [ pandas ];

    doCheck = false;
  };
in
python312Packages.buildPythonApplication rec {
  pname = "tradingagents";
  version = "0.2.5";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "tauricresearch";
    repo = "tradingagents";
    rev = "04f434e86db88e7707bf16db8ed7183f9764fe26";
    hash = "sha256-9Feu+Xw5yp1TkAsoN/2bndryki7bFTQWRHQKPX3GMQU=";
  };

  build-system = with python312Packages; [ setuptools ];

  dependencies = with python312Packages; [
    backtrader
    langchain-core
    langchain-anthropic
    langchain-experimental
    langchain-google-genai
    langchain-openai
    langgraph
    langgraph-checkpoint-sqlite
    pandas
    parsel
    python-dotenv
    pytz
    questionary
    redis
    requests
    rich
    setuptools
    stockstats
    tqdm
    typer
    typing-extensions
    yfinance
  ];

  pythonRelaxDeps = true;

  pythonImportsCheck = [
    "cli.main"
    "tradingagents"
  ];

  meta = {
    description = "Multi-agent LLM financial trading framework";
    homepage = "https://github.com/tauricresearch/tradingagents";
    license = lib.licenses.asl20;
    mainProgram = "tradingagents";
  };
}
