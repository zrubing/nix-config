{
  lib,
  pkgs,
  stdenv,
  python312,
  fetchFromGitHub,
  gitMinimal,
  portaudio,
  playwright-driver,
  fetchPypi,
  system,
  inputs,
}:

let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  python312Packages = pkgs-unstable.python312Packages;
  tree-sitter-language-pack = python312Packages.buildPythonPackage rec {
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
  };
  tree-sitter-c-sharp = python312Packages.buildPythonPackage rec {
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
  };

  tree-sitter-embedded-template = python312Packages.buildPythonPackage rec {
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
  };

  tree-sitter-yaml = python312Packages.buildPythonPackage rec {
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
  };

  grep-ast = python312Packages.buildPythonPackage rec {
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
  };

  python3 = python312.override {
    self = python3;
    packageOverrides = _: super: {
      tree-sitter = super.tree-sitter_0_21;
    };
  };

  aider-chat = python312Packages.buildPythonPackage rec {
    pname = "aider-chat";
    version = "0.84.0";
    pyproject = true;

    src = fetchFromGitHub {
      inherit version;
      owner = "Aider-AI";
      repo = "aider";
      tag = "v${version}";
      hash = "sha256-TOlqwJM9wIAURSimuh9mysYDwgH9AfFev8jY9elLNk8=";
    };

    pythonRelaxDeps = true;

    build-system = with python3.pkgs; [ setuptools-scm ];

    dependencies = with python312Packages; [
      # aiohappyeyeballs
      # aiohttp
      # aiosignal
      # annotated-types
      # anyio
      # attrs
      # backoff
      beautifulsoup4
      # certifi
      # cffi
      # charset-normalizer
      # click
      configargparse
      diff-match-patch
      diskcache
      # distro
      # filelock
      flake8
      # frozenlist
      # fsspec
      gitdb
      gitpython
      # h11
      # httpcore
      # httpx
      # huggingface-hub
      # idna
      importlib-resources
      jinja2
      # jiter
      json5
      jsonschema
      jsonschema-specifications
      litellm
      # markdown-it-py
      markupsafe
      mccabe
      # mdurl
      # multidict
      networkx
      # numpy
      openai
      # packaging
      pathspec
      pexpect
      pillow
      prompt-toolkit
      psutil
      ptyprocess
      pycodestyle
      # pycparser
      pydantic
      pydantic-core
      pydub
      pyflakes
      # pygments
      pypandoc
      pyperclip
      python-dotenv
      pyyaml
      referencing
      regex
      requests
      rich
      rpds-py
      scipy
      six
      smmap
      sniffio
      sounddevice
      socksio
      soundfile
      soupsieve
      tiktoken
      tokenizers
      tqdm
      tree-sitter
      # tree-sitter-languages
      # typing-extensions
      urllib3
      watchfiles
      wcwidth
      yarl
      zipp
      pip
      tree-sitter-language-pack
      tree-sitter-c-sharp
      tree-sitter-embedded-template
      tree-sitter-yaml

      grep-ast
      # # Not listed in requirements
      mixpanel
      monotonic
      posthog
      propcache
      python-dateutil

      typing-inspection
      # 83.0
      cachetools
      google-ai-generativelanguage
      google-api-core
      google-api-python-client
      google-auth
      google-auth-httplib2
      google-generativeai
      googleapis-common-protos
      grpcio
      grpcio-status
      hf-xet
      httplib2
      mslex
      oslex
      proto-plus
      protobuf
      pyasn1
      pyasn1-modules
      pyparsing
      rsa
      shtab
      uritemplate
    ];

    buildInputs = [
      portaudio
    ];

    nativeCheckInputs = (with python3.pkgs; [ pytestCheckHook ]) ++ [ gitMinimal ];

    disabledTestPaths = [
      # Tests require network access
      "tests/scrape/test_scrape.py"
      # Expected 'mock' to have been called once
      "tests/help/test_help.py"
    ];

    disabledTests =
      [
        # Tests require network
        "test_urls"
        "test_get_commit_message_with_custom_prompt"
        # FileNotFoundError
        "test_get_commit_message"
        # Expected 'launch_gui' to have been called once
        "test_browser_flag_imports_streamlit"
        # AttributeError
        "test_simple_send_with_retries"
        # Expected 'check_version' to have been called once
        "test_main_exit_calls_version_check"
        # AssertionError: assert 2 == 1
        "test_simple_send_non_retryable_error"

        # 83.0
        "test_language_ocaml_interface"
        "test_language_ocaml"
      ]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [
        # Tests fails on darwin
        "test_dark_mode_sets_code_theme"
        "test_default_env_file_sets_automatic_variable"
        # FileNotFoundError: [Errno 2] No such file or directory: 'vim'
        "test_pipe_editor"
      ];

    makeWrapperArgs = [
      "--set AIDER_CHECK_UPDATE false"
      "--set AIDER_ANALYTICS false"
    ];

    preCheck = ''
      export HOME=$(mktemp -d)
      export AIDER_ANALYTICS="false"
    '';

    optional-dependencies = with python3.pkgs; {
      playwright = [
        greenlet
        playwright
        pyee
        typing-extensions
      ];
    };

    passthru = {
      withPlaywright = aider-chat.overridePythonAttrs (
        {
          dependencies,
          makeWrapperArgs,
          propagatedBuildInputs ? [ ],
          ...
        }:
        {
          dependencies = dependencies ++ aider-chat.optional-dependencies.playwright;
          propagatedBuildInputs = propagatedBuildInputs ++ [ playwright-driver.browsers ];
          makeWrapperArgs = makeWrapperArgs ++ [
            "--set PLAYWRIGHT_BROWSERS_PATH ${playwright-driver.browsers}"
            "--set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true"
          ];
        }
      );
    };

    meta = {
      description = "AI pair programming in your terminal";
      homepage = "https://github.com/paul-gauthier/aider";
      changelog = "https://github.com/paul-gauthier/aider/blob/v${version}/HISTORY.md";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [ happysalada ];
      mainProgram = "aider";
    };
  };
in
aider-chat
