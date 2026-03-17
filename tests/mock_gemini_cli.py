#!/usr/bin/env python3
"""
Mock Gemini CLI for gemini-code.nvim integration testing.

Behaves like the real Gemini CLI:
  1. Reads GEMINI_CLI_IDE_SERVER_PORT from the environment (set by terminal.lua)
  2. Globs /tmp/gemini/ide/ for the discovery JSON and extracts the auth token
  3. Sends MCP initialize + tools/list handshake
  4. Shows an interactive menu to exercise openDiff, closeDiff, and context

No third-party dependencies — stdlib only (http.client, json, glob, os).
"""

import glob
import http.client
import json
import os
import sys
import tempfile
import textwrap
import time

# ── Discovery ─────────────────────────────────────────────────────────────────

def discover(port: int) -> str:
    """
    Glob the discovery directory for the JSON file matching *port* and return
    the authToken.  Retries for up to 5 seconds in case Neovim is still
    writing the file.
    """
    pattern = f"/tmp/gemini/ide/gemini-ide-server-*-{port}.json"
    for attempt in range(10):
        files = glob.glob(pattern)
        if files:
            with open(files[0]) as fh:
                data = json.load(fh)
            return data["authToken"]
        if attempt == 0:
            print(f"  Waiting for discovery file ({pattern}) …", flush=True)
        time.sleep(0.5)
    raise RuntimeError(
        f"Discovery file not found after 5 s: {pattern}\n"
        "Is the plugin running? Try :GeminiCode first."
    )

# ── HTTP / MCP helpers ────────────────────────────────────────────────────────

_req_id = 0

def _next_id() -> int:
    global _req_id
    _req_id += 1
    return _req_id


def post_mcp(port: int, token: str, method: str, params: dict | None = None) -> dict:
    """
    Send a single JSON-RPC 2.0 POST to /mcp and return the parsed response
    body.  Opens a fresh TCP connection per call (matching the HTTP/1.1
    per-request model used by the plugin).
    """
    body = json.dumps({
        "jsonrpc": "2.0",
        "id":      _next_id(),
        "method":  method,
        "params":  params or {},
    }).encode()

    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.request("POST", "/mcp", body, {
        "Content-Type":   "application/json",
        "Authorization":  f"Bearer {token}",
        "Content-Length": str(len(body)),
    })
    resp = conn.getresponse()
    raw  = resp.read()
    conn.close()

    if not raw:
        return {}
    return json.loads(raw)


def drain_notifications(port: int, token: str,
                        timeout: float = 30.0,
                        poll_interval: float = 0.5) -> list[dict]:
    """
    Poll the server (via tools/list, which is cheap) until at least one
    notification arrives in the piggyback 'notifications' field, or until
    *timeout* seconds elapse.

    Returns the list of notification dicts that were collected.
    """
    deadline = time.monotonic() + timeout
    collected: list[dict] = []

    while time.monotonic() < deadline:
        resp = post_mcp(port, token, "tools/list")
        notifs = resp.get("notifications") or []
        if notifs:
            collected.extend(notifs)
            # Keep polling briefly to collect any further notifications
            # (e.g. if multiple arrive in quick succession)
            extra_deadline = time.monotonic() + 1.0
            while time.monotonic() < extra_deadline:
                resp2 = post_mcp(port, token, "tools/list")
                more  = resp2.get("notifications") or []
                if not more:
                    break
                collected.extend(more)
            return collected
        time.sleep(poll_interval)

    return collected   # empty → timed out

# ── Context display ───────────────────────────────────────────────────────────

_last_context: dict | None = None


def check_context(port: int, token: str) -> None:
    """
    The plugin PUSHES context via ide/contextUpdate notifications piggybacked
    on responses.  We fire a cheap tools/list to flush any queued ones.
    """
    resp  = post_mcp(port, token, "tools/list")
    notifs = resp.get("notifications") or []
    for n in notifs:
        if n.get("method") == "ide/contextUpdate":
            global _last_context
            _last_context = n.get("params", {})

    if _last_context is None:
        print("  (no ide/contextUpdate received yet — move the cursor or open a file)")
        return

    ctx = _last_context
    files = ctx.get("openFiles") or ctx.get("files") or []
    cursor = ctx.get("cursor") or {}
    selection = ctx.get("selection") or ctx.get("selectedText") or ""

    print(f"  Open files   : {files if files else '(none)'}")
    if cursor:
        print(f"  Cursor       : {cursor}")
    if selection:
        preview = selection[:120].replace("\n", "\\n")
        print(f"  Selection    : {preview!r}")

# ── Demo diff content ─────────────────────────────────────────────────────────

ORIGINAL = textwrap.dedent("""\
    # Integration test file
    # This file is used by the mock Gemini CLI to demo openDiff.

    def greet(name):
        print("Hello, " + name)

    greet("world")
""")

PROPOSED = textwrap.dedent("""\
    # Integration test file
    # This file is used by the mock Gemini CLI to demo openDiff.

    def greet(name: str) -> None:
        \"\"\"Greet someone by name.\"\"\"
        print(f"Hello, {name}!")

    if __name__ == "__main__":
        greet("world")
""")

# ── Menu ──────────────────────────────────────────────────────────────────────

def print_banner(port: int) -> None:
    print()
    print("╔══════════════════════════════════════╗")
    print("║   gemini-code.nvim  mock CLI         ║")
    print(f"║   Connected to port {port:<16} ║")
    print("╚══════════════════════════════════════╝")
    print()


def print_menu() -> None:
    print("  1) Open diff  (propose a file change)")
    print("  2) Context    (show last ide/contextUpdate)")
    print("  3) Close diff (programmatic closeDiff)")
    print("  4) Quit")
    print()


_diff_file: str | None = None   # path of the temp file used for openDiff


def do_open_diff(port: int, token: str) -> None:
    global _diff_file

    # Create / reuse a temp file so closeDiff has a stable path
    if _diff_file is None:
        fd, _diff_file = tempfile.mkstemp(suffix=".py", prefix="gemini_mock_")
        os.close(fd)

    # Write the original content so Neovim shows a real diff
    with open(_diff_file, "w") as fh:
        fh.write(ORIGINAL)

    print(f"  Test file    : {_diff_file}")
    print("  Sending openDiff …")

    resp = post_mcp(port, token, "tools/call", {
        "name": "openDiff",
        "arguments": {
            "filePath":   _diff_file,
            "newContent": PROPOSED,
        },
    })

    rpc_err = resp.get("error")
    if rpc_err:
        print(f"  ERROR: {rpc_err}")
        return

    print("  Diff view opened in Neovim!")
    print()
    print("  → Accept : <leader>da  or  :GeminiCodeDiffAccept")
    print("  → Reject : <leader>dr  or  :GeminiCodeDiffDeny")
    print()
    print("  Waiting for your choice (up to 30 s) …", flush=True)

    notifs = drain_notifications(port, token, timeout=30.0)
    if not notifs:
        print("  (timed out — no response received)")
        return

    for n in notifs:
        method = n.get("method", "")
        params = n.get("params", {})
        if method == "ide/diffAccepted":
            content = params.get("content", "")
            print(f"  ✓ Accepted! Final content ({len(content)} chars):")
            for line in content.splitlines()[:6]:
                print(f"    {line}")
            if len(content.splitlines()) > 6:
                print("    …")
        elif method == "ide/diffRejected":
            print("  ✗ Rejected.")
        else:
            print(f"  Notification: {method} {params}")


def do_close_diff(port: int, token: str) -> None:
    global _diff_file

    if _diff_file is None:
        print("  No diff has been opened yet — use option 1 first.")
        return

    print(f"  Sending closeDiff for {_diff_file} …")
    resp = post_mcp(port, token, "tools/call", {
        "name": "closeDiff",
        "arguments": {"filePath": _diff_file},
    })

    rpc_err = resp.get("error")
    if rpc_err:
        print(f"  ERROR: {rpc_err}")
        return

    result  = (resp.get("result") or {})
    content_list = result.get("content") or []
    if content_list:
        text = content_list[0].get("text", "")
        print(f"  Final content ({len(text)} chars):")
        for line in text.splitlines()[:6]:
            print(f"    {line}")
        if len(text.splitlines()) > 6:
            print("    …")
    else:
        print("  (no active diff for that file, or diff was already closed)")


# ── Handshake ─────────────────────────────────────────────────────────────────

def handshake(port: int, token: str) -> None:
    print("  Sending initialize …", end=" ", flush=True)
    resp = post_mcp(port, token, "initialize", {
        "protocolVersion": "2024-11-05",
        "clientInfo": {"name": "mock-gemini-cli", "version": "0.1.0"},
        "capabilities": {},
    })
    server_info = (resp.get("result") or {}).get("serverInfo", {})
    print(f"OK  ({server_info.get('name', '?')} {server_info.get('version', '')})")

    print("  Sending tools/list …", end=" ", flush=True)
    resp = post_mcp(port, token, "tools/list")
    tools = (resp.get("result") or {}).get("tools") or []
    names = [t.get("name") for t in tools]
    print(f"OK  (tools: {names})")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    port_str = os.environ.get("GEMINI_CLI_IDE_SERVER_PORT", "")
    if not port_str:
        sys.exit(
            "ERROR: GEMINI_CLI_IDE_SERVER_PORT is not set.\n"
            "Launch this script via :GeminiCode (or :GeminiCodeAutoEdit),\n"
            "not directly from a shell."
        )

    port = int(port_str)

    try:
        print(f"\n  Discovering auth token for port {port} …", flush=True)
        token = discover(port)
        print(f"  Auth token   : {token[:8]}…")
        handshake(port, token)
    except Exception as exc:
        sys.exit(f"ERROR during startup: {exc}")

    print_banner(port)

    while True:
        print_menu()
        try:
            choice = input("  > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  Bye!")
            break

        print()
        try:
            if choice == "1":
                do_open_diff(port, token)
            elif choice == "2":
                check_context(port, token)
            elif choice == "3":
                do_close_diff(port, token)
            elif choice == "4":
                print("  Bye!")
                break
            else:
                print("  Unknown option.")
        except Exception as exc:
            print(f"  ERROR: {exc}")
        print()


if __name__ == "__main__":
    main()
