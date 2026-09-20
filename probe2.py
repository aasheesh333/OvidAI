#!/usr/bin/env python3
"""Second probe: grants, custom plugins, MCP connection state, activation detail."""
import json
import xml.etree.ElementTree as ET

PREFS = "/data/data/com.dhanuk.ovidai/shared_prefs/FlutterSharedPreferences.xml"
root = ET.parse(PREFS).getroot()
vals = {}
for c in root:
    n = c.get("name")
    if n:
        vals[n] = c.text or ""

for k in (
    "flutter.ovid_plugin_grants_v1",
    "flutter.ovid_custom_plugins_v1",
    "flutter.ovid_plugin_rows_v2",
    "flutter.ovid_custom_mcp_servers_v1",
    "flutter.ovid_mcp_connected_v1",
    "flutter.ovid_active_runs_v1",
    "flutter.ovid_active_session",
):
    v = vals.get(k, "<missing>")
    print("=" * 60)
    print(k)
    print("=" * 60)
    print(v[:900])
    print()

print("=" * 60)
print("ACTIVATION (structure only)")
print("=" * 60)
a = vals.get("flutter.ovid_plugin_activation_v1", "")
try:
    j = json.loads(a)
    for pid, raw in j.items():
        d = json.loads(raw)
        act = d.get("activation", {})
        man = d.get("manifest", {})
        print("plugin:", pid)
        print("  activation:", json.dumps(act, indent=2))
        print("  manifest keys:", list(man.keys()))
        for f in ("id", "name", "version", "format", "rootPath"):
            print(f"    {f}: {man.get(f)!r}")
        print("    skills:", len(man.get("skills", [])),
              "hooks:", len(man.get("hooks", [])),
              "mcpServers:", len(man.get("mcpServers", [])),
              "commands:", len(man.get("commands", [])),
              "agents:", len(man.get("agents", [])))
except Exception as e:
    print("parse failed:", e)
