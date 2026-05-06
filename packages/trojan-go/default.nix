{
  lib,
  pkgs,
  fetchFromGitHub,
  applyPatches,
  buildGoModule,
  ...
}:

buildGoModule rec {
  pname = "trojan-go";
  version = "0.10.6";

  rev = "c49cabe00cd07062b9365ea020020702ec076d08";

  src = applyPatches {
    src = fetchFromGitHub {
      owner = "gfw-report";
      repo = pname;
      rev = rev;
      hash = "sha256-NibeOouvRrLi1UYfvNUM4wInLYnQXMuQP6SA32I1yaQ=";
    };
    # 仍然使用 gfw-report/trojan-go，只更新 assume-no-moving-gc 依赖以兼容 Go 1.25 运行时检查。
    patches = [
      ./update-assume-no-moving-gc.patch
      ./force-client-alpn.patch
    ];
  };

  vendorHash = "sha256-Q6hqZgLygvyfTGWSojMb0B1XfHhQHMl9i9Vr7bQCkDA=";
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
    runHook postInstall
  '';

  meta = with lib; {
    description = "Trojan-Go proxy client/server";
    homepage = "https://github.com/gfw-report/trojan-go";
    license = licenses.gpl3Only;
    mainProgram = "trojan-go";
    platforms = platforms.linux;
  };
}
