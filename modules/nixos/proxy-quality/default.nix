# 按「实测可用性」驱动 selector 的探针。
#
# 背景（2026-10-28 实测）：客户端自带的 url-test / urltest 只测热会话上的一个
# 204，永远是 200–300ms；而真实体验的分水岭是冷启动——同一节点冷会话 5.6s，
# 拥塞时 20s 起不来。用 RTT 选节点等于用错误的指标做决策。
#
# 设计取舍：
#   · 候选从运行中客户端的 Clash API 现读，不写进 nix —— 节点名/协议/地区
#     不进公开仓库；nix 里只有「哪个组、多久测一次、怎么算分」这类策略。
#   · 每个候选新起一个 sing-box 进程 = 强制冷启动，测到的才是首次连接代价。
#   · 只驱动 selector；urltest 组不可写，脚本会直接退出并说明原因。
#   · 迟滞三件套（EWMA / 最小驻留 / 显著优于）避免链路抖动导致分组横跳。
#
# 为什么不做成「一次探测定终身」：这条线路的吞吐在一天内能差 50 倍
# （实测 0.01–5.5MB/s），单次采样不足以决策，必须平滑。
{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.proxyQuality;

  sibEnabled = config.${namespace}.sib.enable or false;
  mihoEnabled = config.${namespace}.miho.enable or false;

  # 只有被启用的那个客户端需要探测。两个都关时模块没有意义。
  clientConfigPath =
    if sibEnabled then
      config.${namespace}.sib.configPath
    else if mihoEnabled then
      config.services.mihomo.configFile
    else
      null;

  sing-box = config.${namespace}.sib.package;

  probe = pkgs.callPackage ../../../packages/proxy-quality { inherit sing-box; };

  # 两个 timer 共用同一套参数，只在模式上分叉。
  commonArgs = [
    "${probe}/bin/proxy-quality"
    "--config"
    clientConfigPath
    "--group-file"
    cfg.groupFile
    "--url"
    cfg.probeUrl
    "--bytes"
    (toString cfg.probeBytes)
    "--timeout"
    (toString cfg.timeout)
    "--min-dwell"
    (toString cfg.minDwell)
    "--improvement"
    (toString cfg.improvement)
    "--samples"
    (toString cfg.samples)
    "--state"
    "/var/lib/proxy-quality/state.json"
  ]
  ++ lib.concatMap (s: [ "--exclude-suffix" s ]) cfg.excludeTagSuffixes
  ++ lib.optionals (cfg.group != "") [ "--group" cfg.group ]
  ++ lib.optional cfg.dryRun "--dry-run";
in
{
  options.${namespace}.proxyQuality = {
    enable = lib.mkEnableOption "按实测可用性选择代理节点";

    group = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        要驱动的 selector 组名。必须是 selector（urltest/url-test 不可写）。

        默认留空：组名属于「能指向具体线路」的信息，不该写进公开仓库。
        实际取值从 groupFile 读，那个文件只在机器上，不在仓库里。
        这里保留选项只是为了临时覆盖/排障。
      '';
    };

    groupFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/proxy-quality/group";
      description = ''
        组名文件，首行有效。放在 /var/lib 而不是 /run：要跨重启存活，
        否则每次开机探针都会因为读不到组名而静默退出。

        文件不进仓库、不进 nix store，由本机手工创建一次：
          install -d -m 0700 /var/lib/proxy-quality
          printf '%s\n' '<组名>' > /var/lib/proxy-quality/group
        服务以 root 运行，文件保持 0600 即可。
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "探测间隔。默认 10 分钟，按 64KB × 候选数计约 1.5MB/小时。";
    };

    probeUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://www.gstatic.com/generate_204";
      description = ''
        探测 URL。用 204 是为了省流量；要测吞吐就换成大文件地址并调大 probeBytes
        —— 但那样每次探测的流量会从几十 KB 涨到 MB 级。
      '';
    };

    probeBytes = lib.mkOption {
      type = lib.types.int;
      default = 65536;
      description = "探测负载的标称字节数，用于把耗时换算成速率。";
    };

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "单个候选的超时（秒）。超过这个时间就当作不可用。";
    };

    minDwell = lib.mkOption {
      type = lib.types.int;
      default = 1200;
      description = "切换后的最小驻留时间（秒）。期间即使别的节点更快也不切。";
    };

    samples = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "每个候选采样几次取最短。单次采样抖动大（同一节点 0.9s/4.3s 都出现过）。";
    };

    improvement = lib.mkOption {
      type = lib.types.float;
      default = 0.25;
      description = "新节点需优于当前选择的比例才切换。设 0 表示只要更快就切（不建议）。";
    };

    excludeTagSuffixes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        候选里剔除 tag 以这些后缀结尾的节点。默认不剔：v6 腿和 v4 腿走的是
        不同路径，但都能被测量，冷启动/吞吐实测差距（0.48s vs 2.3s）靠评分
        表达即可，不需要按拓扑先验排除。用后缀而不是节点名，避免把节点信息
        写进公开仓库。
      '';
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "只测量、不切换。用于观察评分是否符合直觉。";
    };

    quickCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          快速存活检查：只测当前选中的节点，连续失败若干次就切到历史评分最优。
          用来把「节点死了没人发现」的窗口从一个全量周期压到一个短周期。
        '';
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "快速存活检查的间隔。";
      };
      fails = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "连续失败多少次才判定当前节点已死。";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = clientConfigPath != null;
        message = "${namespace}.proxyQuality 需要 miho 或 sib 之一启用：探针要读运行中的客户端配置拿 Clash API 地址。";
      }
      {
        # 探针用 sing-box 起临时实例；miho 模式下没有 sing-box 包，先不支持。
        assertion = sibEnabled;
        message = "${namespace}.proxyQuality 目前只支持 sib（sing-box）客户端。";
      }
    ];

    systemd.services.proxy-quality = {
      description = "按实测可用性选择代理节点";
      # 客户端没起来时 API 不可用，探测没有意义；但也不该把 sib 拉起来。
      after = [ "sib.service" ];
      wants = [ "sib.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs commonArgs;
        # 读 /run/sib 下的运行时配置（含凭据），必须是 root。
        User = "root";
        # /var/lib/proxy-quality：组名文件和 EWMA/驻留状态都在这里（跨重启存活，不进仓库）。
        StateDirectory = "proxy-quality";
        StateDirectoryMode = "0700";
        # 探测要发真流量，不做网络命名空间隔离。
        PrivateNetwork = false;
      };
    };

    systemd.timers.proxy-quality = {
      description = "定时探测代理节点质量";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "1min";
        Unit = "proxy-quality.service";
      };
    };

    systemd.services."proxy-quality-quick" = lib.mkIf cfg.quickCheck.enable {
      description = "代理节点存活检查（只测当前节点）";
      after = [ "sib.service" ];
      wants = [ "sib.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs (
          commonArgs
          ++ [
            "--quick"
            "--quick-fails"
            (toString cfg.quickCheck.fails)
          ]
        );
        User = "root";
        StateDirectory = "proxy-quality";
        StateDirectoryMode = "0700";
        PrivateNetwork = false;
      };
    };

    systemd.timers."proxy-quality-quick" = lib.mkIf cfg.quickCheck.enable {
      description = "定时检查当前代理节点是否还活着";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "90s";
        OnUnitActiveSec = cfg.quickCheck.interval;
        AccuracySec = "10s";
        Unit = "proxy-quality-quick.service";
      };
    };
  };
}
