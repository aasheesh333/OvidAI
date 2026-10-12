#!/usr/bin/env python3
"""Verify prompt caching through an OpenAI-format gateway (e.g. LiteLLM).

Sends the same long (>4k tokens) prefix twice with a cache_control marker and
prints cache_creation / cache_read tokens and the cost delta between calls.

  OVID_BASE_URL=https://api.example.com/v1 OVID_API_KEY=sk-... \\
    python3 verify_cache.py --model claude-sonnet-4.6 [--ttl 1h]

No secrets are stored here: base URL and key come from args or env.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# Fallback USD/MTok list prices (input, output) used only when the server does
# not return a cost header. Server/LiteLLM spend stays authoritative.
PRICES = {"opus": (15, 75), "sonnet": (3, 15), "haiku": (0.8, 4)}


def build_prefix(words: int) -> str:
    # Deterministic filler: identical bytes on both calls.
    return " ".join(f"token{i % 997}" for i in range(words))


def call(base, key, model, prefix, question, ttl):
    cc = {"type": "ephemeral"}
    if ttl == "1h":
        cc["ttl"] = "1h"
    body = {
        "model": model,
        "max_tokens": 16,
        "messages": [
            {
                "role": "system",
                "content": [
                    {"type": "text", "text": prefix, "cache_control": cc}
                ],
            },
            {"role": "user", "content": question},
        ],
    }
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.load(r)
            headers = dict(r.headers)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
    return data, headers


def cache_fields(usage):
    d = usage.get("prompt_tokens_details") or {}
    read = (
        usage.get("cache_read_input_tokens")
        or d.get("cached_tokens")
        or 0
    )
    write = (
        usage.get("cache_creation_input_tokens")
        or d.get("cache_write_tokens")
        or d.get("cache_creation_tokens")
        or 0
    )
    return read, write


def est_cost(model, usage, read, write, ttl):
    fam = next((k for k in PRICES if k in model.lower()), None)
    if not fam:
        return None
    pin, pout = PRICES[fam]
    prompt = usage.get("prompt_tokens", 0)
    fresh = max(prompt - read - write, 0)
    wm = 2.0 if ttl == "1h" else 1.25
    inp = (fresh + read * 0.1 + write * wm) / 1e6 * pin
    return inp + usage.get("completion_tokens", 0) / 1e6 * pout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", default=os.environ.get("OVID_BASE_URL"))
    ap.add_argument("--api-key", default=os.environ.get("OVID_API_KEY"))
    ap.add_argument("--model", required=True)
    ap.add_argument("--ttl", choices=["5m", "1h"], default="5m")
    ap.add_argument("--words", type=int, default=6000,
                    help="prefix size in words (~1.3 tokens each; >4k tokens)")
    ap.add_argument("--delay", type=float, default=2.0,
                    help="seconds between the two calls")
    a = ap.parse_args()
    if not a.base_url or not a.api_key:
        sys.exit("need --base-url/--api-key or OVID_BASE_URL/OVID_API_KEY")

    prefix = build_prefix(a.words)
    rows = []
    for i, q in enumerate(["Reply with the word one.", "Reply with the word two."]):
        data, headers = call(a.base_url, a.api_key, a.model, prefix, q, a.ttl)
        u = data.get("usage") or {}
        read, write = cache_fields(u)
        hdr_cost = headers.get("x-litellm-response-cost")
        cost = float(hdr_cost) if hdr_cost else est_cost(a.model, u, read, write, a.ttl)
        rows.append((u.get("prompt_tokens", 0), write, read, cost, bool(hdr_cost)))
        print(
            f"call {i + 1}: prompt={rows[-1][0]} cache_creation={write} "
            f"cache_read={read} cost={'n/a' if cost is None else f'${cost:.6f}'}"
            f"{' (server)' if hdr_cost else ' (estimate)' if cost is not None else ''}"
        )
        if i == 0:
            time.sleep(a.delay)

    (_, w1, r1, c1, _), (p2, w2, r2, c2, _) = rows
    if c1 is not None and c2 is not None and c1 > 0:
        print(f"cost delta: ${c2 - c1:+.6f} ({(c2 / c1 - 1) * 100:+.0f}%)")
    if r2 > 0:
        print(f"PASS: second call read {r2} tokens from cache "
              f"({r2 / max(p2, 1) * 100:.0f}% of input)")
        return 0
    print("FAIL: no cache read on the second call. Check that the model is "
          "Claude, the prefix is above the provider minimum (1024-4096 "
          "tokens) and that cache_control reaches the provider.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
