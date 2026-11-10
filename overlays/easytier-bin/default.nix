{ ... }:

final: prev:
let
  # EasyTier nightly（构建标识 2.7.0-f07d8d19-20261108）。
  #
  # 为什么离开 2.6.4：见 modules/nixos/easytier 的 etFlags 注释 —— 2.6.4 的
  # 候选地址污染 + 「选路只看 cost 不看质量」两个缺陷把 P2P 逼成了永久中继。
  # 2.7.0 修了低延迟优先路由与死链探测，nightly 又叠了 UDP 打洞重试、
  # STUN 映射不一致时的打洞、relay failover（#2774 / #2780 / #2781）。
  #
  # ⚠️ nightly 是**移动 tag**：同名 zip 每天被覆盖。hash 变化会让重建在
  #    fetch 阶段报 hash mismatch —— 这是有意的响铃，不是静默漂移。
  #    刷新流程：nix-prefetch-url --unpack <url> 然后改下面的 hash。
  version = "2.7.0-nightly";
  src = prev.fetchzip {
    url = "https://github.com/EasyTier/EasyTier/releases/download/nightly/easytier-linux-x86_64-v2.7.0.zip";
    hash = "sha256-jKrc33KgXJ1J5Q5pq7cwDXKxYPsa4bzjm2BeYDszVoc=";
    stripRoot = false;
  };
in
{
  easytier = prev.stdenvNoCC.mkDerivation {
    pname = "easytier";
    inherit version src;

    installPhase = ''
      runHook preInstall

      install -Dm755 easytier-linux-x86_64/easytier-core $out/bin/easytier-core
      install -Dm755 easytier-linux-x86_64/easytier-cli $out/bin/easytier-cli

      runHook postInstall
    '';

    meta = (prev.easytier.meta or { }) // {
      homepage = "https://github.com/EasyTier/EasyTier";
      changelog = "https://github.com/EasyTier/EasyTier/releases/tag/nightly";
      mainProgram = "easytier-core";
    };
  };
}
