{
  lib,
  pkgs,
  fetchFromGitHub,
  buildGoModule,
  ...
}:

buildGoModule rec {
  pname = "trojan-go";
  version = "0.10.6";

  rev = "c49cabe00cd07062b9365ea020020702ec076d08";

  src = fetchFromGitHub {
    owner = "gfw-report";
    repo = pname;
    rev = rev;
    hash = "sha256-NibeOouvRrLi1UYfvNUM4wInLYnQXMuQP6SA32I1yaQ=";
  };

  vendorHash = "sha256-jb2XA152eQ9mQAFIodHA3a1oNkcDVuwrjpe6FvF8lu8=";
  proxyVendor = true;

  # 禁用自动版本注入（改用 Makefile 方式）
  ldflags = [
    "-s"
    "-w"
    "-buildid="
  ];

  # 指定需要构建的子包路径
  subPackages = [ "." ];

  # 修复构建流程
  buildPhase = ''
    runHook preBuild
    make VERSION=${version} COMMIT=${rev} trojan-go
  '';

  # 添加 git 到 nativeBuildInputs 用于获取版本信息
  nativeBuildInputs = [ pkgs.git ];

  # 安装必要文件
  postInstall = ''
    install -Dm644 example/*.json -t $out/etc/trojan-go/
    install -Dm644 example/trojan-go.service -t $out/lib/systemd/system/
  '';

  # 修正输出路径
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp build/trojan-go $out/bin/
  '';

  
}
