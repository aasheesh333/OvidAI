"""Test harness for server/mint/mint.py.

No network, no Redis server, no LiteLLM: Redis is fakeredis when installed,
else a small in-memory stub; LiteLLM is an httpx.MockTransport fake.
"""
import datetime
import fnmatch
import importlib
import json
import os
import sys
from pathlib import Path

import httpx
import pytest

MINT_DIR = Path(__file__).resolve().parents[1]
MASTER = "test-master-key"


class MemoryRedis:
    """The subset of redis-py (decode_responses=True) mint uses."""

    def __init__(self):
        self.kv, self.sets, self.hashes, self.lists = {}, {}, {}, {}

    def get(self, k):
        return self.kv.get(k)

    def set(self, k, v, nx=False, ex=None):
        if nx and k in self.kv:
            return None
        self.kv[k] = str(v)
        return True

    def setex(self, k, ttl, v):
        self.kv[k] = str(v)
        return True

    def delete(self, *keys):
        n = 0
        for k in keys:
            for store in (self.kv, self.sets, self.hashes, self.lists):
                if k in store:
                    del store[k]
                    n += 1
        return n

    def exists(self, *keys):
        return sum(1 for k in keys if any(k in s for s in (self.kv, self.sets, self.hashes, self.lists)))

    def incrbyfloat(self, k, amount):
        self.kv[k] = repr(float(self.kv.get(k, 0)) + float(amount))
        return float(self.kv[k])

    def srem(self, k, *vals):
        s = self.sets.get(k, set())
        n = len(s & set(vals))
        s.difference_update(vals)
        return n

    def hdel(self, k, *fields):
        h = self.hashes.get(k, {})
        n = 0
        for f in fields:
            if f in h:
                del h[f]
                n += 1
        return n

    def incr(self, k):
        self.kv[k] = str(int(self.kv.get(k, 0)) + 1)
        return int(self.kv[k])

    def expire(self, k, ttl):
        return True

    def sadd(self, k, *vals):
        s = self.sets.setdefault(k, set())
        before = len(s)
        s.update(str(v) for v in vals)
        return len(s) - before

    def smembers(self, k):
        return set(self.sets.get(k, set()))

    def sismember(self, k, v):
        return v in self.sets.get(k, set())

    def scard(self, k):
        return len(self.sets.get(k, set()))

    def hget(self, k, f):
        return self.hashes.get(k, {}).get(f)

    def hset(self, k, key=None, value=None, mapping=None):
        h = self.hashes.setdefault(k, {})
        if key is not None:
            h[key] = str(value)
        for f, v in (mapping or {}).items():
            h[f] = str(v)
        return 1

    def hincrby(self, k, f, n=1):
        h = self.hashes.setdefault(k, {})
        h[f] = str(int(h.get(f, 0)) + int(n))
        return int(h[f])

    def hgetall(self, k):
        return dict(self.hashes.get(k, {}))

    def lpush(self, k, *vals):
        lst = self.lists.setdefault(k, [])
        for v in vals:
            lst.insert(0, v)
        return len(lst)

    def ltrim(self, k, start, end):
        lst = self.lists.get(k, [])
        self.lists[k] = lst[start:end + 1]
        return True

    def lrange(self, k, start, end):
        lst = self.lists.get(k, [])
        return lst[start:None if end == -1 else end + 1]

    def scan_iter(self, match="*"):
        for k in list(self.kv):
            if fnmatch.fnmatch(k, match):
                yield k


class AsyncRedis:
    """Async facade over a sync fake (what the LiteLLM hook uses)."""

    def __init__(self, sync, fail=False):
        self.sync, self.fail = sync, fail

    def __getattr__(self, name):
        fn = getattr(self.sync, name)

        async def call(*a, **kw):
            if self.fail:
                raise ConnectionError("redis down")
            return fn(*a, **kw)
        return call


def make_redis():
    try:
        import fakeredis  # type: ignore
        return fakeredis.FakeRedis(decode_responses=True)
    except ImportError:
        return MemoryRedis()


def iso(t):
    return t.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


class FakeLiteLLM:
    """Just enough of the LiteLLM admin API, with call recording."""

    def __init__(self):
        self.keys = {}       # token -> info
        self.users = {}      # uid -> user_info
        self.models = []     # /model/info data
        self.logs = []       # spend log rows
        self.calls = []      # (method, path, params/json)
        self.n = 0

    # helpers for tests
    def add_key(self, token, spend=0.0, max_budget=None, duration="24h", reset_in_h=10):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.keys[token] = {"token": token, "spend": spend, "max_budget": max_budget,
                            "budget_duration": duration, "blocked": False,
                            "budget_reset_at": iso(now + datetime.timedelta(hours=reset_in_h))}
        return token

    def add_model(self, name, under, inp=None, out=None, per_image=None, mode=None, mid=None):
        info = {"id": mid or f"dep-{len(self.models)}"}
        if inp is not None:
            info["input_cost_per_token"] = inp
        if out is not None:
            info["output_cost_per_token"] = out
        if per_image is not None:
            info["output_cost_per_image"] = per_image
        if mode:
            info["mode"] = mode
        self.models.append({"model_name": name, "litellm_params": {"model": under}, "model_info": info})

    def add_log(self, token, model, group=None, pin=100, pout=50, spend=0.001, call_type="acompletion",
                ago_min=5, status="success", model_id=None):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.logs.append({"api_key": token, "model": model, "model_group": group, "prompt_tokens": pin,
                          "completion_tokens": pout, "spend": spend, "call_type": call_type,
                          "startTime": iso(now - datetime.timedelta(minutes=ago_min)),
                          "status": status, "model_id": model_id})

    def posts(self, path):
        return [b for (m, p, b) in self.calls if m == "POST" and p == path]

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.headers.get("authorization") != f"Bearer {MASTER}":
            return httpx.Response(401, json={"error": "auth"})
        path = request.url.path
        params = dict(request.url.params)
        body = json.loads(request.content) if request.content else {}
        self.calls.append((request.method, path, body or params))
        if path == "/key/info":
            info = self.keys.get(params.get("key"))
            return httpx.Response(200, json={"key": params.get("key"), "info": info}) if info \
                else httpx.Response(404, json={"error": "nf"})
        if path == "/key/update":
            info = self.keys.get(body["key"])
            if not info:
                return httpx.Response(404, json={})
            for f in ("max_budget", "budget_duration", "spend"):
                if f in body:
                    info[f] = body[f]
            return httpx.Response(200, json=info)
        if path in ("/key/block", "/key/unblock"):
            self.keys[body["key"]]["blocked"] = path == "/key/block"
            return httpx.Response(200, json={})
        if path == "/key/generate":
            self.n += 1
            tok = f"hashed-{self.n}"
            self.add_key(tok, max_budget=body.get("max_budget"), duration=body.get("budget_duration"))
            return httpx.Response(200, json={"key": f"sk-live-{self.n}", "token": tok})
        if path == "/user/info":
            u = self.users.get(params.get("user_id"))
            return httpx.Response(200, json={"user_info": u}) if u else httpx.Response(404, json={})
        if path == "/user/update":
            u = self.users.setdefault(body["user_id"], {"spend": 0.0})
            for f in ("max_budget", "budget_duration", "spend"):
                if f in body:
                    u[f] = body[f]
            return httpx.Response(200, json=u)
        if path == "/model/info":
            return httpx.Response(200, json={"data": self.models})
        if path == "/spend/logs":
            rows = [r for r in self.logs if r["api_key"] == params.get("api_key")]
            return httpx.Response(200, json=rows)
        if path in ("/team/new", "/team/update"):
            return httpx.Response(200, json={"team_id": "team-web"})
        return httpx.Response(404, json={"error": path})


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("FIREBASE_PROJECT_ID", "test-project")
    monkeypatch.setenv("LITELLM_MASTER_KEY", MASTER)
    monkeypatch.setenv("MINT_SPEND_MONITOR", "false")
    monkeypatch.setenv("MINT_MOUNT_IMAGES", "false")
    monkeypatch.setenv("USAGE_CACHE_S", "0")
    monkeypatch.setenv("MINT_STATE_DIR", str(tmp_path))
    for k in ("BASE_DAILY_USD", "FREE_MONTHLY_CAP_USD", "PAID_WINDOW"):
        monkeypatch.delenv(k, raising=False)
    if str(MINT_DIR) not in sys.path:
        sys.path.insert(0, str(MINT_DIR))
    monkeypatch.setenv("MINT_SWEEP_S", "3600")
    sys.modules.pop("mint", None)
    mint = importlib.import_module("mint")
    fake = FakeLiteLLM()
    mint.rds = make_redis()
    mint.litellm_client = lambda timeout=20: httpx.Client(
        base_url="http://litellm", transport=httpx.MockTransport(fake.handler))
    monkeypatch.setattr(mint, "verify_app_check", lambda token: "android")
    monkeypatch.setattr(mint, "verify_google_id_token",
                        lambda token: {"sub": token, "email": f"{token}@example.com"})
    yield mint, fake, tmp_path
    sys.modules.pop("mint", None)


@pytest.fixture
def client(env):
    from fastapi.testclient import TestClient
    mint, fake, tmp = env
    with TestClient(mint.app) as c:
        yield c, mint, fake, tmp


ADMIN = {"Authorization": f"Bearer {MASTER}"}


def user_with_keys(mint, fake, uid, tier="free", android=True, web=True, **kw):
    # `tier` is what billing/admin store: a plan id or alias (3x/7x/15x).
    """Register a user with android and/or web keys in Redis + the fake."""
    mint.rds.sadd(mint.ALL_UIDS_SET, uid)
    if tier != "free":
        mint.rds.set(f"user:{uid}:tier", tier)
    toks = {}
    if android:
        toks["android"] = fake.add_key(f"tok-{uid}-a", **kw)
        mint.rds.set(f"user:{uid}:keyid", toks["android"])
        mint.rds.set(f"user:{uid}:key", f"sk-{uid}-a")
    if web:
        toks["web"] = fake.add_key(f"tok-{uid}-w", **kw)
        mint.rds.set(f"user:{uid}:web:keyid", toks["web"])
        mint.rds.set(f"user:{uid}:web:key", f"sk-{uid}-w")
    fake.users.setdefault(uid, {"spend": 0.0, "budget_duration": "30d"})
    return toks


def standard_models(fake):
    """Auto routes to the six cheap chat models; plus a pricey chat model, an
    image model with a per-image price and an unpriced model."""
    prices = {  # input, output per token
        "deepseek-v4.1-flash": (1e-7, 4e-7),
        "glm-5.3-flash": (2e-7, 8e-7),
        "gemini-3.7-flash": (1.5e-7, 6e-7),
        "gemini-3.8-flash": (3e-7, 2.5e-6),   # most expensive auto member
        "minimax-m3": (2e-7, 1e-6),
        "gpt-5.6-luna": (2.5e-7, 2e-6),
    }
    for name, (i, o) in prices.items():
        fake.add_model(name, f"prov/{name}", i, o, mode="chat")
        fake.add_model("auto", f"prov/{name}", i, o, mode="chat")
    fake.add_model("big-pro", "prov/big-pro", 5e-6, 2e-5, mode="chat")
    fake.add_model("ovid-image", "prov/img-1", per_image=0.04, mode="image_generation")
    fake.add_model("mystery", "prov/mystery")
    return prices
