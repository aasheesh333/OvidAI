#!/usr/bin/env python3
"""Poll GitHub Actions until the newest Build Ovid APK run finishes."""
import json
import subprocess
import sys
import time

REPO = "aasheesh333/OvidAI"
RUN_ID = sys.argv[1] if len(sys.argv) > 1 else None


def api(path):
    out = subprocess.run(
        ["curl", "-s", "-m", "30", f"https://api.github.com/repos/{REPO}/{path}"],
        capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


if not RUN_ID:
    runs = api("actions/runs?per_page=1").get("workflow_runs", [])
    if not runs:
        print("no runs found")
        sys.exit(1)
    RUN_ID = runs[0]["id"]

print(f"monitoring run {RUN_ID}")
deadline = time.time() + 3600
last = None
while time.time() < deadline:
    r = api(f"actions/runs/{RUN_ID}")
    st = r.get("status")
    cc = r.get("conclusion")
    line = f"status={st} conclusion={cc}"
    if line != last:
        print(f"[{time.strftime('%H:%M:%S')}] {line}", flush=True)
        last = line
    if st == "completed":
        print(f"\nFINAL: {cc}")
        print(f"url: {r.get('html_url')}")
        jobs = api(f"actions/runs/{RUN_ID}/jobs").get("jobs", [])
        for j in jobs:
            print(f"\njob: {j['name']} -> {j['conclusion']}")
            for s in j.get("steps", []):
                print(f"   {s['conclusion'] or s['status']:<12} {s['name']}")
        sys.exit(0 if cc == "success" else 1)
    time.sleep(20)

print("timed out")
sys.exit(2)
