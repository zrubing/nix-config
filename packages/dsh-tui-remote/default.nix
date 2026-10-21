# 远程模式的 dsh-tui 客户端（源码构建）。
#
# 设计与验收记录见 docs/dsh-tui-remote-design.md。
#
# ## 为什么自带 pnpm 11
#
# 本仓 `package.json` 钉 `pnpm@11.21.0`，而 nixpkgs 只到 pnpm 10。pnpm 是 JS CLI，
# 所以直接从 npm 取 tarball、用 node 跑，不依赖 nixpkgs 的版本线。
#
# ## 为什么依赖用「自带网络的 FOD 装成 node_modules」
#
# `fetchPnpmDeps` 的产物是内容寻址 store，构建期 `--offline` 仍要 registry metadata
# 才能把名字解析成 integrity，缺一条就 `ERR_PNPM_NO_OFFLINE_TARBALL`；pnpm 11 的
# release-age / trust 校验在离线树里也永远拿不到 metadata。固定输出派生式允许联网，
# 装完直接交出 node_modules，构建期完全不跑 pnpm 解析。
#
# ## hash 引导
#
# 两个依赖 FOD 各有一处 `lib.fakeHash`（`ROOT_HASH` / `VENDOR_HASH`）：build 一次 →
# 抄报错里的 got → 填回。源码与 pnpm tarball 的 hash 已填好。
#
# ## 为什么装完要钉 pnpm 的墙钟时间
#
# pnpm 会把构建时刻写进产物：`.modules.yaml` 的 `prunedAt`、
# `.pnpm-workspace-state-v1.json` 的 `lastValidatedTimestamp`。固定输出派生只要
# 这两个值一变就是 hash mismatch —— 同一台机器隔一分钟重编都对不上，别的机器
# 更是永远复现不出来（nova13 上就是这么炸的）。它们只是 pnpm 自己的状态缓存，
# 构建期不再跑 pnpm、产物只做 node_modules 交付，所以统一钉成常量。
#
# 结论：这两个 FOD 的 hash 是**可复现**的，任何人都能重编出同一个 store path；
# 改完安装逻辑必须两个 hash 一起重填。
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs-slim,
  makeWrapper,
  zstd,
  cacert,
}:

let
  # 升级脚本（scripts/update-dsh-tui.sh）只改这一行。
  tag = "v0.16.1";

  pnpmVersion = "11.21.0";

  pnpm = stdenv.mkDerivation {
    pname = "pnpm";
    version = pnpmVersion;
    src = fetchurl {
      url = "https://registry.npmjs.org/pnpm/-/pnpm-${pnpmVersion}.tgz";
      hash = "sha256-hyN9N+rbedxiagV26zpS0j1wQiwyOuXgD8BckfQyN4A=";
    };
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/libexec
      cp -r . $out/libexec/pnpm
      makeWrapper ${lib.getExe nodejs-slim} $out/bin/pnpm \
        --add-flags $out/libexec/pnpm/bin/pnpm.cjs
      runHook postInstall
    '';
    # pnpmConfigHook / fetchPnpmDeps 会 `inherit (pnpm) nodejs-slim`。
    passthru.nodejs-slim = nodejs-slim;
  };

  # pnpm 把构建时刻写进产物（见文件头「为什么装完要钉 pnpm 的墙钟时间」）。
  # 两个依赖 FOD 装完 node_modules 后都要走一遍，否则 hash 不可复现。
  pinPnpmTimestamps = ''
    for f in node_modules/.modules.yaml node_modules/.pnpm-workspace-state-v1.json; do
      if [ -f "$f" ]; then
        sed -i -E \
          -e 's/"prunedAt": "[^"]*"/"prunedAt": "Thu, 01 Jan 1970 00:00:00 GMT"/' \
          -e 's/"lastValidatedTimestamp": [0-9]+/"lastValidatedTimestamp": 0/' \
          "$f"
      fi
    done
  '';

in
stdenv.mkDerivation (finalAttrs: {
  pname = "dsh-tui-remote";
  # 版本只有一个来源：脚本只改 tag，产物名跟着走，不会再出现 0.16 的源码打成 0.15 包。
  version = lib.removePrefix "v" tag;

  src = fetchFromGitHub {
    owner = "ccch1mneyyy";
    repo = "dsh-TUI";
    tag = tag;
    hash = "sha256-qZaaOmdDEwZjgBEGA85DcTrlXuWqBOqs66k7w+tOmnM="; # SRC_HASH
    fetchSubmodules = true;
  };

  # remote-mode.patch 是完整的远程客户端改动；permission-presets.patch 叠加在它
  # 之上，把 Host 的权限预设投影成远程会话的 typed `modes`（`/permission` 与
  # Shift+Tab）；preset-support.patch 再把 Host 的 agent-preset 名册投影成 typed
  # `presets`（`/preset` 选择器、`/preset <id>`、`/preset status`）；
  # notification-ghostty-cap.patch 按 Ghostty apprt 的固定通知缓冲
  # （title 63 B / body 255 B）截断 OSC 777/9，避免其盲截 255 B 时切开 UTF-8。
  # stream-resume.patch 把 `session/follow` 与 `session/control` 换成跨连接代可
  # 恢复的流：宿主重启/断线后自动续传，而不是让窗口继续能发消息却收不到任何帧。
  # remote-link-visibility.patch 让这条重连在界面上可见（断线常驻提示 / 恢复提示），
  # 并把宿主重启造成的 `turn.end interrupted` 与用户 Esc 的 `aborted` 分成两种文案。
  #
  # startup-model.patch 暂不接入：它按旧版源码行号生成（session.ts:1556），套不上
  # v0.16.1；且它依赖的 agentDefaultModel 在 Host 侧没有 typert.remote-client 面。
  # 修好前不参与构建，避免整个包被一个未验证的叠加补丁卡死。
  #
  # ctrl-o-layout.patch 修长会话 Ctrl+O 卡顿：展开模式不再写进每行的高度签名
  # （否则一次按键让整段 transcript 的实测高度全部失效，窗口扩展循环把已绘制
  # 行全部重挂载），视口外行保留上次实测高度作为惰性估计，只有本帧真正变高的
  # 行才重挂载；超长 reasoning 与工具卡一样按 400 行窗口渲染。32 行/1MB 尾部
  # 的探针从 214ms Yoga 降到 3ms；400 行/200 张长工具卡的单次切换 Yoga 约 50ms。
  patches = [
    ./remote-mode.patch
    ./permission-presets.patch
    ./preset-support.patch
    ./notification-ghostty-cap.patch
    ./stream-resume.patch
    ./remote-link-visibility.patch
    ./ctrl-o-layout.patch
  ];

  # pnpm 11 从 **workspace 清单**读 trustPolicy / minimumReleaseAge，命令行
  # `--config.*` 对这两个键无效（实测）：没有 registry metadata 时校验必然失败。
  # 清单顶部关掉它；`--frozen-lockfile` 不校验这两项，锁文件仍是权威。
  postPatch = ''
    for f in pnpm-workspace.yaml vendor/dsh-std/pnpm-workspace.yaml; do
      if [ -f "$f" ]; then
        { printf 'trustPolicy: off\nminimumReleaseAge: 0\n'; cat "$f"; } > "$f.new"
        mv "$f.new" "$f"
      fi
    done
  '';

  # 根依赖也装成 node_modules（与 vendor 同构）：只允许当前平台的二进制，
  # 否则 pnpm 会连 darwin/win32 的可选包一起抓（数 GB，必然超时）。
  rootDeps = stdenv.mkDerivation {
    name = "dsh-tui-remote-node-modules";
    nativeBuildInputs = [ nodejs-slim pnpm cacert ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-s7byR4602mXHFze6o+k7ftfIFdk3iWUX3dM2N5j8mmY="; # ROOT_HASH
    buildCommand = ''
      export HOME=/build/home
      export npm_config_cache=/build/cache
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      mkdir -p "$HOME"
      cp -r ${finalAttrs.src}/. /build/ws
      chmod -R u+w /build/ws
      cd /build/ws
      {
        printf 'trustPolicy: off\nminimumReleaseAge: 0\n'
        printf 'supportedArchitectures:\n  os: [linux]\n  cpu: [x64]\n  libc: [glibc]\n'
        cat pnpm-workspace.yaml
      } > ws.yaml
      mv ws.yaml pnpm-workspace.yaml
      pnpm install --frozen-lockfile --ignore-scripts --prod=false --store-dir /build/store
      rm -rf node_modules/.cache
      ${pinPnpmTimestamps}
      cp -a node_modules "$out"
    '';
  };

  # vendor/dsh-std 是**独立** workspace：它自己的 lockfile 里才有 tsdown 等工具，
  # 而 fetchPnpmDeps 从这棵子树解析时会被上层 workspace 干扰（同一份输入每次产出
  # 不同 hash）。所以这里直接装成 node_modules，并把 store/HOME 钉在固定路径上，
  # 免得绝对路径进到产物里导致 hash 抖动。
  vendorDeps = stdenv.mkDerivation {
    name = "dsh-tui-remote-vendor-node-modules";
    nativeBuildInputs = [ nodejs-slim pnpm cacert ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-0y+WO1baX8HwWCzxKEUTbFk1Aa4RpUKbv7OEIlA1b0g="; # VENDOR_HASH
    buildCommand = ''
      export HOME=/build/home
      export npm_config_cache=/build/cache
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      mkdir -p "$HOME"
      cp -r ${finalAttrs.src}/vendor/dsh-std /build/ws
      chmod -R u+w /build/ws
      cd /build/ws
      { printf 'trustPolicy: off\nminimumReleaseAge: 0\n'; cat pnpm-workspace.yaml; } > ws.yaml
      mv ws.yaml pnpm-workspace.yaml
      pnpm install --frozen-lockfile --ignore-scripts --prod=false --store-dir /build/store
      rm -rf node_modules/.cache
      ${pinPnpmTimestamps}
      cp -a node_modules "$out"
    '';
  };

  nativeBuildInputs = [ nodejs-slim ];

  buildPhase = ''
    runHook preBuild

    cp -a "$rootDeps" node_modules
    cp -a "$vendorDeps" vendor/dsh-std/node_modules
    chmod -R u+w node_modules vendor/dsh-std/node_modules

    for pkg in core manifest connection presentation command storage messages; do
      pushd "vendor/dsh-std/packages/$pkg"
      ../../node_modules/.bin/tsc -p tsconfig.json --noEmit
      ../../node_modules/.bin/tsdown
      popd
    done

    node --import tsx/esm scripts/gen-backend-index.mjs
    node_modules/.bin/tsc -p tsconfig.json
    node scripts/gen-settings-json.mjs

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec
    cp -a lib package.json node_modules $out/libexec/
    # node_modules 里有指向 workspace 包（vendor/…）的 symlink，少了它们
    # fixupPhase 的 noBrokenSymlinks 会直接判失败。
    cp -a vendor $out/libexec/vendor
    cp -a assets guide presets tui-profile $out/libexec/ 2>/dev/null || true
    runHook postInstall
  '';

  meta = {
    description = "dsh-tui as a remote client of a running DeepSeek Harness core";
    homepage = "https://github.com/ccch1mneyyy/dsh-TUI";
    license = lib.licenses.mit;
  };
})
