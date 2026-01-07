{
  python3,
}:

python3.pkgs.buildPythonApplication {
  pname = "claude-md";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = with python3.pkgs; [
    hatchling
  ];

  meta = {
    description = "CLI tool to manage CLAUDE.local.md files across repositories";
    mainProgram = "claude-md";
  };
}
