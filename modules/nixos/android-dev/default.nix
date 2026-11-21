{ config, lib, pkgs, namespace, ... }:

let
  cfg = config.${namespace}.android-dev;

  # Android SDK 由 androidenv 组合。accept_license 必须在 nixpkgs 实例上打开，
  # 否则 composeAndroidPackages 求值阶段就报 license 未接受。
  android = pkgs.androidenv.composeAndroidPackages {
    # FlClash / Flutter 当前要求：build-tools 35、platform 35/36、NDK（Flutter
    # 3.4x 默认 NDK 27）。
    buildToolsVersions = cfg.buildToolsVersions;
    platformVersions = cfg.platformVersions;
    abiVersions = [ "arm64-v8a" "x86_64" ];
    includeNDK = true;
    # Gradle 插件（sqlite3 等）会按需装 cmake；SDK 只读，必须预先由 nix 提供。
    includeCmake = true;
    cmakeVersions = [ "3.22.1" ];
    ndkVersions = cfg.ndkVersions;
    includeEmulator = false;
    includeSystemImages = false;
    includeSources = false;
  };

  sdkRoot = "${android.androidsdk}/libexec/android-sdk";
in
{
  options.${namespace}.android-dev = with lib; {
    enable = mkEnableOption "Android/Flutter 构建工具链（SDK、NDK、JDK 17、Gradle、gomobile、apktool）";

    buildToolsVersions = mkOption {
      type = types.listOf types.str;
      default = [ "34.0.0" "35.0.0" "36.0.0" "37.0.0" ];
      description = "androidenv build-tools 版本列表";
    };
    platformVersions = mkOption {
      type = types.listOf types.str;
      default = [ "35" "36" "37" ];
      description = "Android platform（android-XX）版本列表";
    };
    ndkVersions = mkOption {
      type = types.listOf types.str;
      default = [ "27.0.12077973" "28.2.13676358" ];
      description = "NDK 版本列表";
    };
  };

  config = lib.mkIf cfg.enable {
    # androidenv 的固件包是 unfree-like：不声明就拒绝求值。
    nixpkgs.config.android_sdk.accept_license = true;

    environment.systemPackages = with pkgs; [
      # SDK（含 platform-tools、build-tools、platforms、NDK）
      android.androidsdk
      # Flutter 必须取 unstable：nixpkgs 稳定的 3.41.9 自带 Dart 3.11.5，
      # 而 FlClash 源码的 pubspec 依赖 riverpod_generator 4.0.9（要求 Dart
      # ^3.12.0），版本求解直接失败。unstable 的 3.47.x 才够。
      unstable.flutter
      jdk17
      gradle
      # 核心（Clash.Meta）用 gomobile bind 产出 libclash.so
      go
      gomobile
      # 原生构建依赖（Flutter plugin / NDK 工具链）
      clang
      cmake
      ninja
      pkg-config
      # APK 后处理：反编译、重打包、验签
      apktool
      unzip
      which
    ];

    # 只在 session 里给变量，不写死进 /etc/environment：
    # gradle 会读 ANDROID_HOME，Flutter 会读 ANDROID_SDK_ROOT，缺一个就报
    # "No Android SDK found"。
    environment.sessionVariables = {
      ANDROID_HOME = sdkRoot;
      ANDROID_SDK_ROOT = sdkRoot;
      JAVA_HOME = "${pkgs.jdk17}";
      GRADLE_USER_HOME = "\${HOME}/.gradle";
      GOBIN = "\${HOME}/go/bin";
      # gomobile bind 需要 CGO 与 NDK 里的 clang
      CGO_ENABLED = "1";
    };

    # Flutter/Gradle 首次构建要写 ~/.gradle 与 SDK 目录；SDK 在 /nix/store 只读，
    # 因此给一份可写的 license 目录，避免 gradle 报 "SDK dir not writable"。
    system.activationScripts.androidSdkLicenses = lib.mkIf cfg.enable ''
      install -d -m 0755 /var/lib/android-sdk
      if [ ! -e /var/lib/android-sdk/licenses ]; then
        install -d -m 0755 /var/lib/android-sdk/licenses
        printf '\n24333f8a63b6825ea9c5514f83c2829b004d1fee' > /var/lib/android-sdk/licenses/android-sdk-license
      fi
    '';

    # 三条踩过的坑，改这个模块前先看：
    #
    # 1. SDK 路径会随每次 nixos 更新换 store 路径。工程的 android/local.properties
    #    里不要写死 sdk.dir，删掉那行让 AGP 回退到本模块给的 ANDROID_HOME。
    # 2. NDK 的 aarch64-linux-androidNN-clang 是个 shell 脚本，内部按 $0 推导
    #    bin_dir 再执行 $bin_dir/clang。给它做软链接（哪怕只为让 bindgen 探测
    #    到头文件）会让它指回自己，形成无限递归：一瞬间几千个 clang 进程，内存
    #    打满后被 OOM 杀，日志里看不出是谁吃的。要 shim 就 exec 真正的
    #    toolchains/llvm/prebuilt/linux-x86_64/bin/clang，并显式给 --target。
    # 3. bindgen 默认走宿主 clang（glibc 头），交叉编译 Android 时会报
    #    gnu/stubs-32.h 缺失。需要设 LIBCLANG_PATH、BINDGEN_EXTRA_CLANG_ARGS、
    #    CC_<triple>、CARGO_TARGET_<TRIPLE>_LINKER 指向 NDK。
  };
}
