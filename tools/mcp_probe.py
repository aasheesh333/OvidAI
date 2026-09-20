#!/usr/bin/env python3
"""
mcp_probe.py — drive a real MCP stdio server through the Ovid sandbox.

Starts the server exactly the way lib/core/mcp_service.dart does
(`npx -y <package> <args>`) and performs a real JSON-RPC 2.0 handshake:

    initialize -> notifications/initialized -> tools/list

Exits 0 only if the server answers `initialize` with a serverInfo block.

Usage:
    python3 tools/mcp_probe.py
    python3 tools/mcp_probe.py @modelcontextprotocol/server-memory /tmp/ws
"""
import json
import os
import subprocess
import sys
import threading
import time

BIN = "/data/data/com.dhanuk.ovidai/files/sandbox/bin"
SANDBOX_ROOT = os.path.dirname(BIN)


def main():
    pkg = sys.argv[1] if len(sys.argv) > 1 else "@modelcontextprotocol/server-filesystem"
    extra = sys.argv[2:] or [os.getcwd()]

    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env.get("PATH", "")
    env["PREFIX"] = SANDBOX_ROOT
    env["HOME"] = os.path.join(SANDBOX_ROOT, "home")
    env.setdefault("TMPDIR", os.path.join(SANDBOX_ROOT, "tmp"))
    env["npm_config_update_notifier"] = "false"

    cmd = [os.path.join(BIN, "npx"), "-y", pkg] + extra
    print(f"$ {' '.join(cmd)}")

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )

    stderr_buf = []

    def drain():
        for line in proc.stderr:
            stderr_buf.append(line.rstrip())
            if len(stderr_buf) > 40:
                stderr_buf.pop(0)

    threading.Thread(target=drain, daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "ovid-probe", "version": "1.0"},
        },
    })

    reply = None
    deadline = time.time() + 180
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("id") == 1:
            reply = msg
            break

    if reply is None:
        print("FAIL: no initialize reply")
        print("--- stderr ---")
        for l in stderr_buf[-25:]:
            print("  " + l)
        proc.kill()
        return 1

    info = reply.get("result", {}).get("serverInfo", {})
    print(f"OK: initialize -> {info.get('name')} {info.get('version')}")

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})

    deadline = time.time() + 60
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        try:
            msg = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        if msg.get("id") == 2:
            tools = msg.get("result", {}).get("tools", [])
            names = [t.get("name") for t in tools]
            print(f"OK: tools/list -> {len(names)} tools: {names[:6]}")
            break

    proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
