#!/usr/bin/env python3
"""Probe Ovid's plugin/session-manifest state to find why `skill` is rejected.

Prints only small, targeted slices so the tool output stays bounded.
"""
import json
import xml.etree.ElementTree as ET

PREFS = "/data/data/com.dhanuk.ovidai/shared_prefs/FlutterSharedPreferences.xml"
root = ET.parse(PREFS).getroot()

vals = {}
for c in root:
    n = c.get("name")
    if n:
        vals[n] = c.text or ""

print("total prefs:", len(vals))
print()

for k in sorted(vals):
    if any(w in k.lower() for w in ("plugin", "manifest", "skill", "activ", "mcp")):
        v = vals[k]
        print(f"{k}  len={len(v)}")
print()

# boot epoch
print("=== boot epoch ===")
print(repr(vals.get("flutter.ovid_plugin_boot_epoch_v1"))[:200])
print()

# runtime status
print("=== runtime status (first 400) ===")
print(vals.get("flutter.ovid_plugin_runtime_status_v1", "")[:400])
print()

# bootstrap
b = vals.get("flutter.ovid_session_bootstrap_v1")
print("=== bootstrap ===")
print("len:", len(b) if b else 0)
try:
    j = json.loads(b)
except Exception as e:
    print("parse failed:", e)
    raise SystemExit(0)

print("top keys:", list(j.keys()))
s = j.get("session", {})
print("session keys:", list(s.keys()))

def scan(prefix, d):
    for k in d:
        kl = k.lower()
        if any(w in kl for w in ("plugin", "manifest", "skill", "activ")):
            val = d[k]
            txt = str(val)
            print(f"  HIT {prefix}{k}: len={len(txt)} :: {txt[:300]}")

scan("session.", s)
for k in j:
    if k != "session":
        scan("top.", {k: j[k]})

# the system prompt snapshot should list the skills Ovid advertises
sp = s.get("systemPromptSnapshot", "")
print()
print("systemPromptSnapshot len:", len(sp))
for needle in ("superpowers", "AVAILABLE SKILLS", "plugin:"):
    print(f"  contains {needle!r}:", needle in sp)

# how many tool entries mention skill
print("todos:", len(s.get("todos", [])))
print("messages:", len(s.get("messages", [])))
