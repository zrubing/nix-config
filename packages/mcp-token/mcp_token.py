#!/usr/bin/env python3
"""mcp-token —— MCP 家族的凭据：一次授权，之后自动续期。

为什么是设备码流程（而不是浏览器回环回调）：
  OpenBao 的 CLI 登录把回调固定在 `http://localhost:8250/oidc/callback`，
  于是「在哪台机器登录，浏览器就得在那台机器上」—— 没有桌面的机器（nova13）
  或手机根本完不成授权。Authelia 的 device_code 授权把「确认」和「回调」解耦：
  任意设备打开 URL 确认，进程侧只轮询，跟机器无关。

文件格式（0600）：

    {"access_token": "...", "refresh_token": "...", "expires_at": 1730000000,
     "token_endpoint": "https://authelia.hinihao.net/api/oidc/token",
     "client_id": "mcp"}

`expires_at` 由本工具算好，代理据此判断是否需要刷新；刷新在代理侧做
（见 packages/mcp-auth-proxy/proxy.py），所以 agent 与用户都不用管 1 小时过期。

兼容：文件里若是一个裸字符串（`hvs.…` 的 OpenBao periodic token），原样使用 ——
那条路径留给 CI / 无人值守场景。
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ISSUER = os.environ.get("MCP_AUTH_ISSUER", "https://authelia.hinihao.net")
CLIENT_ID = os.environ.get("MCP_CLIENT_ID", "mcp")
SCOPE = os.environ.get("MCP_SCOPE", "openid profile email groups offline_access")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "mcp")
TOKEN_FILE = os.environ.get("MCP_TOKEN_FILE", os.path.join(STATE_DIR, "token"))


def http_json(url: str, data: dict | None = None) -> dict:
    body = None if data is None else urllib.parse.urlencode(data).encode()
    request = urllib.request.Request(url, data=body, method="GET" if data is None else "POST")
    if body is not None:
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.add_header("Accept", "application/json")
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode())


def discovery() -> dict:
    return http_json(f"{ISSUER.rstrip('/')}/.well-known/openid-configuration")


def write_token(payload: dict) -> None:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = f"{TOKEN_FILE}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.replace(tmp, TOKEN_FILE)
    os.chmod(TOKEN_FILE, 0o600)


def read_token() -> dict | str | None:
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            raw = handle.read().strip()
    except FileNotFoundError:
        return None
    except OSError:
        return None
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def cmd_login() -> int:
    meta = discovery()
    device_endpoint = meta["device_authorization_endpoint"]
    token_endpoint = meta["token_endpoint"]
    start = http_json(
        device_endpoint,
        {"client_id": CLIENT_ID, "scope": SCOPE, "audience": meta.get("issuer", ISSUER)},
    )
    verify = start.get("verification_uri_complete") or start.get("verification_uri")
    code = start.get("user_code", "")
    print(f"在你的任意设备打开（手机也可以）：\n  {verify}\n确认码：{code}\n", flush=True)
    interval = max(2, int(start.get("interval", 5)))
    deadline = time.time() + int(start.get("expires_in", 300))
    while time.time() < deadline:
        time.sleep(interval)
        try:
            token = http_json(
                token_endpoint,
                {
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": start["device_code"],
                    "client_id": CLIENT_ID,
                },
            )
        except urllib.error.HTTPError as exc:
            detail = json.loads(exc.read() or b"{}")
            error = detail.get("error")
            if error == "authorization_pending":
                continue
            if error == "slow_down":
                interval += 2
                continue
            print(f"授权失败：{error or exc.code}", file=sys.stderr)
            return 1
        payload = {
            "access_token": token["access_token"],
            "refresh_token": token.get("refresh_token", ""),
            "expires_at": int(time.time()) + int(token.get("expires_in", 3600)),
            "token_endpoint": token_endpoint,
            "client_id": CLIENT_ID,
        }
        write_token(payload)
        print(f"已写入 {TOKEN_FILE}（有效期 {token.get('expires_in', 3600)}s，之后由代理自动刷新）")
        return 0
    print("授权超时：请重新运行 mcp-token login", file=sys.stderr)
    return 1


def cmd_status() -> int:
    token = read_token()
    if token is None:
        print(f"missing {TOKEN_FILE}（跑 mcp-token login）")
        return 1
    if isinstance(token, str):
        print(f"present {TOKEN_FILE} 类型=OpenBao token（裸串，无过期信息）")
        return 0
    left = int(token.get("expires_at", 0) - time.time())
    kind = "有效" if left > 0 else "已过期（代理会自动刷新）"
    print(f"present {TOKEN_FILE} {kind} 剩余={left}s refresh={'有' if token.get('refresh_token') else '无'}")
    return 0


def cmd_show() -> int:
    token = read_token()
    if token is None:
        print("没有 token：先跑 mcp-token login", file=sys.stderr)
        return 1
    print(token if isinstance(token, str) else token.get("access_token", ""))
    return 0


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    if command == "login":
        return cmd_login()
    if command == "status":
        return cmd_status()
    if command == "show":
        return cmd_show()
    if command == "path":
        print(TOKEN_FILE)
        return 0
    print(__doc__)
    return 0 if command in ("-h", "--help", "help") else 2


if __name__ == "__main__":
    raise SystemExit(main())
