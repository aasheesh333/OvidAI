#!/usr/bin/env python3
"""Probe 3: is the recorded manifestDigest still valid for the installed content?

If Ovid gates contribution activation on `manifestDigest`, and the digest was
computed over the plugin content at approval time, then re-extracting the plugin
later invalidates the grant -> "not active in the current manifest for this
session".

We try a broad set of candidate digest inputs and look for the recorded value.
"""
import hashlib
import json
import os

CONTENT = ("/data/data/com.dhanuk.ovidai/app_flutter/plugin-runtime/"
           "jesse-vincent/superpowers/6.4.1/content")
RECORDED = "30fa7420ce17c4a7d3d3ff90b4982659b94bf6b2ee9243b54524c2c495b7d5eb"


def sha(b):
    if isinstance(b, str):
        b = b.encode()
    return hashlib.sha256(b).hexdigest()


def walk_files():
    out = []
    for root, dirs, files in os.walk(CONTENT):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            out.append((os.path.relpath(p, CONTENT), p))
    return sorted(out)


print("recorded digest:", RECORDED)
print("content dir exists:", os.path.isdir(CONTENT))
print()

files = walk_files()
print("files in content dir:", len(files))
print()

cands = {}

# 1. single-file digests
for rel, p in files:
    try:
        with open(p, "rb") as fh:
            cands[f"file:{rel}"] = sha(fh.read())
    except OSError:
        pass

# 2. concatenation of all file bytes, sorted by relpath
h = hashlib.sha256()
for rel, p in files:
    try:
        with open(p, "rb") as fh:
            h.update(fh.read())
    except OSError:
        pass
cands["concat-all-bytes"] = h.hexdigest()

# 3. "relpath\0sha256" manifest-style listing
h = hashlib.sha256()
for rel, p in files:
    try:
        with open(p, "rb") as fh:
            h.update(f"{rel}\0{sha(fh.read())}\n".encode())
    except OSError:
        pass
cands["listing:relpath+hash"] = h.hexdigest()

# 4. digests of parsed manifest objects
try:
    with open(os.path.join(CONTENT, "ovid-plugin.json")) as fh:
        man = json.load(fh)
    for label, kwargs in (
        ("manifest:sortkeys", {"sort_keys": True}),
        ("manifest:nosort", {}),
        ("manifest:sortkeys:compact", {"sort_keys": True, "separators": (",", ":")}),
        ("manifest:sortkeys:indent2", {"sort_keys": True, "indent": 2}),
    ):
        cands[label] = sha(json.dumps(man, **kwargs))
except Exception as e:
    print("manifest parse failed:", e)

try:
    with open(os.path.join(CONTENT, "ovid-activation.json")) as fh:
        act = json.load(fh)
    cands["activation:manifest:sortkeys"] = sha(
        json.dumps(act.get("manifest"), sort_keys=True))
    cands["activation:whole:sortkeys"] = sha(json.dumps(act, sort_keys=True))
except Exception as e:
    print("activation parse failed:", e)

print("candidate digests tried:", len(cands))
print()
hit = None
for label, d in sorted(cands.items()):
    mark = "  <<<< MATCH" if d == RECORDED else ""
    if mark:
        hit = label
    print(f"  {d[:16]}...  {label}{mark}")

print()
print("MATCH:", hit if hit else "none")
