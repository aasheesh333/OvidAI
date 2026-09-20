#!/usr/bin/env python3
"""Probe 4: reconstruct the pre-fix plugin bytes and re-test the recorded digest.

The only thing this session changed in the content dir was expanding
${CLAUDE_PLUGIN_ROOT}.  Reversing that gives back (approximately) the bytes that
existed when the grant was recorded.  If a candidate digest then matches, the
gate is content-based and the mismatch is explained.
"""
import hashlib
import json
import os

CONTENT = ("/data/data/com.dhanuk.ovidai/app_flutter/plugin-runtime/"
           "jesse-vincent/superpowers/6.4.1/content")
ROOT = "/data/user/0/com.dhanuk.ovidai/app_flutter/plugin-runtime/jesse-vincent/superpowers/6.4.1/content"
RECORDED = "30fa7420ce17c4a7d3d3ff90b4982659b94bf6b2ee9243b54524c2c495b7d5eb"


def sha(b):
    if isinstance(b, str):
        b = b.encode()
    return hashlib.sha256(b).hexdigest()


cands = {}

for rel in ("ovid-plugin.json", "ovid-activation.json", "hooks/hooks.json"):
    p = os.path.join(CONTENT, rel)
    if not os.path.exists(p):
        continue
    with open(p, "r", encoding="utf-8") as fh:
        cur = fh.read()
    rev = cur.replace(ROOT, "${CLAUDE_PLUGIN_ROOT}")
    cands[f"raw:{rel}:current"] = sha(cur)
    cands[f"raw:{rel}:reversed"] = sha(rev)
    try:
        j = json.loads(rev)
        cands[f"json:{rel}:sortkeys"] = sha(json.dumps(j, sort_keys=True))
        cands[f"json:{rel}:nosort"] = sha(json.dumps(j))
        cands[f"json:{rel}:compact"] = sha(json.dumps(j, sort_keys=True, separators=(",", ":")))
    except Exception:
        pass

# manifest variants without volatile fields
try:
    with open(os.path.join(CONTENT, "ovid-plugin.json")) as fh:
        man = json.load(fh)
    man_rev = json.loads(json.dumps(man).replace(ROOT, "${CLAUDE_PLUGIN_ROOT}"))
    for label, m in (("rev", man_rev), ("cur", man)):
        for drop in ([], ["rootPath"], ["rootPath", "unknownFields"]):
            d = {k: v for k, v in m.items() if k not in drop}
            cands[f"manifest:{label}:drop={drop or 'none'}:sortkeys"] = sha(
                json.dumps(d, sort_keys=True))
except Exception as e:
    print("manifest variant failed:", e)

# the source plugin descriptors
for rel in (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
            "package.json", "index.js"):
    p = os.path.join(CONTENT, rel)
    if os.path.exists(p):
        with open(p, "rb") as fh:
            cands[f"raw:{rel}"] = sha(fh.read())

print("recorded:", RECORDED)
print("tried:", len(cands))
print()
hit = None
for label, d in sorted(cands.items()):
    if d == RECORDED:
        hit = label
        print(f"  MATCH  {d}  {label}")
print()
print("MATCH:", hit if hit else "none")
print()
print("sample (first 12):")
for label, d in sorted(cands.items())[:12]:
    print(f"  {d[:16]}...  {label}")
