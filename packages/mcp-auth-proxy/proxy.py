#!/usr/bin/env python3
"""mcp-auth-proxy —— 本地 MCP 鉴权代理：客户端配置零密钥，token 只存在一个文件里。

为什么要这一层（问题）：

  1. 五个自建 MCP（ci / db / agent-docs / loki / forgejo）都接受同一个 OpenBao
     periodic token，但 token 会变（revoke、连续 3 天未用而过期、重新登录）。
  2. 客户端（multica / dsh / pi / codex）的 MCP 配置是**静态**的，没有地方跑
     刷新流程；把 token 抄进配置 = 一个必然过期的副本 + 一份明文密钥躺在
     multica 的数据库 / nix store / 配置文件里。
  3. 一份 token 抄 N 处，轮换就是 N 处手改，漏一处表现为某客户端莫名 401。

做法：本进程读 token 文件（每个请求读一次，改动立即生效），按路径前缀路由到
上游，并把 `Authorization: Bearer <token>` 注入进去。客户端只需要一个不含任何
密钥的地址：`http://127.0.0.1:9100/<name>/mcp`。

信任边界（必须知道）：监听 127.0.0.1，不做客户端认证 —— 任何本机同用户进程都
能借道使用这张 token。这与 token 文件本身 0600 的信任级一致（拿到文件 = 拿到
token），不引入新的攻击面。不要把它绑到 0.0.0.0。

配置（全部来自环境变量，nix 与 sops 各自负责自己那半）：

  MCP_TOKEN_FILE      token 文件路径（默认 ~/.local/state/mcp/token）
  MCP_PROXY_LISTEN    监听地址（默认 127.0.0.1:9100）
  MCP_PROXY_ROUTES    逗号分隔的路由，每项 `name` 或 `name=ENVVAR`，如
                      `catalog=MCP_CATALOG_URL,db`（后者等价于 DB_MCP_URL）。
                      写成 `name=ENVVAR` 是为了让上游变量名由调用方决定 ——
                      systemd 的 Environment= 不做变量展开，nix 没法把一个
                      已经渲染进 EnvironmentFile 的变量改名转发。
"""
from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request

TOKEN_FILE = os.environ.get(
    "MCP_TOKEN_FILE", os.path.expanduser("~/.local/state/mcp/token")
)
LISTEN_DEFAULT = "127.0.0.1:9100"
# 上游连接超时：SSE 长连接会一直读，所以只限制「建连 + 首字节」这一段。
CONNECT_TIMEOUT = 30.0
# 提前多少秒视为「该刷新了」：避免请求在路上过期的边界情况。
TOKEN_SKEW = 60.0
# 转发时剔掉的逐跳头：它们的语义只对单跳有效，原样透传会让下游误判。
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length",
        "authorization",
    }
)


def log(payload: dict) -> None:
    payload.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    print(json.dumps(payload, ensure_ascii=False), file=sys.stderr, flush=True)


def env_name(route: str) -> str:
    return route.upper().replace("-", "_") + "_MCP_URL"


def load_routes() -> dict[str, tuple[str, str, str]]:
    """返回 {route: (scheme, netloc, base_path)}，缺上游的路由直接跳过（不致命）。

    跳过而不是退出：同一份 nix 配置会铺到多台机器，某台没有配某个服务的
    端点（例如非集群网段的机器）时，其余路由仍然可用。
    """
    routes: dict[str, tuple[str, str, str]] = {}
    specs = [item.strip() for item in os.environ.get("MCP_PROXY_ROUTES", "").split(",") if item.strip()]
    for spec in specs:
        name, _, explicit = spec.partition("=")
        name = name.strip()
        source = explicit.strip() or env_name(name)
        if not name:
            continue
        raw = (os.environ.get(source) or "").strip()
        if not raw:
            log({"event": "route_skipped", "route": name, "reason": f"{source} 未设置"})
            continue
        parsed = urllib.parse.urlsplit(raw)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            log({"event": "route_skipped", "route": name, "reason": "上游不是 http(s) URL"})
            continue
        routes[name] = (parsed.scheme, parsed.netloc, parsed.path.rstrip("/"))
    return routes


def _read_raw() -> str:
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            return handle.read().strip()
    except FileNotFoundError:
        return ""
    except OSError as exc:
        log({"event": "token_read_failed", "detail": type(exc).__name__})
        return ""


def _write_token(payload: dict) -> None:
    tmp = f"{TOKEN_FILE}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.replace(tmp, TOKEN_FILE)


def _refresh(payload: dict) -> str:
    """用 refresh_token 换新的 access_token，成功则回写文件。

    为什么刷新在代理侧而不是客户端：客户端的 MCP 配置是静态的，没有位置跑刷新；
    放这里之后「1 小时过期」这件事对 agent 与用户都不可见。
    """
    endpoint = str(payload.get("token_endpoint") or "")
    refresh = str(payload.get("refresh_token") or "")
    client_id = str(payload.get("client_id") or "mcp")
    if not (endpoint and refresh):
        return ""
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": refresh, "client_id": client_id}
    ).encode()
    request = urllib.request.Request(endpoint, data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            token = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        log({"event": "refresh_failed", "detail": type(exc).__name__})
        return ""
    updated = {
        **payload,
        "access_token": token.get("access_token", ""),
        "refresh_token": token.get("refresh_token", refresh),
        "expires_at": int(time.time()) + int(token.get("expires_in", 3600)),
    }
    try:
        _write_token(updated)
    except OSError as exc:
        log({"event": "refresh_write_failed", "detail": type(exc).__name__})
    log({"event": "refreshed", "expires_in": token.get("expires_in")})
    return str(updated["access_token"])


def read_token() -> str:
    """返回可用的 access token。

    文件两种形态：JSON（Authelia 设备码流程，含 refresh）或裸串（OpenBao
    periodic token）。前者在剩余不足 60 秒时先刷新再返回。
    """
    raw = _read_raw()
    if not raw:
        return ""
    try:
        payload = json.loads(raw)
    except ValueError:
        return raw
    if not isinstance(payload, dict):
        return str(payload)
    access = str(payload.get("access_token") or "")
    if float(payload.get("expires_at") or 0) - time.time() > TOKEN_SKEW:
        return access
    return _refresh(payload) or access


class Handler:
    """把标准库的 BaseHTTPRequestHandler 拆成可测试的纯函数 + 薄壳。

    这里只放无状态逻辑（路径解析、头上过滤、响应形态），真正的 I/O 在 Server。
    """

    @staticmethod
    def split_path(path: str, routes: dict[str, tuple[str, str, str]]):
        """`/<route>/mcp[/...]` → (route, upstream_path)；不匹配返回 (None, None)。"""
        parsed = urllib.parse.urlsplit(path)
        segments = parsed.path.lstrip("/").split("/", 1)
        route = segments[0] if segments else ""
        if route not in routes:
            return None, None
        rest = "/" + (segments[1] if len(segments) > 1 and segments[1] else "mcp")
        base = routes[route][2]
        upstream_path = f"{base}{rest}"
        if parsed.query:
            upstream_path += f"?{parsed.query}"
        return route, upstream_path

    @staticmethod
    def forward_headers(raw_headers, token: str):
        """保留客户端的业务头，剔掉逐跳头与客户端自带的 Authorization。"""
        out = []
        for key, value in raw_headers:
            if key.lower() in HOP_BY_HOP:
                continue
            out.append((key, value))
        out.append(("Authorization", f"Bearer {token}"))
        return out

    @staticmethod
    def response_headers(raw_headers, has_length: bool):
        out = []
        for key, value in raw_headers:
            if key.lower() in HOP_BY_HOP:
                continue
            out.append((key, value))
        return out


def serve() -> int:
    listen = os.environ.get("MCP_PROXY_LISTEN", LISTEN_DEFAULT)
    host, _, port_text = listen.rpartition(":")
    host = host or "127.0.0.1"
    try:
        port = int(port_text)
    except ValueError:
        print(f"MCP_PROXY_LISTEN 不是 host:port：{listen!r}", file=sys.stderr)
        return 2

    routes = load_routes()
    if not routes:
        print("没有任何可用路由：检查 MCP_PROXY_ROUTES 与 <NAME>_MCP_URL", file=sys.stderr)
        return 2

    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class ProxyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "mcp-auth-proxy"

        def log_message(self, fmt, *args):  # 静音默认 access log
            return

        # —— 转发 ——
        def _handle(self, method: str) -> None:
            route, upstream_path = Handler.split_path(self.path, routes)
            if route is None:
                self._json(404, {"error": "unknown_route", "path": self.path})
                return
            token = read_token()
            if not token:
                self._json(
                    401,
                    {
                        "error": "token_missing",
                        "message": f"没有可用的 MCP token（{TOKEN_FILE}）",
                        "hint": "mcp-token login",
                    },
                )
                return

            scheme, netloc, _ = routes[route]
            body = None
            length = self.headers.get("Content-Length")
            if length:
                try:
                    body = self.rfile.read(int(length))
                except (ValueError, OSError):
                    self._json(400, {"error": "bad_body"})
                    return

            connection_cls = (
                http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            )
            headers = dict(Handler.forward_headers(self.headers.items(), token))
            try:
                conn = connection_cls(netloc, timeout=CONNECT_TIMEOUT)
                conn.request(method, upstream_path, body=body, headers=headers)
                upstream = conn.getresponse()
            except (OSError, http.client.HTTPException) as exc:
                log({"event": "upstream_error", "route": route, "detail": type(exc).__name__})
                self._json(502, {"error": "upstream_unreachable", "route": route})
                return

            length_header = upstream.getheader("Content-Length")
            self.send_response(upstream.status)
            for key, value in Handler.response_headers(upstream.getheaders(), length_header is not None):
                self.send_header(key, value)
            if length_header is not None:
                self.send_header("Content-Length", length_header)
                self.end_headers()
                self._pump(upstream, chunked=False)
            else:
                # SSE / 流式响应没有长度：用 chunked 边读边写，别把整段攒在内存里，
                # 也别指望客户端等到连接关闭才看到第一行。
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                self._pump(upstream, chunked=True)
            conn.close()

        def _pump(self, upstream, chunked: bool) -> None:
            try:
                while True:
                    chunk = upstream.read1(65536) if hasattr(upstream, "read1") else upstream.read(65536)
                    if not chunk:
                        break
                    if chunked:
                        self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            finally:
                if chunked:
                    try:
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass

        # MCP streamable HTTP 只用到这三个方法：POST 调工具、GET 订阅、DELETE 收会话。
        def do_POST(self):
            self._handle("POST")

        def do_GET(self):
            self._handle("GET")

        def do_DELETE(self):
            self._handle("DELETE")

        def _json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer((host, port), ProxyHandler)
    server.daemon_threads = True
    log({"event": "startup", "listen": f"{host}:{port}", "routes": sorted(routes), "token_file": TOKEN_FILE})
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI 入口：参数优先于环境变量（uvx / systemd 两种用法都覆盖）。"""
    import argparse

    parser = argparse.ArgumentParser(description="本地 MCP 凭证代理")
    parser.add_argument("--listen", help="监听地址，默认取 MCP_PROXY_LISTEN 或 127.0.0.1:9100")
    parser.add_argument(
        "--route",
        action="append",
        default=[],
        metavar="NAME[=ENVVAR]",
        help="路由，可重复；上游地址取 ENVVAR，缺省为 <NAME>_MCP_URL",
    )
    parser.add_argument("--token-file", help="token 文件路径")
    args = parser.parse_args(argv)
    if args.listen:
        os.environ["MCP_PROXY_LISTEN"] = args.listen
    if args.route:
        os.environ["MCP_PROXY_ROUTES"] = ",".join(args.route)
    if args.token_file:
        global TOKEN_FILE
        TOKEN_FILE = args.token_file
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())
