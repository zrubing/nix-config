# 统一 MCP server 定义（单一事实来源）：一处声明，pi 与 dsh 各取所需。
#
# 为什么需要这个文件：pi 的 MCP 配置是 ~/.pi/agent/mcp.json（Claude Code 风格
# JSON），dsh 的是 ~/.dsh/cordis.patch.yml（cordis 插件条目 YAML）。格式与密钥
# 求值方式都不同，此前两边各自硬编码——新增/改一个 server 要动两处，且同一
# server 的连接方式容易漂移。
#
# 每个 server 可声明两个视图（缺省某侧 = 该侧不启用）：
#
#   pi  = 写入 ~/.pi/agent/mcp.json 的条目。密钥不写明文，用 ${VAR} 引用——
#         pi-mcp-adapter 对 env / headers / url / cwd / socket 做插值（args 不做，
#         故密钥必须走 env 或 headers，不能塞进 args）。变量由 shell 的
#         ~/.config/default.env（sops 渲染，见 modules/home/sops）提供。
#
#   dsh = dsh-mcp-client 插件 config，渲染进 cordis.patch.yml。密钥不写明文，
#         用 { env = "VAR"; } 表示运行时读宿主 env（渲染成 !!js process.env.VAR）；
#         { env = "VAR"; prefix = "…"; } 表示加前缀（如 "Bearer "）。变量由
#         ~/.config/dsh.env（sops 渲染，dsh-web 启动时 source）提供。
#
# 密钥值本身不在本文件：pi 侧 ~/.config/default.env、dsh 侧 ~/.config/dsh.env，
# 两边同名变量。轮换 key 只改 sops/clan vars，本文件不动。
#
# 注意：pi 视图里含密钥的字段必须整字段重写（jq `*` 深合并，数组整体替换）。
# 例：context7 的 key 从 args 的 --api-key 迁到 env.CONTEXT7_API_KEY，这样
# nix 覆盖 args 时不会丢密钥（@upstash/context7-mcp 支持该环境变量，实测 npm
# readme：`--api-key <key>` 或 `CONTEXT7_API_KEY` env 二选一）。
{
  lib,
  pkgs,
  namespace,
}:
let
  # YAML 标量：裸标量优先，含特殊字符才加双引号（与 dsh/default.nix 同规则）
  yamlScalar = v:
    if builtins.isInt v then builtins.toString v
    else if v == true then "true"
    else if v == false then "false"
    else if builtins.match "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" (builtins.toString v) != null
    then builtins.toString v
    else "\"${builtins.replaceStrings [ "\"" ] [ "\\\"" ] (builtins.toString v)}\"";

  # dsh config 值渲染：{ env = "VAR"; } → !!js process.env.VAR
  dshValue = v:
    if lib.isAttrs v && (v ? env) then
      if v ? prefix
      then "!!js '\"${v.prefix}\" + process.env.${v.env}'"
      else "!!js process.env.${v.env}"
    else yamlScalar v;

  # 单个 server 的 cordis patch 条目（列 0 起，与 providerPatch 其他 insert 条目对齐：
  # `- insert:` 列 0 / `- id:` 列 4 / config 字段列 8 / 子项列 10）
  dshEntry = name: s:
    let
      cfg = s.dsh;
      cfgLines =
        [
          "serverName: ${yamlScalar name}"
          "transport: ${yamlScalar cfg.transport}"
        ]
        ++ (
          if cfg.transport == "stdio" then
            [ "command: ${yamlScalar cfg.command}" ]
            ++ lib.optional (cfg ? args) "args: [${lib.concatMapStringsSep ", " yamlScalar cfg.args}]"
            ++ lib.optional (cfg ? cwd) "cwd: ${yamlScalar cfg.cwd}"
            ++ lib.optional (cfg ? env) "env:"
            ++ lib.mapAttrsToList (k: v: "  ${k}: ${dshValue v}") (cfg.env or { })
          else
            [ "url: ${yamlScalar cfg.url}" ]
            ++ lib.optional (cfg ? headers) "headers:"
            ++ lib.mapAttrsToList (k: v: "  ${k}: ${dshValue v}") (cfg.headers or { })
        );
    in
    lib.concatStringsSep "\n" (
      [
        "# ${s.description}"
        "- insert:"
        "    - id: mcp-${name}"
        "      name: '@deepseek-ai/dsh-mcp-client'"
        "      config:"
      ]
      ++ lib.map (l: "        ${l}") cfgLines
    );
in
rec {
  # ------------------------------------------------------------------ 统一源
  servers = {
    # ---------------------------------------------------------- pi + dsh 共用
    github = {
      description = "GitHub MCP（pi: docker stdio 本地；dsh: 官方远程托管，免 docker）";
      pi = {
        command = "docker";
        args = [
          "run"
          "-i"
          "--rm"
          "-e"
          "GITHUB_PERSONAL_ACCESS_TOKEN"
          "-e"
          "GITHUB_DYNAMIC_TOOLSETS"
          "ghcr.io/github/github-mcp-server"
        ];
        # PAT 走 GH_TOKEN（sops default.env，与 github-mcp/api_token 同源同一份
        # PAT，随 MCP token 一起轮换）。GITHUB_DYNAMIC_TOOLSETS=1 开启动态工具集。
        env = {
          GITHUB_PERSONAL_ACCESS_TOKEN = "\${GH_TOKEN}";
          GITHUB_DYNAMIC_TOOLSETS = "1";
        };
      };
      dsh = {
        transport = "streamable-http";
        url = "https://api.githubcopilot.com/mcp/";
        headers.Authorization = {
          env = "GITHUB_MCP_TOKEN";
          prefix = "Bearer ";
        };
      };
    };

    context7 = {
      description = "Context7 库文档 MCP（pi: npx stdio；dsh: Upstash 远程托管）";
      # key 从 args 的 --api-key 迁到 env（见文件头注释：args 不支持插值）。
      pi = {
        type = "stdio";
        command = "npx";
        args = [
          "-y"
          "@upstash/context7-mcp"
        ];
        env.CONTEXT7_API_KEY = "\${CONTEXT7_API_KEY}";
      };
      dsh = {
        transport = "streamable-http";
        url = "https://mcp.context7.com/mcp";
        headers.CONTEXT7_API_KEY = {
          env = "CONTEXT7_API_KEY";
        };
      };
    };

    # 智谱 Z.ai MCP（图像/视频理解等）。key 与 web-search-prime 同一份智谱 key
    # （ZAI_CODING_CN_API_KEY ← sops anthropic/api_key，两侧实测同值）。
    zai-mcp-server = {
      description = "Z.ai MCP（视觉/多模态，智谱 key，两侧均 npx stdio）";
      pi = {
        type = "stdio";
        command = "npx";
        args = [
          "-y"
          "@z_ai/mcp-server"
        ];
        env = {
          Z_AI_API_KEY = "\${ZAI_CODING_CN_API_KEY}";
          Z_AI_MODE = "ZHIPU";
        };
      };
      dsh = {
        transport = "stdio";
        command = "npx";
        args = [
          "-y"
          "@z_ai/mcp-server"
        ];
        env = {
          Z_AI_API_KEY = {
            env = "ZAI_CODING_CN_API_KEY";
          };
          Z_AI_MODE = "ZHIPU";
        };
      };
    };

    # 智谱 web 搜索（远程 HTTP，Bearer 认证）
    web-search-prime = {
      description = "智谱 web 搜索 MCP（远程 HTTP，Bearer 智谱 key）";
      pi = {
        type = "http";
        url = "https://open.bigmodel.cn/api/mcp/web_search_prime/mcp";
        headers.Authorization = "Bearer \${ZAI_CODING_CN_API_KEY}";
      };
      dsh = {
        transport = "streamable-http";
        url = "https://open.bigmodel.cn/api/mcp/web_search_prime/mcp";
        headers.Authorization = {
          env = "ZAI_CODING_CN_API_KEY";
          prefix = "Bearer ";
        };
      };
    };

    # ------------------------------------------------------------- 仅 pi 侧
    # chrome-devtools 需要 DISPLAY + 系统 Chrome，dsh-web 是 systemd user 服务
    # （实测 Environment 只有 PATH/BROWSER，无 DISPLAY）→ dsh 侧不启用。
    # command 用 nix 锁版本的 store 路径（不依赖 npx 下载），Chrome 指向系统
    # google-chrome（NixOS 上 Puppeteer 自带的 Chrome-for-Testing 跑不了）。
    chrome-devtools = {
      description = "Chrome DevTools MCP（仅 pi：需要 DISPLAY，dsh-web 服务无）";
      pi = {
        command = "${pkgs.${namespace}.chrome-devtools-mcp}/bin/chrome-devtools-mcp";
        args = [
          "-e"
          "${pkgs.unstable.google-chrome}/bin/google-chrome-stable"
        ];
      };
    };

    # ------------------------------------------------------------ 仅 dsh 侧
    # ApiPost 开放平台 MCP：远程 streamable-http，认证走 api-token 头。token 由
    # clan vars（apipost-mcp-token）→ home sops 渲染进 dsh.env。pi 侧未配置。
    apipost = {
      description = "ApiPost 开放平台 MCP（仅 dsh，远程 HTTP，api-token 头）";
      dsh = {
        transport = "streamable-http";
        url = "https://open.apipost.net/mcp";
        headers."api-token" = {
          env = "APIPOST_MCP_TOKEN";
        };
      };
    };
  };

  # ------------------------------------------------- pi 侧渲染（mcpServers 对象）
  # 只输出声明了 pi 视图的 server；密钥保持 ${VAR} 引用，由 pi-mcp-adapter 在
  # 连接时插值（值来自 shell 的 default.env）。
  piServers = lib.mapAttrs (_: s: s.pi) (lib.filterAttrs (_: s: s ? pi) servers);

  # --------------------------------------------- dsh 侧渲染（cordis 条目 YAML）
  # 只输出声明了 dsh 视图的 server。每行已是最终列位（列 0 起），插进
  # providerPatch 时按 4 空格缩进写插值行（与该 '' 串的公共缩进对齐）。
  dshPatchEntries = lib.concatStringsSep "\n\n" (
    lib.mapAttrsToList dshEntry (lib.filterAttrs (_: s: s ? dsh) servers)
  );
}
