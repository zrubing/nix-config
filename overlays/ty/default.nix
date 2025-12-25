{
  # Channels are named after NixPkgs instances in your flake inputs. For example,
  # with .input `nixpkgs` there will be a channel available at `channels.nixpkgs`.
  # These channels are system-specific instances of NixPkgs that can be used to quickly
  # pull packages into your overlay.
  channels,
  lib,
  ... }:

final: prev: {
  ty = final.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "ty";
    version = "0.0.5";

    src = final.fetchFromGitHub {
      owner = "astral-sh";
      repo = "ty";
      tag = finalAttrs.version;
      fetchSubmodules = true;
      hash = "sha256-G9sVPg1fe35CNYJlRO/1zm3gOY78qfmU/RwKw2iG7o8=";
    };

    # For Darwin platforms, remove the integration test for file notifications,
    # as these tests fail in its sandboxes.
    postPatch = lib.optionalString final.stdenv.hostPlatform.isDarwin ''
      rm ${finalAttrs.cargoRoot}/crates/ty/tests/file_watching.rs
    '';

    cargoRoot = "ruff";
    buildAndTestSubdir = finalAttrs.cargoRoot;

    cargoBuildFlags = [ "--package=ty" ];

    # 临时设置，需要实际构建获取正确的hash
    cargoHash = "sha256-NyNXR1PGds+GXAha9u4DglUyy7T+yqLjNpGnchYn6oc=";

    nativeBuildInputs = [ final.installShellFiles ];

    # `ty`'s tests use `insta-cmd`, which depends on the structure of the `target/` directory,
    # and also fails to find the environment variable `$CARGO_BIN_EXE_ty`, which leads to tests failing.
    # Instead, we specify the path ourselves and forgo the lookup.
    # As the patches occur solely in test code, they have no effect on the packaged `ty` binary itself.
    #
    # `stdenv.hostPlatform.rust.cargoShortTarget` is taken from `cargoSetupHook`'s `installPhase`,
    # which constructs a path as below to reference the built binary.
    preCheck = ''
      export CARGO_BIN_EXE_ty="$PWD"/target/${final.stdenv.hostPlatform.rust.cargoShortTarget}/release/ty
    '';

    cargoTestFlags = [
      "--package=ty" # CLI tests; file-watching tests only on Linux platforms
      "--package=ty_python_semantic" # core type checking tests
      "--package=ty_test" # test framework tests
    ];

    checkFlags = [
      # Flaky:
      # called `Result::unwrap()` on an `Err` value: Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }
      "--skip=python_environment::ty_environment_and_active_environment"
      "--skip=python_environment::ty_environment_is_only_environment"
      "--skip=python_environment::ty_environment_is_system_not_virtual"
    ];

    nativeInstallCheckInputs = [ final.versionCheckHook ];
    versionCheckProgramArg = "--version";
    doInstallCheck = true;

    postInstall = lib.optionalString (final.stdenv.hostPlatform.emulatorAvailable final.buildPackages) (
      let
        emulator = final.stdenv.hostPlatform.emulator final.buildPackages;
      in
      ''
        installShellCompletion --cmd ty \
          --bash <(${emulator} $out/bin/ty generate-shell-completion bash) \
          --fish <(${emulator} $out/bin/ty generate-shell-completion fish) \
          --zsh <(${emulator} $out/bin/ty generate-shell-completion zsh)
      ''
    );

    meta = {
      description = "Extremely fast Python type checker and language server, written in Rust";
      homepage = "https://github.com/astral-sh/ty";
      changelog = "https://github.com/astral-sh/ty/blob/${finalAttrs.version}/CHANGELOG.md";
      license = lib.licenses.mit;
      mainProgram = "ty";
      maintainers = with lib.maintainers; [
        bengsparks
        GaetanLepage
      ];
    };
  });
}
