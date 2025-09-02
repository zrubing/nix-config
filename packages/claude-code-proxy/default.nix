{
  lib,
  fetchFromGitHub,
  uv,
  python3,
  python3Packages,
}:

python3Packages.buildPythonApplication rec {
  pname = "claude-code-proxy";
  version = "notset";
  pyproject = true; # 告诉 Nix 使用 pyproject.toml

  src = fetchFromGitHub {
    owner = "fuergaosi233";
    repo = "claude-code-proxy";
    rev = "main"; # 可换成具体 commit
    hash = "sha256-qZtiGONKGyCszWKNsGcT7JEjDIH1zRKnmXMqav5439o="; # nix-prefetch-url 生成
  };
  build-system = [ python3Packages.hatchling ];

  nativeBuildInputs = [ uv ];

  dependencies = with python3Packages; [
    openai

  ];

  propagatedBuildInputs = with python3.pkgs; [
    fastapi
    httpx
    uvicorn
    pydantic
    python-dotenv
  ];

  # installPhase = ''
  #   runHook preInstall
  #   uv pip install --prefix=$out dist/*.whl
  #   runHook postInstall
  # '';

  meta = with lib; {
    description = "Claude Code to OpenAI API proxy";
    homepage = "https://github.com/fuergaosi233/claude-code-proxy";
    license = licenses.mit;
    maintainers = [ ];
  };
}
