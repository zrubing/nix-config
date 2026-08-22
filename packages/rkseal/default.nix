{
  lib,
  buildRubyGem,
  fetchFromGitHub,
  kubeseal,
  kubernetes,
  rubyPackages,
}:

buildRubyGem rec {
  name = "rkseal";
  gemName = "rkseal";
  version = "0.1.1";

  src = fetchFromGitHub {
    owner = "pwojcieszonek";
    repo = "rkseal";
    rev = "17231facd97522af5e63c76832d4590b0e09ac5d";
    hash = "sha256-4avclTLsxeYBcWZxE+yPwdpuJPQ68Q2bUsB8b6inkqE=";
  };

  # rkseal 调用的外部 CLI（kubeseal + kubectl）
  buildInputs = [
    kubeseal
    kubernetes
  ];

  # gem 运行时依赖（gem install --ignore-dependencies，需显式声明）。
  # base64 在 ruby 3.4+ 不再是默认 gem，gemspec 已显式列出。
  gemPath = [
    rubyPackages.thor
    rubyPackages.base64
  ];

  # rkseal 的 binstub 是纯 ruby 脚本，不会把外部 CLI 挂进 PATH。
  # 必须用 wrapProgram（原地包装：先把原文件移为 ./.rkseal-wrapped 再生成
  # wrapper）；用 makeWrapper $out/bin/rkseal $out/bin/rkseal 会因
  # program==wrapper 覆盖原 binstub，生成自 exec 自己的 wrapper（死循环卡死）。
  postFixup = ''
    wrapProgram $out/bin/rkseal \
      --prefix PATH : ${lib.makeBinPath [ kubeseal kubernetes ]}
    # shebang 脚本的 $0 永远是自身文件路径（exec -a 也无效），Thor 的 help
    # banner 用 File.basename($0) 会显示成包装后的隐藏名 .rkseal-wrapped；
    # 在 binstub 里手动设 $0 修正显示。
    substituteInPlace $out/bin/.rkseal-wrapped \
      --replace-fail 'load Gem.activate_bin_path' '$0 = "rkseal"
load Gem.activate_bin_path'
  '';

  postPatch = ''
    # gemspec 钉死 ruby >= 4.0.0（作者用 rvm 4.0.2 开发），但完整单测
    # 套件（343 examples）在 nixpkgs 的 ruby 3.3 / 3.4 下全部通过，
    # 放宽下限以匹配 nixpkgs 实际提供的 ruby。
    substituteInPlace rkseal.gemspec \
      --replace-fail 'spec.required_ruby_version = ">= 4.0.0"' \
      'spec.required_ruby_version = ">= 3.3"'
  '';
  dontBuild = false;

  meta = {
    description = "Interactively create and edit Kubernetes SealedSecrets via $EDITOR (wraps kubeseal)";
    homepage = "https://github.com/pwojcieszonek/rkseal";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    mainProgram = "rkseal";
  };
}
