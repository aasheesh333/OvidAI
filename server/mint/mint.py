# Ovid Cloud — mint verifier service
#
# Runs on the VPS next to LiteLLM (NO Firebase Blaze). It:
#   1. verifies the Google ID token (Firebase Auth) against Google's public JWKS
#   2. verifies the Firebase App Check token against Firebase's public JWKS
#   3. mints/returns the caller's per-user LiteLLM virtual key (tier budget)
#   4. enforces the $10/calendar-month free-tier cap via Redis
#
# Everything stays on the box. The APK only ever receives its own virtual key.

#
# Versioned in the repo at server/mint/mint.py (see server/mint/README.md for
# the deploy steps, the Redis keys and the /usage API contract).

import os
import time
import threading
import json
import math
import hmac
import hashlib
import datetime
import urllib.request

import jwt  # PyJWT
from jwt import PyJWKClient
import redis
import httpx
from fastapi import Body, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from pydantic import BaseModel

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ovid_plans as plans  # noqa: E402  (shared with the LiteLLM pools hook)

# ── config (from env; secrets never in code) ──
FIREBASE_PROJECT = os.environ["FIREBASE_PROJECT_ID"]          # e.g. ovid-ai
APPCHECK_ENABLED = os.environ.get("APPCHECK_ENABLED", "true").lower() == "true"
# Allowed Firebase app ids per platform: "android:<appId>,web:<appId>".
# A valid App Check token from any other app id is refused.
APPCHECK_APPS = {}
for _entry in os.environ.get("OVID_APPCHECK_APPS", "").split(","):
    _entry = _entry.strip()
    if ":" in _entry:
        _plat, _app = _entry.split(":", 1)
        APPCHECK_APPS[_app.strip()] = _plat.strip().lower()
# Abuse ceilings per key. Ovid is a 24/7 agent on very large projects, so
# these sit far above any legitimate agent loop (parallel subagents, long
# tool chains); budgets remain the real per-user limit.
KEY_RPM = int(os.environ.get("KEY_RPM", "240"))
KEY_TPM = int(os.environ.get("KEY_TPM", "4000000"))
KEY_MAX_PARALLEL = int(os.environ.get("KEY_MAX_PARALLEL", "16"))
# Web clients (reCAPTCHA-attested) share a team whose daily budget is a hard
# ceiling on total web spend.
WEB_TEAM_DAILY_USD = float(os.environ.get("WEB_TEAM_DAILY_USD", "25"))
# Alerts.
ALERT_TELEGRAM_BOT_TOKEN = os.environ.get("ALERT_TELEGRAM_BOT_TOKEN", "")
ALERT_TELEGRAM_CHAT_ID = os.environ.get("ALERT_TELEGRAM_CHAT_ID", "")
ALERT_WEBHOOK_URL = os.environ.get("ALERT_WEBHOOK_URL", "")
DAILY_SPEND_ALERT_USD = float(os.environ.get("DAILY_SPEND_ALERT_USD", "20"))
LITELLM_BASE = os.environ.get("LITELLM_BASE", "http://litellm:4000")
LITELLM_MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/2")
FREE_MONTHLY_CAP_USD = float(os.environ.get("FREE_MONTHLY_CAP_USD", "10"))


# ── usage limits: plans are data, every number is a runtime setting ──
#
# All limits live in Redis (config:limits + config:base_daily_usd) and are
# edited from the /admin console; mint reads them on every request, so a change
# takes effect immediately (no rebuild/restart). The env values and the seeds
# in ovid_plans.py are FIRST-RUN SEEDS only: ensure_default_settings() writes
# them for fields that are unset and never overwrites a stored value.
#
#   shared plans (free, starter): allowance = the user's free allowance × mult
#       per window; frontier models may use at most frontier_share of it.
#   split plans (pro, max): oss fair-use pool + frontier pool. Over the oss
#       pool → slow mode (lower rpm/tpm/parallel), never a block. Frontier
#       exhausted → frontier requests get `frontier_limit_reached`.
# Pools are enforced in the LiteLLM request path by litellm_hook/ovid_pools.py
# (reads the same Redis settings); LiteLLM key/user budgets stay a backstop.
BASE_DAILY_USD = float(os.environ.get("BASE_DAILY_USD", "0.15"))
SEEDS = {
    "free_daily_usd": BASE_DAILY_USD,
    "free_monthly_cap_usd": FREE_MONTHLY_CAP_USD,
    "normal_rpm": KEY_RPM,
    "normal_tpm": KEY_TPM,
    "normal_parallel": KEY_MAX_PARALLEL,
    "est_input_tokens": int(os.environ.get("EST_INPUT_TOKENS", "2000")),
    "est_output_tokens": int(os.environ.get("EST_OUTPUT_TOKENS", "600")),
    "est_image_tokens": int(os.environ.get("EST_IMAGE_TOKENS", "1500")),
}
# Back-compat names (images_gateway, billing): legacy tier ids are aliases.
TIER_MULT = {"free": 1, "3x": 3, "7x": 7, "15x": 15}
TIERS = {t: {"mult": m} for t, m in TIER_MULT.items()}
# Settings + audit mirrors on the mint volume (mintdata:/data), so a Redis loss
# does not lose the owner's limits or the audit trail.
MINT_STATE_DIR = os.environ.get("MINT_STATE_DIR", "/data")
# Above this many users a "re-apply/reset everyone" runs in the background.
REAPPLY_SYNC_MAX = int(os.environ.get("REAPPLY_SYNC_MAX", "200"))

ALL_UIDS_SET = "ovid:uids"
BASE_BUDGET_KEY = plans.BASE_BUDGET_KEY
LIMITS_HASH = plans.LIMITS_HASH
REAPPLY_STATUS_KEY = "config:reapply_status"
RESET_STATUS_KEY = "config:reset_status"
AUDIT_LIST = "audit:admin"
AUDIT_MAX = int(os.environ.get("AUDIT_MAX", "5000"))
KEY_NAMESPACES = ("", "web:")          # android key, web key


def _float_or(v, default: float) -> float:
    try:
        return float(v) if v not in (None, "") else default
    except (TypeError, ValueError):
        return default


def _int_or(v, default: int) -> int:
    try:
        return int(float(v)) if v not in (None, "") else default
    except (TypeError, ValueError):
        return default


def get_settings() -> dict:
    """Live settings, read from Redis on every call (no caching)."""
    return plans.parse_settings(rds.hgetall(LIMITS_HASH), rds.get(BASE_BUDGET_KEY), SEEDS)


def get_base_daily() -> float:
    return get_settings()["free_daily_usd"]


def get_free_monthly_cap() -> float:
    return get_settings()["free_monthly_cap_usd"]


def store_settings(s: dict) -> dict:
    s = plans.validate_settings(s)
    base, fields = plans.serialize_settings(s)
    rds.set(BASE_BUDGET_KEY, base)
    rds.hset(LIMITS_HASH, mapping=fields)
    _persist_settings(s)
    return s


def ensure_default_settings() -> list[str]:
    """Write first-run seeds for UNSET fields only (never overwrites).

    An existing install (users or a base budget already in Redis) gets paid
    plan windows of 720h (30 days, the behaviour before plans existed); a new
    install gets 24h. Returns the fields written."""
    existing = bool(rds.exists(BASE_BUDGET_KEY) or rds.scard(ALL_UIDS_SET))
    written = []
    if not rds.exists(BASE_BUDGET_KEY):
        rds.set(BASE_BUDGET_KEY, str(SEEDS["free_daily_usd"]))
        written.append("free_daily_usd")
    seeded = plans.parse_settings({}, None, {**SEEDS, "plans": plans.seed_plans(720 if existing else 24)})
    _, fields = plans.serialize_settings(seeded)
    for f, v in fields.items():
        if rds.hget(LIMITS_HASH, f) is None:
            rds.hset(LIMITS_HASH, f, v)
            written.append(f)
    if written:
        _persist_settings(get_settings())
    return written


def _state_path(name: str) -> str | None:
    if not MINT_STATE_DIR or not os.path.isdir(MINT_STATE_DIR):
        return None
    return os.path.join(MINT_STATE_DIR, name)


def _persist_settings(s: dict) -> None:
    path = _state_path("limits.json")
    if not path:
        return
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(s, f, sort_keys=True)
        os.replace(tmp, path)
    except OSError as e:
        print(f"[mint] settings mirror write failed: {type(e).__name__}", flush=True)


def restore_settings_if_missing() -> bool:
    """After a Redis loss, restore the owner's limits from the volume mirror."""
    if rds.exists(BASE_BUDGET_KEY) or rds.exists(LIMITS_HASH):
        return False
    path = _state_path("limits.json")
    if not path or not os.path.exists(path):
        return False
    try:
        with open(path) as f:
            saved = json.load(f)
        s = get_settings()
        s.update({k: v for k, v in saved.items() if k in s})
        store_settings(s)
        print("[mint] limits restored from volume mirror", flush=True)
        return True
    except (OSError, ValueError) as e:
        print(f"[mint] settings restore failed: {type(e).__name__}", flush=True)
        return False


def user_free_daily(uid: str, s: dict | None = None) -> float:
    """This user's free allowance per 24h: custom free limit or the global."""
    override = rds.get(f"user:{uid}:dailyUsd")
    if override not in (None, ""):
        try:
            return float(override)
        except (TypeError, ValueError):
            pass
    return (s or get_settings())["free_daily_usd"]


def user_pool_override(uid: str) -> dict | None:
    raw = rds.get(f"user:{uid}:pools")
    if not raw:
        return None
    try:
        v = json.loads(raw)
        return v if isinstance(v, dict) else None
    except ValueError:
        return None


def plan_for(uid: str, s: dict | None = None) -> dict:
    s = s or get_settings()
    return plans.find_plan(s, rds.get(f"user:{uid}:tier"))


def pools_for(uid: str, s: dict | None = None, plan: dict | None = None) -> dict:
    s = s or get_settings()
    plan = plan or plan_for(uid, s)
    return plans.user_pools(s, plan, user_free_daily(uid, s), user_pool_override(uid))


def tier_daily(uid: str, tier: str) -> float:
    """Back-compat: the user's total allowance per 24h on `tier`."""
    s = get_settings()
    p = plans.user_pools(s, plans.find_plan(s, tier), user_free_daily(uid, s), user_pool_override(uid))
    total = p["all"] if p["all"] is not None else p["oss"] + p["frontier"]
    return total * 24 / p["window_hours"]


def tier_budget(uid: str, tier: str) -> tuple[float, str]:
    """(LiteLLM key max_budget, budget_duration) for a user on `tier` (plan id
    or alias). Kept for images_gateway."""
    s = get_settings()
    p = plans.user_pools(s, plans.find_plan(s, tier), user_free_daily(uid, s), user_pool_override(uid))
    return plans.key_budget(p, s), plans.window_str(p["window_hours"])


# Anti-abuse knobs (all server-side, per spec §7).
# Shared-IP SAFE: these throttle NEW-signup VELOCITY, not raw account counts,
# so CGNAT / college / office WiFi (thousands of real users per IP) are never
# banned. App Check (Play Integrity) is the primary anti-farm defense.
#
# How many brand-new accounts one IP may create inside the short velocity
# window before NEW signups (only) get a 429. A farmer spins up many fast;
# a shared network makes a few organically.
NEW_ACCOUNTS_PER_IP_PER_WINDOW = int(os.environ.get("NEW_ACCOUNTS_PER_IP_PER_WINDOW", "12"))
SIGNUP_VELOCITY_WINDOW_S = int(os.environ.get("SIGNUP_VELOCITY_WINDOW_S", "600"))  # 10 min
# Backstop daily set-expiry for the per-IP seen-accounts set.
IP_ACCOUNT_WINDOW_S = int(os.environ.get("IP_ACCOUNT_WINDOW_S", str(24 * 3600)))
# Auto-ban (the ACCOUNT, never the shared IP) after this many abuse strikes.
ABUSE_STRIKE_LIMIT = int(os.environ.get("ABUSE_STRIKE_LIMIT", "20"))
ABUSE_WINDOW_S = int(os.environ.get("ABUSE_WINDOW_S", str(3600)))
# Advisory only: distinct keys per IP is a REVIEW signal, never a lone ban
# reason (a shared IP legitimately has many). Surfaced for admin + corroboration.
DISTINCT_KEYS_PER_IP_REVIEW = int(os.environ.get("DISTINCT_KEYS_PER_IP_REVIEW", "100"))
IP_KEYS_WINDOW_S = int(os.environ.get("IP_KEYS_WINDOW_S", str(6 * 3600)))
# Per-IP /mint call rate limit (even with valid tokens): stops a scripted
# attacker hammering mint from one IP. Mint calls per IP per window.
MINT_CALLS_PER_IP = int(os.environ.get("MINT_CALLS_PER_IP", "40"))
MINT_WINDOW_S = int(os.environ.get("MINT_WINDOW_S", "3600"))
# Global new-key circuit breaker: max brand-new keys created across the WHOLE
# service per window. A mass key-creation event (even with many real accounts)
# trips this and pauses new sign-ups, raising an admin alert.
GLOBAL_NEWKEYS_PER_WINDOW = int(os.environ.get("GLOBAL_NEWKEYS_PER_WINDOW", "500"))
NEWKEY_WINDOW_S = int(os.environ.get("NEWKEY_WINDOW_S", "3600"))

GOOGLE_JWKS = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
APPCHECK_JWKS = "https://firebaseappcheck.googleapis.com/v1/jwks"

rds = redis.from_url(REDIS_URL, decode_responses=True)
app = FastAPI(title="ovid-mint")


@app.exception_handler(StarletteHTTPException)
async def _log_http_error(request: Request, exc: StarletteHTTPException):
    # Log WHY a request failed (e.g. "missing app check token"). Details never
    # contain tokens or keys.
    print(f"[mint] {request.method} {request.url.path} -> {exc.status_code}: {exc.detail}", flush=True)
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code,
                        headers=getattr(exc, "headers", None))


# ── token verification (standard JWT, no Blaze/Admin billing) ──
def verify_google_id_token(token: str) -> dict:
    """Verify a Firebase Auth (Google) ID token against the public certs."""
    try:
        header = jwt.get_unverified_header(token)
        kid = header["kid"]
        certs = _google_certs()
        key_pem = certs.get(kid)
        if not key_pem:
            raise HTTPException(401, "unknown signing key")
        claims = jwt.decode(
            token,
            key_pem,
            algorithms=["RS256"],
            audience=FIREBASE_PROJECT,
            issuer=f"https://securetoken.google.com/{FIREBASE_PROJECT}",
        )
        if not claims.get("sub"):
            raise HTTPException(401, "no subject")
        return claims
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"invalid id token: {e}")


_cert_cache: dict = {"exp": 0, "certs": {}}


def _google_certs() -> dict:
    """Fetch + cache Google's x509 certs (Firebase ID-token signers)."""
    now = time.time()
    if now < _cert_cache["exp"] and _cert_cache["certs"]:
        return _cert_cache["certs"]
    url = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"
    with urllib.request.urlopen(url, timeout=10) as r:
        data = json.load(r)
        cc = r.headers.get("cache-control", "")
    # crude max-age parse; default 1h
    ttl = 3600
    for part in cc.split(","):
        part = part.strip()
        if part.startswith("max-age="):
            try:
                ttl = int(part.split("=", 1)[1])
            except ValueError:
                pass
    # convert PEM x509 certs → public keys usable by PyJWT
    from cryptography import x509
    from cryptography.hazmat.backends import default_backend
    certs = {}
    for kid, pem in data.items():
        cert = x509.load_pem_x509_certificate(pem.encode(), default_backend())
        certs[kid] = cert.public_key()
    _cert_cache.update(exp=now + ttl, certs=certs)
    return certs


_appcheck_jwk_client = PyJWKClient(APPCHECK_JWKS)


def verify_app_check(token: str) -> str:
    """Verify a Firebase App Check token; return the client platform
    ("android", "web", ...). Play Integrity on Android, reCAPTCHA Enterprise
    on web — both arrive as the same signed App Check JWT."""
    if not APPCHECK_ENABLED:
        return "android"
    try:
        signing_key = _appcheck_jwk_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=[f"projects/{FIREBASE_PROJECT}"],
            issuer=f"https://firebaseappcheck.googleapis.com/{_project_number()}",
            options={"verify_iss": False},  # project-number issuer; aud is the strong check
        )
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"invalid app check token: {e}")
    app_id = str(claims.get("sub", ""))
    if APPCHECK_APPS:
        platform = APPCHECK_APPS.get(app_id)
        if not platform:
            raise HTTPException(403, "unknown app")
        return platform
    return "web" if ":web:" in app_id else "android"



def alert(kind: str, message: str, every_s: int = 3600) -> None:
    """Send an operator alert at most once per `every_s` per kind."""
    bucket = int(time.time() // every_s)
    if not rds.set(f"alertsent:{kind}:{bucket}", "1", nx=True, ex=every_s):
        return
    print(f"[mint] ALERT {kind}: {message}", flush=True)
    text = f"Ovid gateway alert [{kind}]\n{message}"

    def _send():
        try:
            with httpx.Client(timeout=10) as c:
                if ALERT_TELEGRAM_BOT_TOKEN and ALERT_TELEGRAM_CHAT_ID:
                    c.post(f"https://api.telegram.org/bot{ALERT_TELEGRAM_BOT_TOKEN}/sendMessage",
                           json={"chat_id": ALERT_TELEGRAM_CHAT_ID, "text": text})
                if ALERT_WEBHOOK_URL:
                    c.post(ALERT_WEBHOOK_URL, json={"kind": kind, "text": text})
        except Exception as e:  # noqa: BLE001
            print(f"[mint] alert send failed: {type(e).__name__}", flush=True)

    threading.Thread(target=_send, daemon=True).start()


def litellm_client(timeout: float = 20) -> httpx.Client:
    """Client for the on-box LiteLLM admin API (tests swap this out)."""
    return httpx.Client(base_url=LITELLM_BASE, timeout=timeout)


def _admin_headers() -> dict:
    return {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}



def web_team_id(c: httpx.Client, headers: dict) -> str:
    """Shared LiteLLM team for web keys; its daily budget caps total web spend."""
    team = rds.get("config:web_team_id")
    want = str(WEB_TEAM_DAILY_USD)
    if team:
        if rds.get("config:web_team_budget") != want:
            r = c.post("/team/update", headers=headers,
                       json={"team_id": team, "max_budget": WEB_TEAM_DAILY_USD, "budget_duration": "1d"})
            if r.status_code < 300:
                rds.set("config:web_team_budget", want)
        return team
    r = c.post("/team/new", headers=headers,
               json={"team_alias": "ovid-web", "max_budget": WEB_TEAM_DAILY_USD, "budget_duration": "1d"})
    r.raise_for_status()
    team = r.json()["team_id"]
    rds.set("config:web_team_id", team)
    rds.set("config:web_team_budget", want)
    return team


def _spend_monitor() -> None:
    """Every 5 min: alert when today's total spend crosses the threshold."""
    while True:
        try:
            with litellm_client(15) as c:
                r = c.get("/global/spend", headers=_admin_headers())
            if r.status_code == 200:
                total = float(r.json().get("spend") or 0.0)
                day = time.strftime("%Y%m%d", time.gmtime())
                rds.set(f"spend:daybase:{day}", str(total), nx=True, ex=3 * 86400)
                today = total - float(rds.get(f"spend:daybase:{day}") or total)
                if today >= DAILY_SPEND_ALERT_USD:
                    alert("daily_spend", f"Spend today ${today:.2f} >= ${DAILY_SPEND_ALERT_USD:.2f}", 86400)
        except Exception as e:  # noqa: BLE001
            print(f"[mint] spend monitor: {type(e).__name__}", flush=True)
        time.sleep(300)


def _project_number() -> str:
    return os.environ.get("FIREBASE_PROJECT_NUMBER", "")




# ── plan, budgets, windows, slow mode ──
def effective_tier(uid: str) -> str:
    """The user's plan id (stored legacy ids 3x/7x/15x resolve via aliases)."""
    return plan_for(uid)["id"]


def month_key(uid: str) -> str:
    """Legacy counter key (never written; kept so old deletes stay harmless)."""
    return f"freecap:{uid}:{_now().strftime('%Y-%m')}"


def free_cap_usd(uid: str) -> float:
    return _float_or(rds.get(f"user:{uid}:monthlyCapUsd"), get_free_monthly_cap())


def month_spent(uid: str) -> float:
    """User-level spend over the current LiteLLM user-budget window."""
    try:
        with litellm_client(10) as c:
            return _month_spent_c(c, uid)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user/info error: {type(e).__name__}", flush=True)
    return 0.0


def _month_spent_c(c: httpx.Client, uid: str) -> float:
    try:
        r = c.get("/user/info", headers=_admin_headers(), params={"user_id": uid})
        if r.status_code == 200:
            return float((r.json().get("user_info") or {}).get("spend") or 0.0)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user/info error: {type(e).__name__}", flush=True)
    return 0.0


def user_budget_target(uid: str, tier: str) -> tuple[float, str]:
    """LiteLLM user budget (across all of the user's keys). Free plan: the
    monthly backstop per 30d. Other plans: the key budget per plan window."""
    if plans.find_plan(get_settings(), tier)["id"] == "free":
        return free_cap_usd(uid), "30d"
    return tier_budget(uid, tier)


def ensure_user_budget(c: httpx.Client, headers: dict, uid: str, tier: str,
                       force_duration: bool = False, extra: dict | None = None) -> None:
    budget, duration = user_budget_target(uid, tier)
    body = {"user_id": uid, "max_budget": budget, **(extra or {})}
    # Only send budget_duration when it changes: LiteLLM restarts the budget
    # clock (budget_reset_at = now + duration) whenever it is sent, so sending
    # it on every mint would keep pushing the reset out.
    current = None
    if not force_duration:
        try:
            r = c.get("/user/info", headers=headers, params={"user_id": uid})
            if r.status_code == 200:
                current = (r.json().get("user_info") or {}).get("budget_duration")
            elif r.status_code != 404:
                current = "unknown"  # outage: don't touch the clock
        except Exception:  # noqa: BLE001
            current = "unknown"
    if force_duration or (current != duration and current != "unknown"):
        body["budget_duration"] = duration
    r = c.post("/user/update", headers=headers, json=body)
    if r.status_code >= 300:
        print(f"[mint] user/update {r.status_code} for {uid[:6]}", flush=True)


def free_cap_remaining(uid: str) -> float:
    return max(0.0, free_cap_usd(uid) - month_spent(uid))


def _key_info(c: httpx.Client, key_id: str) -> dict | None:
    try:
        r = c.get("/key/info", headers=_admin_headers(), params={"key": key_id})
    except Exception:  # noqa: BLE001
        return None
    if r.status_code != 200:
        return None
    data = r.json()
    return data.get("info", data) or {}


def apply_key_budget(c: httpx.Client, key_id: str, budget: float, duration: str,
                     info: dict | None, extra: dict | None = None,
                     force_duration: bool = False) -> bool:
    """Set a key's budget (+ rate limits in `extra`); budget_duration only when
    it changes or a window reset forces the LiteLLM clock to restart."""
    body = {"key": key_id, "max_budget": budget, **(extra or {})}
    if force_duration or (info is not None and info.get("budget_duration") != duration):
        body["budget_duration"] = duration
    r = c.post("/key/update", headers=_admin_headers(), json=body)
    if r.status_code >= 300:
        print(f"[mint] key/update {r.status_code}", flush=True)
        return False
    return True


def user_key_ids(uid: str) -> dict:
    """{namespace: key id} for every key this user holds (android, web)."""
    out = {}
    for ns in KEY_NAMESPACES:
        k = rds.get(f"user:{uid}:{ns}keyid")
        if k:
            out[ns] = k
    return out


def in_slow_mode(uid: str) -> bool:
    until = _float_or(rds.hget(plans.SLOW_HASH, uid), 0.0)
    return until > time.time()


def rate_limits(uid: str, s: dict | None = None) -> dict:
    s = s or get_settings()
    mode = "slow" if in_slow_mode(uid) else "normal"
    return {"rpm_limit": s[f"{mode}_rpm"], "tpm_limit": s[f"{mode}_tpm"],
            "max_parallel_requests": s[f"{mode}_parallel"]}


def reapply_user(c: httpx.Client, uid: str, extra: dict | None = None,
                 force_duration: bool = False, user_extra: dict | None = None,
                 user_force_duration: bool = False) -> dict:
    """Re-apply this user's budget + rate limits to EVERY key (android + web)
    and to the LiteLLM user budget."""
    s = get_settings()
    tier = effective_tier(uid)
    budget, duration = tier_budget(uid, tier)
    body_extra = {**rate_limits(uid, s), **(extra or {})}
    keys = errors = 0
    for _ns, key_id in user_key_ids(uid).items():
        try:
            info = None if force_duration else _key_info(c, key_id)
            if apply_key_budget(c, key_id, budget, duration, info, body_extra, force_duration):
                keys += 1
            else:
                errors += 1
        except Exception as e:  # noqa: BLE001
            errors += 1
            print(f"[mint] reapply key error: {type(e).__name__}", flush=True)
    try:
        ensure_user_budget(c, _admin_headers(), uid, tier, user_force_duration, user_extra)
    except Exception as e:  # noqa: BLE001
        errors += 1
        print(f"[mint] reapply user error: {type(e).__name__}", flush=True)
    return {"keys": keys, "errors": errors}


def _run_over_users(status_key: str, uids: list[str], fn) -> dict:
    total = {"users": 0, "keys": 0, "errors": 0}
    rds.set(status_key, json.dumps({"state": "running", "total": len(uids), "done": 0, "at": _now_iso()}))
    with litellm_client(20) as c:
        for i, uid in enumerate(uids, 1):
            res = fn(c, uid)
            total["users"] += 1
            total["keys"] += res.get("keys", 0)
            total["errors"] += res.get("errors", 0)
            if i % 25 == 0:
                rds.set(status_key, json.dumps({"state": "running", "total": len(uids), "done": i,
                                                **total, "at": _now_iso()}))
    rds.set(status_key, json.dumps({"state": "done", "total": len(uids), "done": len(uids),
                                    **total, "at": _now_iso()}))
    return total


def run_for_everyone(status_key: str, fn) -> dict:
    """Run fn(client, uid) for all users: inline when small, else background
    with progress in `status_key`."""
    uids = sorted(rds.smembers(ALL_UIDS_SET))
    if len(uids) <= REAPPLY_SYNC_MAX:
        return {"mode": "sync", **_run_over_users(status_key, uids, fn)}
    threading.Thread(target=_run_over_users, args=(status_key, uids, fn), daemon=True).start()
    return {"mode": "background", "users": len(uids)}


def reapply_all(uids: list[str] | None = None) -> dict:
    uids = list(uids if uids is not None else rds.smembers(ALL_UIDS_SET))
    return _run_over_users(REAPPLY_STATUS_KEY, uids, lambda c, u: reapply_user(c, u))


def reapply_everyone() -> dict:
    return run_for_everyone(REAPPLY_STATUS_KEY, lambda c, u: reapply_user(c, u))


def window_bounds(uid: str, pools: dict, create: bool = True,
                  first_use: datetime.datetime | None = None) -> tuple[datetime.datetime, datetime.datetime]:
    """The user's current pool window [start, resets_at). It starts at the
    first use (hook or mint, whichever sees it first; `first_use` lets mint
    anchor it at the earliest request it finds) and lasts the plan's
    window_hours; an admin reset restarts it now."""
    k = plans.pool_keys(uid)
    secs = int(pools["window_hours"] * 3600)
    now = _now()
    start = current_window_start(uid, pools)
    if start is None:
        if not create:
            return now, now + datetime.timedelta(seconds=secs)
        begin = min(first_use or now, now)
        ttl = max(1, int(secs - (now - begin).total_seconds()))
        # floor to whole seconds so the first request is never after "start"
        rds.set(k["start"], str(math.floor(begin.timestamp())), nx=True, ex=ttl)
        start = _epoch_dt(rds.get(k["start"])) or begin
    return start, start + datetime.timedelta(seconds=secs)


def current_window_start(uid: str, pools: dict) -> datetime.datetime | None:
    """Start of the live window, or None (expired windows are cleared)."""
    k = plans.pool_keys(uid)
    start = _epoch_dt(rds.get(k["start"]))
    if start is not None and start + datetime.timedelta(hours=pools["window_hours"]) <= _now():
        rds.delete(k["start"], k["oss"], k["frontier"])
        return None
    return start


def _epoch_dt(v) -> datetime.datetime | None:
    try:
        return datetime.datetime.fromtimestamp(float(v), datetime.timezone.utc) if v else None
    except (TypeError, ValueError):
        return None


def hook_spend(uid: str) -> dict:
    k = plans.pool_keys(uid)
    return {c: _float_or(rds.get(k[c]), 0.0) for c in plans.CLASSES}


def push_rate_limits(c: httpx.Client, uid: str) -> None:
    limits = rate_limits(uid)
    for key_id in user_key_ids(uid).values():
        try:
            c.post("/key/update", headers=_admin_headers(), json={"key": key_id, **limits})
        except Exception as e:  # noqa: BLE001
            print(f"[mint] rate-limit update error: {type(e).__name__}", flush=True)


def sync_slow_mode(c: httpx.Client, uid: str, slow: bool, until: datetime.datetime) -> bool:
    """Turn slow mode on/off on all of the user's keys. Returns True on change."""
    was = in_slow_mode(uid)
    if slow:
        rds.hset(plans.SLOW_HASH, uid, f"{until.timestamp():.3f}")
    else:
        rds.hdel(plans.SLOW_HASH, uid)
    if was == slow:
        return False
    push_rate_limits(c, uid)
    return True


def sweep_slow_mode() -> dict:
    """Apply slow mode for users the hook flagged; lift it when windows end."""
    out = {"checked": 0, "lifted": 0}
    for uid in list(rds.smembers(plans.SLOW_PENDING)):
        rds.srem(plans.SLOW_PENDING, uid)
        try:
            compute_usage(uid)  # syncs slow mode from the pools
            out["checked"] += 1
        except Exception as e:  # noqa: BLE001
            print(f"[mint] slow sweep error: {type(e).__name__}", flush=True)
    now = time.time()
    with litellm_client(15) as c:
        for uid, until in list(rds.hgetall(plans.SLOW_HASH).items()):
            if _float_or(until, 0) <= now:
                rds.hdel(plans.SLOW_HASH, uid)
                push_rate_limits(c, uid)
                out["lifted"] += 1
    return out


def _sweeper() -> None:
    while True:
        try:
            sweep_slow_mode()
            refresh_public_map()
        except Exception as e:  # noqa: BLE001
            print(f"[mint] sweeper: {type(e).__name__}", flush=True)
        time.sleep(int(os.environ.get("MINT_SWEEP_S", "30")))


def reset_window_user(c: httpx.Client, uid: str, reset_month_free: bool = False) -> dict:
    """Restart the user's window NOW: clear pool counters and slow mode, zero
    spend on every key (android + web), restart the LiteLLM budget clocks and
    re-apply budgets."""
    s = get_settings()
    pools = pools_for(uid, s)
    k = plans.pool_keys(uid)
    rds.delete(k["oss"], k["frontier"], f"usagecache:{uid}")
    rds.set(k["start"], f"{time.time():.3f}", ex=int(pools["window_hours"] * 3600))
    rds.hdel(plans.SLOW_HASH, uid)
    rds.srem(plans.SLOW_PENDING, uid)
    # The free plan's LiteLLM user budget is the monthly backstop with its own
    # 30-day clock; only reset it when asked. Other plans' user budget is the
    # window budget, so it restarts with the window.
    is_free = plan_for(uid, s)["id"] == "free"
    restart_user = not is_free or reset_month_free
    res = reapply_user(c, uid, extra={"spend": 0}, force_duration=True,
                       user_extra={"spend": 0} if restart_user else None,
                       user_force_duration=restart_user)
    rds.delete(month_key(uid))  # legacy key, harmless
    return res


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _now_iso() -> str:
    return _now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def remember_email(uid: str, email) -> None:
    """Index the verified Google email so the admin can look users up by it."""
    if not email or not isinstance(email, str):
        return
    email = email.strip().lower()
    try:
        if rds.get(f"user:{uid}:email") != email:
            rds.set(f"user:{uid}:email", email)
            rds.set(f"email:{email}", uid)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] email index error: {type(e).__name__}", flush=True)



# ── anti-abuse: client IP, IP-based signup throttle, ban ──
# DESIGN NOTE (shared-IP safety): In India especially, CGNAT mobile carriers and
# college/office WiFi put THOUSANDS of legitimate users behind ONE IP. So we
# must NEVER ban an IP just because many accounts use it. The real defenses are:
#   1) App Check (Play Integrity) — a farmer can't attest at scale; this is the
#      primary anti-farm signal, not IP counting.
#   2) Signup VELOCITY throttle — a farmer makes many accounts fast; a shared
#      network makes a handful organically. We throttle only NEW signups from a
#      hot IP (429), which NEVER affects existing users on that IP.
#   3) Abuse strikes land on the UID (the actual bad account), not the IP.
# An IP ban is reserved for extreme, corroborated cases (App Check failing AND
# crazy signup velocity AND many abuse strikes) and is always TTL'd, or set by
# an admin by hand.
def client_ip(x_forwarded_for: str, x_real_ip: str) -> str:
    # Behind Cloudflare → Caddy, the real client is the first XFF hop.
    if x_forwarded_for:
        return x_forwarded_for.split(",")[0].strip()
    return (x_real_ip or "unknown").strip()


def is_banned(uid: str, ip: str) -> bool:
    if rds.get(f"user:{uid}:banned"):
        return True
    if ip and ip != "unknown" and rds.get(f"ban:ip:{ip}"):
        return True
    return False


def record_strike(uid: str, ip: str) -> None:
    """Count an abuse signal on the UID (the actual bad actor). The IP counter
    is advisory only — it is NEVER the sole basis for an IP ban, so a shared
    network cannot be taken down by one bad account behind it."""
    n = rds.incr(f"abuse:uid:{uid}")
    if n == 1:
        rds.expire(f"abuse:uid:{uid}", ABUSE_WINDOW_S)
    if n >= ABUSE_STRIKE_LIMIT:
        rds.set(f"user:{uid}:banned", "auto")  # ban the account, not the IP
        alert("auto_ban", f"uid {uid[:6]}… auto-banned after {n} abuse strikes", 600)
    # advisory IP signal (for admin review / corroboration only)
    m = rds.incr(f"abuse:ip:{ip}")
    if m == 1:
        rds.expire(f"abuse:ip:{ip}", ABUSE_WINDOW_S)


def enforce_ip_signup_quota(uid: str, ip: str) -> None:
    """Shared-IP-safe signup throttle.

    Throttles only the RATE of NEW account creation from an IP in a short
    window. Returning users (uid already seen on this IP) are never touched,
    and existing users on the same IP are never affected — we only ever delay
    a burst of brand-new signups, never ban the IP. A college/CGNAT IP making
    a few new accounts organically stays fine; a farmer spinning up dozens in
    minutes gets 429'd on the NEW ones only.
    """
    if not ip or ip == "unknown":
        return
    seen_key = f"ipacct:{ip}"
    # Returning user on this IP → never throttled.
    if rds.sismember(seen_key, uid):
        return
    # Short-window NEW-signup velocity (the farmer tell).
    vel_key = f"ipnew:{ip}:{int(time.time() // SIGNUP_VELOCITY_WINDOW_S)}"
    vel = rds.incr(vel_key)
    if vel == 1:
        rds.expire(vel_key, SIGNUP_VELOCITY_WINDOW_S)
    if vel > NEW_ACCOUNTS_PER_IP_PER_WINDOW:
        alert("signup_velocity", f"IP {ip} exceeded {NEW_ACCOUNTS_PER_IP_PER_WINDOW} new accounts / window", 1800)
        # Throttle the NEW signup only — existing users unaffected, IP NOT banned.
        raise HTTPException(
            429,
            "sign-ups from this network are busy right now — please retry "
            "in a few minutes",
        )
    rds.sadd(seen_key, uid)
    rds.expire(seen_key, IP_ACCOUNT_WINDOW_S)



# ── LiteLLM admin calls (local, on-box) ──
def _key_state(c: httpx.Client, headers: dict, key_id: str) -> tuple[bool, dict | None]:
    """(usable, info). Not usable only when LiteLLM says the key is gone,
    rejected or expired. Upstream errors/timeouts count as usable (never churn
    keys on outages). Admin-blocked keys stay as they are (ban/unban manages
    them)."""
    try:
        r = c.get("/key/info", headers=headers, params={"key": key_id})
    except Exception:  # noqa: BLE001
        return True, None
    if r.status_code in (401, 403, 404):
        return False, None
    if r.status_code != 200:
        return True, None
    info = r.json().get("info") or {}
    exp = info.get("expires")
    if exp:
        when = _parse_time(exp)
        if when is not None and when <= _now():
            return False, info
    return True, info


def _key_usable(c: httpx.Client, headers: dict, key_id: str) -> bool:
    return _key_state(c, headers, key_id)[0]


def _safe_user_budget(c, headers, uid, tier):
    try:
        ensure_user_budget(c, headers, uid, tier)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user budget error: {type(e).__name__}", flush=True)


def litellm_mint_or_get(uid: str, tier: str, platform: str = "android") -> str:
    """Strictly idempotent per UID: one Google account == exactly one key.

    A reverse engineer with a real Google ID token can only ever obtain THEIR
    OWN single key here — re-calling returns the same key, never a new one. A
    short Redis lock closes the race where two concurrent mint calls for the
    same brand-new UID could each create a key. 'Unlimited key creation' is
    therefore impossible per account; the only way to more keys is more real
    Google accounts, which App Check + IP signup-velocity + the global
    new-key breaker all throttle.
    """
    budget, duration = tier_budget(uid, tier)
    # Separate key per platform so phone and web never evict each other.
    ns = "web:" if platform == "web" else ""
    headers = _admin_headers()
    with litellm_client(20) as c:
        # Idempotent: look up an existing key for this user first.
        existing = rds.get(f"user:{uid}:{ns}keyid")
        body = {
            "user_id": uid,
            "max_budget": budget,
            "budget_duration": duration,
            "metadata": {"tier": tier, "ovid_uid": uid, "platform": platform},
            # Runtime-editable limits; slow-mode limits while the user is in it.
            **rate_limits(uid),
        }
        if platform == "web":
            body["team_id"] = web_team_id(c, headers)
        usable, info = _key_state(c, headers, existing) if existing else (False, None)
        if existing and usable:
            update = {"key": existing, **body}
            # Re-sending an unchanged budget_duration restarts LiteLLM's budget
            # clock on every app launch; only send it when it changes.
            if info is None or info.get("budget_duration") == duration:
                update.pop("budget_duration")
            r = c.post("/key/update", headers=headers, json=update)
            if r.status_code >= 300:
                print(f"[mint] key/update {r.status_code} for {uid[:6]}", flush=True)
            _safe_user_budget(c, headers, uid, tier)
            rds.sadd(ALL_UIDS_SET, uid)
            k = rds.get(f"user:{uid}:{ns}key")
            if k:
                return k
        if existing:
            # Stored key is gone/expired/rejected: replace it so the app is
            # never stuck retrying a dead key.
            print(f"[mint] re-issuing unusable key for {uid[:6]}", flush=True)
            try:
                c.post("/key/delete", headers=headers, json={"keys": [existing]})
            except Exception:  # noqa: BLE001
                pass
            rds.delete(f"user:{uid}:{ns}keyid", f"user:{uid}:{ns}key")

        # No key yet → take a per-UID creation lock so concurrent calls for a
        # brand-new account cannot each mint a key (race-safe idempotency).
        lock = f"mintlock:{ns}{uid}"
        got = rds.set(lock, "1", nx=True, ex=30)
        if not got:
            # Another request is creating it; wait briefly then return it.
            for _ in range(20):
                time.sleep(0.25)
                k = rds.get(f"user:{uid}:{ns}key")
                if k:
                    return k
            raise HTTPException(409, "key creation in progress, retry")
        try:
            # Re-check inside the lock (someone may have just created it).
            k = rds.get(f"user:{uid}:{ns}key")
            if k:
                return k
            # Global new-key circuit breaker: cap brand-new keys per window so
            # no mass-creation event (even with many real accounts) can run away.
            win = int(time.time() // NEWKEY_WINDOW_S)
            gkey = f"newkeys:{win}"
            created = rds.incr(gkey)
            if created == 1:
                rds.expire(gkey, NEWKEY_WINDOW_S)
            if created > GLOBAL_NEWKEYS_PER_WINDOW:
                rds.set("alert:newkey_spike", str(created), ex=NEWKEY_WINDOW_S)
                alert("newkey_spike", f"{created} new keys this window (cap {GLOBAL_NEWKEYS_PER_WINDOW}); sign-ups paused")
                raise HTTPException(
                    503,
                    "sign-ups are temporarily paused — please try again shortly",
                )
            r = c.post("/key/generate", headers=headers, json=body)
            r.raise_for_status()
            data = r.json()
            key = data["key"]
            rds.set(f"user:{uid}:{ns}keyid", data.get("token", key))
            rds.set(f"user:{uid}:{ns}key", key)
            rds.sadd(ALL_UIDS_SET, uid)
            _safe_user_budget(c, headers, uid, tier)
            return key
        finally:
            rds.delete(lock)


# ── API ──
class MintResp(BaseModel):
    key: str
    tier: str
    base_url: str


@app.get("/healthz")
def healthz():
    return {"ok": True}


# TEST-ONLY self-upgrade (the app's "Pay now" button). Gated by env so it is
# OFF in production — a real payment webhook replaces this later. When enabled,
# a signed-in user can set their own paid tier WITHOUT real payment, for
# end-to-end plan testing only.
ALLOW_TEST_UPGRADE = os.environ.get("ALLOW_TEST_UPGRADE", "false").lower() == "true"


class UpgradeReq(BaseModel):
    tier: str  # plan id or alias (free | starter/3x | pro/7x | max/15x | ...)


class UpgradeResp(BaseModel):
    ok: bool
    tier: str


@app.post("/upgrade", response_model=UpgradeResp)
def upgrade(
    body: UpgradeReq,
    authorization: str = Header(...),
    x_firebase_appcheck: str = Header(default=""),
):
    if not ALLOW_TEST_UPGRADE:
        raise HTTPException(403, "test upgrade is disabled")
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer id token")
    id_token = authorization.split(" ", 1)[1]
    if APPCHECK_ENABLED and not x_firebase_appcheck:
        raise HTTPException(401, "missing app check token")
    platform = verify_app_check(x_firebase_appcheck)
    claims = verify_google_id_token(id_token)
    uid = claims["sub"]
    s = get_settings()
    plan = plans.find_plan(s, body.tier)
    if not plan["enabled"] or (body.tier != plan["id"] and body.tier not in plan["aliases"]):
        plan = plans.find_plan(s, "free")
    tier = plans.stored_tier(plan)
    rds.set(f"user:{uid}:tier", tier)
    # Re-apply the new tier's budget to the live keys (android + web) now.
    try:
        with litellm_client(15) as c:
            reapply_user(c, uid)
    except Exception as e:  # noqa: BLE001
        print(f"upgrade reapply error: {type(e).__name__}")
    return UpgradeResp(ok=True, tier=tier)



@app.post("/mint", response_model=MintResp)
def mint(
    authorization: str = Header(...),
    x_firebase_appcheck: str = Header(default=""),
    x_forwarded_for: str = Header(default=""),
    x_real_ip: str = Header(default=""),
):
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer id token")
    id_token = authorization.split(" ", 1)[1]
    if APPCHECK_ENABLED and not x_firebase_appcheck:
        raise HTTPException(401, "missing app check token")
    platform = verify_app_check(x_firebase_appcheck)
    # Per-user key is assigned ONLY after a verified Google sign-in. A reverse
    # engineer cannot reach this without a real Firebase ID token (verified
    # against Google's public keys), and even then only ever gets THEIR OWN
    # quota-limited key — never a master key, never another user's key.
    claims = verify_google_id_token(id_token)
    uid = claims["sub"]
    remember_email(uid, claims.get("email"))
    ip = client_ip(x_forwarded_for, x_real_ip)

    if is_banned(uid, ip):
        raise HTTPException(403, "account suspended")

    # Per-IP mint-call rate limit (even with valid tokens): a scripted attacker
    # hammering /mint from one IP is throttled. Shared-IP-safe: the limit is
    # generous and only caps mint CALLS, not usage.
    if ip and ip != "unknown":
        mkey = f"mintrate:{ip}:{int(time.time() // MINT_WINDOW_S)}"
        mc = rds.incr(mkey)
        if mc == 1:
            rds.expire(mkey, MINT_WINDOW_S)
        if mc > MINT_CALLS_PER_IP:
            raise HTTPException(429, "too many requests from this network — retry later")

    # Spam-signup defense: cap new free accounts per IP per window.
    enforce_ip_signup_quota(uid, ip)

    tier = effective_tier(uid)
    # Free tier: stop at the $10/month ceiling.
    if tier == "free" and free_cap_remaining(uid) <= 0:
        raise HTTPException(402, "monthly free limit reached")

    key = litellm_mint_or_get(uid, tier, platform)
    return MintResp(
        key=key,
        tier=plans.stored_tier(plan_for(uid)),  # legacy ids (3x/7x/15x) for app builds
        base_url=os.environ.get("PUBLIC_BASE_URL", "https://cloud.dhanuksoftwares.com/v1"),
    )





# ── usage: counts + per-model remaining (no prices shown to users) ──
AUTO_MODEL = plans.AUTO_MODEL
USAGE_CACHE_S = int(os.environ.get("USAGE_CACHE_S", "15"))
IMAGE_CALL_TYPES = {"image_generation", "aimage_generation", "image_edit", "aimage_edit",
                    "image_variation", "aimage_variation"}
IMAGE_MODES = {"image_generation", "image_edit"}


def _parse_time(v) -> datetime.datetime | None:
    if isinstance(v, datetime.datetime):
        t = v
    elif isinstance(v, str) and v:
        try:
            t = datetime.datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    return t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)


def _iso(t: datetime.datetime) -> str:
    return t.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _token_id(key_id: str) -> str:
    """Spend logs store the hashed key; legacy raw sk- ids are hashed here."""
    return hashlib.sha256(key_id.encode()).hexdigest() if key_id.startswith("sk-") else key_id


def _price(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f > 0 else None


def _suffix(model: str) -> str:
    return model.split("/", 1)[-1] if model else model


def model_catalog(c: httpx.Client, hidden: set | None = None) -> dict:
    """Owner-published models from LiteLLM /model/info, grouped by public name
    (the 'auto' group has one deployment per member model)."""
    data = []
    try:
        r = c.get("/model/info", headers=_admin_headers())
        if r.status_code == 200:
            data = r.json().get("data", []) or []
    except Exception as e:  # noqa: BLE001
        print(f"[mint] model/info error: {type(e).__name__}", flush=True)
    groups: dict = {}
    dep_underlying: dict = {}
    under_to_public: dict = {}
    for m in data:
        name = m.get("model_name") or ""
        if not name:
            continue
        info = m.get("model_info") or {}
        params = m.get("litellm_params") or {}
        under = str(params.get("model") or "")
        g = groups.setdefault(name, {
            "id": name, "name": name, "inputs": [], "outputs": [], "per_image": [],
            "modes": set(), "underlying": [], "legacy": {},
        })
        disp = info.get("display_name") or info.get("ovid_display_name")
        if disp:
            g["name"] = str(disp)
        for field, bucket in (("input_cost_per_token", "inputs"),
                              ("output_cost_per_token", "outputs"),
                              ("output_cost_per_image", "per_image")):
            p = _price(info.get(field))
            if p is not None:
                g[bucket].append(p)
        if info.get("mode"):
            g["modes"].add(str(info["mode"]))
        if under:
            g["underlying"].append(under)
        # Back-compat: the old /usage de-duped by name, last deployment wins.
        g["legacy"] = {"input_cost_per_token": info.get("input_cost_per_token"),
                       "output_cost_per_token": info.get("output_cost_per_token")}
        if info.get("id"):
            dep_underlying[str(info["id"])] = under
        if under and name != AUTO_MODEL and name not in (hidden or ()):
            under_to_public.setdefault(under, name)
            under_to_public.setdefault(_suffix(under), name)
    return {"groups": groups, "dep_underlying": dep_underlying, "under_to_public": under_to_public}


def _public_for(cat: dict, under: str) -> str | None:
    if not under:
        return None
    u2p = cat["under_to_public"]
    return u2p.get(under) or u2p.get(_suffix(under))


def _group_kind(g: dict | None) -> str:
    if not g:
        return "chat"
    if g["modes"] & IMAGE_MODES or (g["per_image"] and not g["inputs"]):
        return "image"
    return "chat"


def attribute_row(row: dict, cat: dict) -> tuple[str, bool]:
    """(public model id, via_auto) for one LiteLLM spend-log row. Requests made
    with 'auto' are attributed to the member model LiteLLM actually used when
    it logged it, else to 'auto'."""
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    group = str(row.get("model_group") or meta.get("model_group") or "")
    under = str(row.get("model") or "")
    if not under and row.get("model_id"):
        under = cat["dep_underlying"].get(str(row["model_id"]), "")
    groups = cat["groups"]
    if group and group in cat.get("auto_groups", {AUTO_MODEL}):
        return (_public_for(cat, under) or AUTO_MODEL), True
    if group in groups:
        return group, False
    pub = _public_for(cat, under)
    if pub:
        return pub, False
    if under in groups:
        return under, False
    return (group or under or "unknown"), False




def _unit_cost(g: dict, settings: dict, measured_img: dict) -> float | None:
    """Estimated USD per typical message (chat) or per image, at THIS model's
    LiteLLM price (most expensive deployment when a name has several)."""
    if _group_kind(g) == "image":
        if g["per_image"]:
            return max(g["per_image"])
        if g["outputs"]:
            toks = measured_img.get(g["id"]) or settings["est_image_tokens"]
            return max(g["outputs"]) * toks
        return None
    cost = ((max(g["inputs"]) if g["inputs"] else 0.0) * settings["est_input_tokens"]
            + (max(g["outputs"]) if g["outputs"] else 0.0) * settings["est_output_tokens"])
    return cost if cost > 0 else None




def _spend_logs(c: httpx.Client, token: str, start: datetime.datetime,
                now: datetime.datetime) -> list[dict]:
    try:
        r = c.get("/spend/logs", headers=_admin_headers(), params={
            "api_key": token,
            "start_date": start.strftime("%Y-%m-%d"),
            "end_date": (now + datetime.timedelta(days=1)).strftime("%Y-%m-%d"),
        })
    except Exception as e:  # noqa: BLE001
        print(f"[mint] spend/logs error: {type(e).__name__}", flush=True)
        return []
    if r.status_code != 200:
        return []
    data = r.json()
    rows = data if isinstance(data, list) else (data.get("data") or [])
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("api_key") not in (None, "", token):
            continue
        t = _parse_time(row.get("startTime") or row.get("start_time"))
        if t is not None and t < start:
            continue
        out.append(row)
    return out




def catalog_for(c: httpx.Client, s: dict) -> dict:
    hidden = {s["auto_oss_group"]} if s.get("auto_oss_group") else set()
    cat = model_catalog(c, hidden)
    cat["auto_groups"] = {AUTO_MODEL} | hidden
    cat["hidden"] = hidden
    return cat


def refresh_public_map(cat: dict | None = None) -> None:
    """Publish underlying-model → public-name for the LiteLLM hook, which
    attributes auto requests by the served model's class."""
    if cat is None:
        with litellm_client(15) as c:
            cat = catalog_for(c, get_settings())
    if not cat["groups"]:
        return
    blob = json.dumps(cat["under_to_public"], sort_keys=True)
    if rds.get(plans.PUBLIC_MAP_KEY) != blob:
        rds.set(plans.PUBLIC_MAP_KEY, blob)


def count_usage(rows: list[dict], cat: dict, s: dict | None = None) -> tuple[dict, float, dict, dict]:
    """(window counts, logged spend USD, measured avg image tokens per model,
    spend per class {oss, frontier})."""
    s = s or get_settings()
    today = {"requests": 0, "input_tokens": 0, "output_tokens": 0, "images": 0,
             "auto_requests": 0, "by_model": {}}
    spend = 0.0
    by_class = {"oss": 0.0, "frontier": 0.0}
    img_tokens: dict = {}
    for row in rows:
        if str(row.get("status") or "success").lower() == "failure":
            continue
        mid, via_auto = attribute_row(row, cat)
        call_type = str(row.get("call_type") or "")
        is_image = call_type in IMAGE_CALL_TYPES or _group_kind(cat["groups"].get(mid)) == "image"
        pin = _int_or(row.get("prompt_tokens"), 0)
        pout = _int_or(row.get("completion_tokens"), 0)
        cost = _float_or(row.get("spend"), 0.0)
        spend += cost
        if is_image:
            cls = "frontier"
        elif mid in cat["groups"] and mid not in cat.get("auto_groups", {AUTO_MODEL}):
            cls = plans.model_class(mid, s)
        else:
            cls = "frontier"  # auto with an unknown member: conservative
        by_class[cls] += cost
        bm = today["by_model"].setdefault(mid, {"requests": 0, "input_tokens": 0, "output_tokens": 0,
                                                "images": 0, "via_auto": 0, "class": cls})
        for d in (today, bm):
            d["requests"] += 1
            d["input_tokens"] += pin
            d["output_tokens"] += pout
            d["images"] += 1 if is_image else 0
        if via_auto:
            today["auto_requests"] += 1
            bm["via_auto"] += 1
        if is_image and pout > 0:
            img_tokens.setdefault(mid, []).append(pout)
    measured = {m: sum(v) / len(v) for m, v in img_tokens.items()}
    return today, spend, measured, by_class


def _pool_of(cls: str, pools: dict) -> str:
    if pools["kind"] == "shared":
        return "frontier" if cls == "frontier" else "all"
    return cls


def model_estimates(cat: dict, st: dict, pools: dict, settings: dict,
                    measured_img: dict | None = None, remaining_fraction: float = 0.0) -> list[dict]:
    """Per-model remaining messages/images, each from THAT model's pool and
    at THAT model's LiteLLM price. No money in display fields."""
    measured_img = measured_img or {}
    groups = cat["groups"]
    split = pools["kind"] == "split"

    def rem(pool):
        return st[pool]["remaining"]

    def count(pool, cost):
        return math.floor(max(0.0, rem(pool)) / cost + 1e-9)

    out = []
    for gid, g in groups.items():
        if gid in cat.get("hidden", ()):
            continue
        is_auto = gid == AUTO_MODEL
        kind = "chat" if is_auto else _group_kind(g)
        entry = {"id": gid, "name": g["name"], "kind": kind, "auto": is_auto, "estimate": "typical"}
        remaining = None
        if is_auto:
            members = sorted({p for u in g["underlying"] for p in [_public_for(cat, u)]
                              if p and p in groups and p not in cat.get("auto_groups", ())})
            entry["class"] = "auto"
            entry["estimate"] = "conservative"
            if split and settings.get("auto_oss_group"):
                members = [m for m in members if plans.model_class(m, settings) == "oss"]
                pool = "oss"
            else:
                pool = "mixed" if split else "all"
            entry["members"] = members
            costed = [(m, _unit_cost(groups[m], settings, measured_img)) for m in members]
            costed = [(m, c) for m, c in costed if c]
            priced = bool(costed)
            if priced and pool == "mixed":
                remaining = min(count(_pool_of(plans.model_class(m, settings), pools), c) for m, c in costed)
            elif priced:
                remaining = count(pool, max(c for _, c in costed))
            entry["slow_mode"] = bool(split and st["slow_mode"] and pool in ("oss", "mixed"))
        else:
            cls = "frontier" if kind == "image" else plans.model_class(gid, settings)
            pool = _pool_of(cls, pools)
            entry["class"] = cls
            cost = _unit_cost(g, settings, measured_img)
            priced = cost is not None and cost > 0
            if priced:
                remaining = count(pool, cost)
            entry["slow_mode"] = bool(split and cls == "oss" and st["slow_mode"])
        entry["pool"] = pool
        entry["priced"] = priced
        entry["remaining_images" if kind == "image" else "remaining_messages"] = remaining
        # Back-compat fields read by current app builds (prices are parsed but
        # never rendered there). Not for display.
        entry["model"] = gid
        entry["input_cost_per_token"] = g["legacy"].get("input_cost_per_token")
        entry["output_cost_per_token"] = g["legacy"].get("output_cost_per_token")
        entry["remaining_pct"] = round(remaining_fraction, 4)
        out.append(entry)
    out.sort(key=lambda e: (not e["auto"], e["kind"] != "chat", e["name"].lower()))
    return out


def compute_usage(uid: str) -> tuple[dict, dict]:
    """(public /usage body, admin-only detail). Spend comes from LiteLLM for
    ALL of the user's keys (android + web) plus the hook's pool counters."""
    s = get_settings()
    plan = plan_for(uid, s)
    pools = plans.user_pools(s, plan, user_free_daily(uid, s), user_pool_override(uid))
    keys = user_key_ids(uid)
    key_detail = []
    rows: list[dict] = []
    now = _now()
    start = current_window_start(uid, pools)
    # No live window: look back one window length; the window then starts at
    # the earliest request found (or now when there is none).
    since = start or now - datetime.timedelta(hours=pools["window_hours"])
    with litellm_client(15) as c:
        for ns, kid in keys.items():
            info = _key_info(c, kid)
            d = {"platform": "web" if ns else "android", "present": True}
            if info is not None:
                d.update(spend_usd=_float_or(info.get("spend"), 0.0),
                         max_budget_usd=info.get("max_budget"),
                         budget_duration=info.get("budget_duration"),
                         budget_reset_at=info.get("budget_reset_at"),
                         rpm_limit=info.get("rpm_limit"),
                         max_parallel_requests=info.get("max_parallel_requests"),
                         blocked=bool(info.get("blocked")))
            key_detail.append(d)
            rows.extend(_spend_logs(c, _token_id(kid), since, now))
        if start is None:
            times = [t for t in (_parse_time(r.get("startTime") or r.get("start_time")) for r in rows) if t]
            start, _ = window_bounds(uid, pools, first_use=min(times) if times else now)
            rows = [r for r in rows
                    if (_parse_time(r.get("startTime") or r.get("start_time")) or now) >= start]
        resets_at = start + datetime.timedelta(hours=pools["window_hours"])
        cat = catalog_for(c, s)
        refresh_public_map(cat)
        month_free_spent = _month_spent_c(c, uid) if keys else 0.0
        today, log_spend, measured, by_class = count_usage(rows, cat, s)
        counters = hook_spend(uid)
        spend = {k: max(by_class[k], counters[k]) for k in plans.CLASSES}
        month_cap = free_cap_usd(uid)
        cap_left = (month_cap - month_free_spent) if plan["id"] == "free" else None
        st = plans.pool_state(pools, spend, cap_left)
        if pools["kind"] == "split":
            sync_slow_mode(c, uid, st["slow_mode"], resets_at)
        elif in_slow_mode(uid):
            sync_slow_mode(c, uid, False, resets_at)
    resets_iso = _iso(resets_at)

    def frac(p):
        return round(min(1.0, p["remaining"] / p["cap"]), 4) if p["cap"] > 0 else 0.0

    if pools["kind"] == "shared":
        budget, remaining = st["all"]["cap"], st["all"]["remaining"]
        pool_list = [
            {"class": "all", "remaining_fraction": frac(st["all"]), "resets_at": resets_iso, "slow_mode": False},
            {"class": "frontier", "remaining_fraction": frac(st["frontier"]), "resets_at": resets_iso,
             "slow_mode": False}]
    else:
        budget = st["oss"]["cap"] + st["frontier"]["cap"]
        remaining = st["oss"]["remaining"] + st["frontier"]["remaining"]
        pool_list = [
            {"class": "oss", "remaining_fraction": frac(st["oss"]), "resets_at": resets_iso,
             "slow_mode": bool(st["slow_mode"])},
            {"class": "frontier", "remaining_fraction": frac(st["frontier"]), "resets_at": resets_iso,
             "slow_mode": False}]
    spent = spend["oss"] + spend["frontier"]
    fraction = round(min(1.0, remaining / budget), 4) if budget > 0 else 0.0
    window = plans.window_str(pools["window_hours"])
    body = {
        "tier": plans.stored_tier(plan),
        "is_paid": plan["id"] != "free",
        # Back-compat / internal USD (never rendered by the app).
        "daily_spent_usd": round(spent, 6),
        "daily_budget_usd": round(budget, 6),
        "daily_remaining_usd": round(remaining, 6),
        "month_free_spent_usd": round(month_free_spent, 6),
        "month_free_cap_usd": round(month_cap, 6),
        "requests_today": today["requests"],
        "budget_window": window,
        "remaining_pct": fraction,
        # Display-safe fields (no money).
        "plan": plan["id"],
        "plan_name": plan["name"],
        "window": window,
        "resets_at": resets_iso,
        "today": today,
        "remaining_fraction": fraction,
        "pools": pool_list,
        "models": model_estimates(cat, st, pools, s, measured, fraction),
    }
    detail = {"keys": key_detail, "spend_usd": round(spent, 6), "logged_spend_usd": round(log_spend, 6),
              "spend_by_class_usd": {k: round(v, 6) for k, v in spend.items()},
              "hook_counters_usd": counters, "pools_usd": pools,
              "pool_state_usd": {k: v for k, v in st.items() if k != "slow_mode"},
              "slow_mode": bool(st["slow_mode"]),
              "window_start": _iso(start), "remaining_usd": round(remaining, 6)}
    return body, detail


class UsageResp(BaseModel):
    tier: str
    is_paid: bool
    # Server-authoritative spend numbers (USD) — internal, never rendered.
    daily_spent_usd: float
    daily_budget_usd: float
    daily_remaining_usd: float
    month_free_spent_usd: float
    month_free_cap_usd: float
    requests_today: int
    budget_window: str
    remaining_pct: float
    # Display-safe additions (see README "API contract").
    plan: str
    plan_name: str
    window: str
    resets_at: str
    today: dict
    remaining_fraction: float
    pools: list[dict]
    models: list[dict]


@app.post("/usage", response_model=UsageResp)
def usage(
    authorization: str = Header(...),
    x_firebase_appcheck: str = Header(default=""),
):
    """Server-authoritative usage for the signed-in user.

    Spend and counts are read from LiteLLM (the source of truth), NOT computed
    on the device. Users never see prices: availability is expressed as pool
    fractions and remaining messages / images per model.
    """
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer id token")
    id_token = authorization.split(" ", 1)[1]
    if APPCHECK_ENABLED and not x_firebase_appcheck:
        raise HTTPException(401, "missing app check token")
    verify_app_check(x_firebase_appcheck)
    claims = verify_google_id_token(id_token)
    uid = claims["sub"]
    remember_email(uid, claims.get("email"))
    if USAGE_CACHE_S > 0:
        cached = rds.get(f"usagecache:{uid}")
        if cached:
            return json.loads(cached)
    body, _ = compute_usage(uid)
    if USAGE_CACHE_S > 0:
        rds.set(f"usagecache:{uid}", json.dumps(body), ex=USAGE_CACHE_S)
    return body


@app.get("/plans")
def public_plans():
    """Enabled plans for the app's plan screen (subscription price is plan
    metadata, not model pricing). Ids and aliases match user:{uid}:tier."""
    s = get_settings()
    return {"plans": [{"id": p["id"], "name": p["name"], "price_usd": p["price_usd"],
                       "aliases": p["aliases"], "kind": p["kind"],
                       "window": plans.window_str(p["window_hours"])}
                      for p in s["plans"] if p["enabled"]]}


def _drop_usage_cache(uids) -> None:
    for uid in uids:
        rds.delete(f"usagecache:{uid}")



# ── admin (master-key protected; console is localhost / SSH-tunnel only) ──
def _require_admin(authorization: str) -> None:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing admin key")
    token = authorization.split(" ", 1)[1]
    if not hmac.compare_digest(token.encode(), LITELLM_MASTER_KEY.encode()):
        raise HTTPException(403, "not admin")


def _request_ip(request: Request | None) -> str:
    if request is None:
        return "unknown"
    xff = request.headers.get("x-forwarded-for", "")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def audit(request: Request | None, action: str, target=None, before=None, after=None,
          result=None) -> dict:
    """Append-only admin audit trail: Redis list (newest first, capped for the
    console) + an append-only JSONL file on the mint volume (never trimmed)."""
    entry = {"ts": _now_iso(), "action": action, "actor": "master-key",
             "ip": _request_ip(request), "target": target, "before": before,
             "after": after, "result": result}
    line = json.dumps(entry, sort_keys=True, default=str)
    try:
        rds.lpush(AUDIT_LIST, line)
        rds.ltrim(AUDIT_LIST, 0, AUDIT_MAX - 1)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] audit redis error: {type(e).__name__}", flush=True)
    path = _state_path("admin-audit.jsonl")
    if path:
        try:
            with open(path, "a") as f:
                f.write(line + "\n")
        except OSError as e:
            print(f"[mint] audit file error: {type(e).__name__}", flush=True)
    return entry




def _user_state(uid: str) -> dict:
    return {"tier": rds.get(f"user:{uid}:tier") or "free",
            "plan": effective_tier(uid),
            "daily_usd_override": rds.get(f"user:{uid}:dailyUsd"),
            "monthly_cap_override": rds.get(f"user:{uid}:monthlyCapUsd"),
            "pools_override": user_pool_override(uid),
            "banned": rds.get(f"user:{uid}:banned")}


class AdminAction(BaseModel):
    uid: str | None = None
    ip: str | None = None
    tier: str | None = None                 # plan id or alias
    daily_usd: float | None = None          # custom FREE allowance per 24h
    monthly_cap_usd: float | None = None    # custom free monthly backstop
    pools: dict | None = None               # custom plan pools (mult, frontier_share, oss_usd, frontier_usd, window_hours)
    clear_daily_usd: bool = False
    clear_monthly_cap_usd: bool = False
    clear_pools: bool = False



def _set_key_blocked(uid: str, blocked: bool) -> None:
    for ns in KEY_NAMESPACES:
        _set_one_key_blocked(uid, ns, blocked)


def _set_one_key_blocked(uid: str, ns: str, blocked: bool) -> None:
    key = rds.get(f"user:{uid}:{ns}keyid")
    if not key:
        return
    try:
        with litellm_client(15) as c:
            r = c.post("/key/block" if blocked else "/key/unblock",
                       headers=_admin_headers(), json={"key": key})
        print(f"[mint] key {'block' if blocked else 'unblock'} {r.status_code} for {uid[:6]}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] key block error: {type(e).__name__}", flush=True)


@app.post("/admin/ban")
def admin_ban(body: AdminAction, request: Request, authorization: str = Header(default="")):
    _require_admin(authorization)
    if body.uid:
        rds.set(f"user:{body.uid}:banned", "admin")
        _set_key_blocked(body.uid, True)
    if body.ip:
        rds.setex(f"ban:ip:{body.ip}", 30 * 24 * 3600, "admin")
    audit(request, "ban", {"uid": body.uid, "ip": body.ip})
    return {"ok": True}


@app.post("/admin/unban")
def admin_unban(body: AdminAction, request: Request, authorization: str = Header(default="")):
    _require_admin(authorization)
    if body.uid:
        rds.delete(f"user:{body.uid}:banned")
        _set_key_blocked(body.uid, False)
    if body.ip:
        rds.delete(f"ban:ip:{body.ip}")
    audit(request, "unban", {"uid": body.uid, "ip": body.ip})
    return {"ok": True}



def _validate_pool_override(p: dict) -> dict:
    out = {}
    for f, v in p.items():
        if f not in plans.POOL_OVERRIDE_FIELDS:
            raise HTTPException(400, f"unknown pool field {f!r}")
        if v is None:
            continue
        lo, hi, _kinds = plans.PLAN_NUMBERS[f]
        try:
            out[f] = plans._bounded(f, v, lo, hi)
        except ValueError as e:
            raise HTTPException(400, str(e))
    if "window_hours" in out:
        out["window_hours"] = int(out["window_hours"])
    return out


def _bad_request(fn, *a):
    try:
        return fn(*a)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.post("/admin/set-tier")
@app.post("/admin/user/update")
def admin_set_tier(body: AdminAction, request: Request, authorization: str = Header(default="")):
    """Change one user's plan and/or per-user overrides (custom free limit,
    custom monthly backstop, custom plan pools), then re-apply the user's
    budgets to all of their keys (android + web)."""
    _require_admin(authorization)
    if not body.uid:
        raise HTTPException(400, "uid required")
    uid = body.uid.strip()
    s = get_settings()
    plan = None
    if body.tier:
        plan = plans.find_plan(s, body.tier)
        if body.tier not in (plan["id"], *plan["aliases"]):
            raise HTTPException(400, "unknown plan")
    for name, v in (("daily_usd", body.daily_usd), ("monthly_cap_usd", body.monthly_cap_usd)):
        if v is not None and (v < 0 or math.isnan(v)):
            raise HTTPException(400, f"{name} must be >= 0")
    pools_override = _validate_pool_override(body.pools) if body.pools else None
    before = _user_state(uid)
    if plan:
        rds.set(f"user:{uid}:tier", plans.stored_tier(plan))
    if body.clear_daily_usd:
        rds.delete(f"user:{uid}:dailyUsd")
    elif body.daily_usd is not None:
        rds.set(f"user:{uid}:dailyUsd", str(body.daily_usd))
    if body.clear_monthly_cap_usd:
        rds.delete(f"user:{uid}:monthlyCapUsd")
    elif body.monthly_cap_usd is not None:
        rds.set(f"user:{uid}:monthlyCapUsd", str(body.monthly_cap_usd))
    if body.clear_pools:
        rds.delete(f"user:{uid}:pools")
    elif pools_override:
        rds.set(f"user:{uid}:pools", json.dumps(pools_override, sort_keys=True))
    with litellm_client(15) as c:
        res = reapply_user(c, uid)
    _drop_usage_cache([uid])
    after = _user_state(uid)
    audit(request, "set-user", uid, before, after, res)
    return {"ok": True, "user": after, "reapplied": res}


def _apply_settings(request: Request | None, changes: dict, reapply: bool, action: str,
                    target="global") -> dict:
    before = get_settings()
    merged = dict(before)
    for k, v in changes.items():
        if v is None:
            continue
        if k not in merged:
            raise HTTPException(400, f"unknown setting {k!r}")
        merged[k] = v
    after = _bad_request(store_settings, merged)
    result = reapply_everyone() if reapply else {"mode": "skipped"}
    audit(request, action, target, before, after, result)
    return {"ok": True, "settings": get_settings(), "reapplied": result}


@app.get("/admin/settings")
def admin_get_settings(authorization: str = Header(default="")):
    _require_admin(authorization)
    status = rds.get(REAPPLY_STATUS_KEY)
    reset = rds.get(RESET_STATUS_KEY)
    return {"settings": get_settings(), "users": rds.scard(ALL_UIDS_SET),
            "scalars": {k: {"min": lo, "max": hi} for k, (_t, _s, lo, hi) in plans.SCALARS.items()},
            "reapply_status": json.loads(status) if status else None,
            "reset_status": json.loads(reset) if reset else None}


@app.post("/admin/settings")
def admin_set_settings(request: Request, payload: dict = Body(...), authorization: str = Header(default="")):
    """Partial update of any setting (free_daily_usd, scalars, oss_models,
    auto_oss_group, plans). Takes effect immediately and is re-applied to
    every key (android + web) and LiteLLM user budget."""
    _require_admin(authorization)
    payload = dict(payload)
    reapply = bool(payload.pop("reapply", True))
    return _apply_settings(request, payload, reapply, "settings")


@app.get("/admin/plans")
def admin_get_plans(authorization: str = Header(default="")):
    _require_admin(authorization)
    return {"plans": get_settings()["plans"]}


@app.post("/admin/plans")
def admin_upsert_plan(request: Request, payload: dict = Body(...), authorization: str = Header(default="")):
    """Add a plan or edit one (by id): name, price, enabled, aliases, kind,
    window_hours, mult/frontier_share (shared) or oss_usd/frontier_usd (split)."""
    _require_admin(authorization)
    payload = dict(payload)
    reapply = bool(payload.pop("reapply", True))
    pid = str(payload.get("id") or "")
    current = get_settings()["plans"]
    found = next((p for p in current if p["id"] == pid), None)
    new_plan = {**(found or {}), **payload}
    new_list = [new_plan if p["id"] == pid else p for p in current] if found else current + [new_plan]
    return _apply_settings(request, {"plans": new_list}, reapply,
                           "plan-edit" if found else "plan-add", pid)


@app.post("/admin/plans/{pid}/{action}")
def admin_plan_toggle(pid: str, action: str, request: Request, authorization: str = Header(default="")):
    _require_admin(authorization)
    if action not in ("enable", "disable"):
        raise HTTPException(404, "unknown action")
    current = get_settings()["plans"]
    if not any(p["id"] == pid for p in current):
        raise HTTPException(404, "unknown plan")
    new_list = [{**p, "enabled": action == "enable"} if p["id"] == pid else p for p in current]
    return _apply_settings(request, {"plans": new_list}, False, f"plan-{action}", pid)


@app.get("/admin/models")
def admin_models(authorization: str = Header(default="")):
    """Models LiteLLM publishes with their class (for the class editor). Admin
    only: includes LiteLLM prices."""
    _require_admin(authorization)
    s = get_settings()
    with litellm_client(15) as c:
        cat = catalog_for(c, s)
    out = []
    for gid, g in sorted(cat["groups"].items()):
        out.append({"id": gid, "name": g["name"], "kind": _group_kind(g),
                    "class": plans.model_class(gid, s), "hidden": gid in cat["hidden"],
                    "input_cost_per_token": max(g["inputs"]) if g["inputs"] else None,
                    "output_cost_per_token": max(g["outputs"]) if g["outputs"] else None,
                    "output_cost_per_image": max(g["per_image"]) if g["per_image"] else None,
                    "members": sorted({_public_for(cat, u) or u for u in g["underlying"]})
                    if gid in cat["auto_groups"] else None})
    return {"models": out, "oss_models": s["oss_models"], "auto_oss_group": s["auto_oss_group"]}


class BaseBudgetAction(BaseModel):
    daily_usd: float
    reapply: bool = True


@app.post("/admin/set-base-budget")
def admin_set_base_budget(body: BaseBudgetAction, request: Request,
                          authorization: str = Header(default="")):
    """Legacy: set the global FREE allowance per user per 24h."""
    _require_admin(authorization)
    if body.daily_usd < 0:
        raise HTTPException(400, "daily_usd must be >= 0")
    res = _apply_settings(request, {"free_daily_usd": body.daily_usd}, body.reapply, "set-base-budget")
    r = res["reapplied"]
    return {"ok": True, "base_daily_usd": body.daily_usd,
            "reapplied": r.get("keys", r.get("users", 0)), "detail": r}


class ResetAction(BaseModel):
    uid: str | None = None          # omit → ALL users (background when large)
    reset_month_free: bool = False  # also zero the free monthly backstop


def _reset(request: Request, body: ResetAction, action: str) -> dict:
    if body.uid:
        uid = body.uid.strip()
        with litellm_client(20) as c:
            res = {"mode": "sync", "users": 1, **reset_window_user(c, uid, body.reset_month_free)}
        target = uid
    else:
        res = run_for_everyone(RESET_STATUS_KEY,
                               lambda c, u: reset_window_user(c, u, body.reset_month_free))
        target = "ALL"
    audit(request, action, target, None, {"reset_month_free": body.reset_month_free}, res)
    return {"ok": True, "reset": res.get("keys", 0), "detail": res}


@app.post("/admin/reset-window")
def admin_reset_window(body: ResetAction, request: Request, authorization: str = Header(default="")):
    """Restart the 24h (plan) window NOW for one user (uid) or ALL users:
    pool counters and slow mode cleared, spend zeroed on every key (android +
    web), LiteLLM budget clocks restarted, budgets re-applied."""
    _require_admin(authorization)
    return _reset(request, body, "reset-window")


@app.post("/admin/reset-usage")
def admin_reset_usage(request: Request, body: dict = Body(default={}),
                      authorization: str = Header(default="")):
    """Legacy name: a window reset that also zeroes the monthly backstop."""
    _require_admin(authorization)
    act = ResetAction(uid=body.get("uid"), reset_month_free=body.get("reset_month_free", True))
    return _reset(request, act, "reset-usage")


@app.get("/admin/reset-status")
def admin_reset_status(authorization: str = Header(default="")):
    _require_admin(authorization)
    status = rds.get(RESET_STATUS_KEY)
    return json.loads(status) if status else {"state": "never"}


@app.get("/admin/user")
def admin_user(q: str, authorization: str = Header(default="")):
    """Look a user up by uid or email: plan, overrides, pools, window usage
    (requests, tokens, images, spend) and the per-model table exactly as the
    app sees it."""
    _require_admin(authorization)
    uid = _resolve_uid(q)
    if not uid:
        raise HTTPException(404, "user not found")
    body, detail = compute_usage(uid)
    s = get_settings()
    plan = plan_for(uid, s)
    return {
        "uid": uid,
        "email": rds.get(f"user:{uid}:email"),
        "tier": body["tier"],
        "plan": plan,
        "banned": rds.get(f"user:{uid}:banned"),
        "override_daily_usd": rds.get(f"user:{uid}:dailyUsd"),
        "override_monthly_cap_usd": rds.get(f"user:{uid}:monthlyCapUsd"),
        "override_pools": user_pool_override(uid),
        "free_daily_usd": user_free_daily(uid, s),
        "pools_usd": detail["pools_usd"],
        "pool_state_usd": detail["pool_state_usd"],
        "spend_by_class_usd": detail["spend_by_class_usd"],
        "slow_mode": detail["slow_mode"],
        "allowance_usd": body["daily_budget_usd"],
        "window": body["window"],
        "window_start": detail["window_start"],
        "resets_at": body["resets_at"],
        "today": {**body["today"], "spend_usd": detail["spend_usd"]},
        "month_spent_usd": body["month_free_spent_usd"],
        "month_cap_usd": body["month_free_cap_usd"],
        "remaining_usd": detail["remaining_usd"],
        "remaining_fraction": body["remaining_fraction"],
        "keys": detail["keys"],
        "app_view": body,
    }



def _resolve_uid(q: str) -> str | None:
    q = (q or "").strip()
    if not q:
        return None
    uid = rds.get(f"email:{q.lower()}") if "@" in q else q
    if not uid:
        return None
    if (rds.sismember(ALL_UIDS_SET, uid) or rds.exists(f"user:{uid}:tier")
            or user_key_ids(uid)):
        return uid
    return None




@app.get("/admin/audit")
def admin_audit(limit: int = 100, authorization: str = Header(default="")):
    _require_admin(authorization)
    limit = max(1, min(limit, AUDIT_MAX))
    return {"entries": [json.loads(x) for x in rds.lrange(AUDIT_LIST, 0, limit - 1)]}




@app.get("/admin/reapply-status")
def admin_reapply_status(authorization: str = Header(default="")):
    _require_admin(authorization)
    status = rds.get(REAPPLY_STATUS_KEY)
    return json.loads(status) if status else {"state": "never"}


@app.post("/admin/sweep")
def admin_sweep(request: Request, authorization: str = Header(default="")):
    """Run the slow-mode sweep now (it also runs in the background)."""
    _require_admin(authorization)
    return sweep_slow_mode()


@app.get("/admin/export")
def admin_export(authorization: str = Header(default="")):
    """Backup of the Redis-only entitlements (L8): settings, plans, overrides,
    bans and emails for every known user. Save it off-box."""
    _require_admin(authorization)
    users = {}
    for uid in sorted(rds.smembers(ALL_UIDS_SET)):
        st = _user_state(uid)
        st["email"] = rds.get(f"user:{uid}:email")
        users[uid] = st
    return {"exported_at": _now_iso(), "settings": get_settings(), "users": users}



# ── Admin web page (localhost / SSH-tunnel only — NOT routed publicly) ──
# Served by mint on port 8090. Caddy's public vhost does NOT route /admin, so
# the console is reachable only through an SSH tunnel to 127.0.0.1:8090. It is
# a pure client of the /admin JSON API, authorized with the master key pasted
# into the tab (kept in memory only).
_ADMIN_HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=referrer content=no-referrer>
<title>Ovid Admin</title>
<style>
 body{font:14px/1.5 system-ui,sans-serif;max-width:1180px;margin:0 auto;padding:24px;background:#0d1117;color:#e6edf3}
 h1{font-size:20px}h2{font-size:14px;margin:26px 0 8px;color:#8b949e;text-transform:uppercase;letter-spacing:.08em}
 .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:16px;margin:10px 0;overflow-x:auto}
 label{display:block;font-size:12px;color:#8b949e;margin:8px 0 4px}
 input,select{width:100%;box-sizing:border-box;padding:7px;border-radius:7px;border:1px solid #30363d;background:#0d1117;color:#e6edf3;font-size:13px}
 input[type=checkbox]{width:auto}
 button{margin:10px 8px 0 0;padding:8px 13px;border:0;border-radius:8px;background:#2f81f7;color:#fff;font-size:13px;font-weight:600;cursor:pointer}
 button.danger{background:#da3633}button.ghost{background:#30363d}button.sm{margin:0;padding:5px 9px}
 .row{display:flex;gap:10px;flex-wrap:wrap}.row>div{flex:1;min-width:130px}
 .out{margin-top:10px;font-size:12px;color:#7ee787;white-space:pre-wrap;font-family:ui-monospace,monospace}
 .err{color:#ff7b72}.muted{color:#8b949e;font-size:12px}
 table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px}
 th,td{text-align:left;padding:5px 6px;border-bottom:1px solid #30363d;vertical-align:top}
 th{color:#8b949e;font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums}
 td input,td select{min-width:70px}
 .kv{display:grid;grid-template-columns:210px 1fr;gap:4px 12px;font-size:13px}.kv div:nth-child(odd){color:#8b949e}
</style></head><body>
<h1>Ovid Cloud — Admin</h1>
<div class=card>
 <label>Master key (stays in this tab only)</label>
 <input id=mk type=password placeholder="sk-..." autocomplete=off>
 <button onclick=loadAll()>Load</button>
 <div class=muted>Every number below is live: saving takes effect immediately (no restart), is re-applied to all affected keys (android + web) and is written to the audit log.</div>
</div>

<h2>Global limits</h2>
<div class=card>
 <div class=row>
  <div><label>Free allowance per user per 24h (USD)</label><input id=g_free_daily_usd type=number step=0.01 min=0></div>
  <div><label>Free monthly backstop per user (USD / 30 days)</label><input id=g_free_monthly_cap_usd type=number step=0.01 min=0></div>
  <div><label>Key ceiling for split plans (× oss pool + frontier)</label><input id=g_hard_ceiling_mult type=number step=0.1 min=1></div>
 </div>
 <div class=muted>The monthly backstop is a second cap on free users across all their keys: with a high daily amount it stops a heavy user after a few days (e.g. $3/day with a $10 backstop: day 4). <span id=backstopNote></span></div>
 <div class=row>
  <div><label>Normal rpm</label><input id=g_normal_rpm type=number min=1></div>
  <div><label>Normal tpm</label><input id=g_normal_tpm type=number min=1></div>
  <div><label>Normal parallel</label><input id=g_normal_parallel type=number min=1></div>
  <div><label>Slow-mode rpm</label><input id=g_slow_rpm type=number min=1></div>
  <div><label>Slow-mode tpm</label><input id=g_slow_tpm type=number min=1></div>
  <div><label>Slow-mode parallel</label><input id=g_slow_parallel type=number min=1></div>
 </div>
 <div class=row>
  <div><label>Typical message: input tokens</label><input id=g_est_input_tokens type=number min=1></div>
  <div><label>Typical message: output tokens</label><input id=g_est_output_tokens type=number min=1></div>
  <div><label>Typical image: output tokens</label><input id=g_est_image_tokens type=number min=1></div>
  <div><label>Oss-only auto group for split plans (LiteLLM model group, empty = off)</label><input id=g_auto_oss_group></div>
 </div>
 <button onclick=saveGlobal()>Save global limits</button>
 <div class=out id=globalOut></div>
</div>

<h2>Plans</h2>
<div class=card>
 <div class=muted>Amounts are USD per 24h and scale with the window (720h = 30 days → ×30). Shared plans: allowance = user's free allowance × mult, frontier capped at frontier share. Split plans: oss fair-use pool (over it → slow mode) + frontier pool (exhausted → frontier_limit_reached). Price is admin/plan-screen metadata only. Disable = stop selling; users already on it keep it.</div>
 <table><thead><tr><th>id</th><th>name</th><th>price $</th><th>on</th><th>aliases</th><th>kind</th><th>window h</th><th>mult</th><th>frontier share</th><th>oss $/24h</th><th>frontier $/24h</th><th></th></tr></thead><tbody id=planRows></tbody></table>
 <button class=ghost onclick=addPlanRow()>Add plan</button>
 <div class=out id=planOut></div>
</div>

<h2>Model classes</h2>
<div class=card>
 <div class=muted>oss = open-source fair-use pool; frontier = everything else (images are always frontier). Auto is counted by the model that served each request.</div>
 <table><thead><tr><th>Model</th><th>Kind</th><th>Class</th><th>In $/tok</th><th>Out $/tok</th><th>$/image</th></tr></thead><tbody id=classRows></tbody></table>
 <button onclick=saveClasses()>Save classes</button>
 <div class=out id=classOut></div>
</div>

<h2>User</h2>
<div class=card>
 <div class=row><div><label>uid or email</label><input id=q placeholder="firebase uid or user@gmail.com" onkeydown="if(event.key==='Enter')lookup()"></div></div>
 <button onclick=lookup()>Look up</button>
 <div class=out id=userOut></div>
 <div id=userBox style="display:none">
  <div class=kv id=userKv style="margin-top:12px"></div>
  <h2>Models as the app sees them</h2>
  <table><thead><tr><th>Model</th><th>Class / pool</th><th class=num>Remaining</th><th>Estimate</th><th class=num>Requests</th><th class=num>Tokens in / out</th><th class=num>Images</th></tr></thead><tbody id=modelRows></tbody></table>
  <h2>Change this user</h2>
  <div class=row>
   <div><label>Plan</label><select id=u_tier></select></div>
   <div><label>Custom free limit (USD / 24h)</label><input id=u_daily type=number step=0.01 min=0></div>
   <div><label>Custom monthly backstop (USD)</label><input id=u_cap type=number step=0.01 min=0></div>
  </div>
  <div class=row>
   <div><label>Custom pool: mult</label><input id=u_p_mult type=number step=0.1 min=0></div>
   <div><label>frontier share</label><input id=u_p_frontier_share type=number step=0.01 min=0 max=1></div>
   <div><label>oss $/24h</label><input id=u_p_oss_usd type=number step=0.01 min=0></div>
   <div><label>frontier $/24h</label><input id=u_p_frontier_usd type=number step=0.01 min=0></div>
   <div><label>window hours</label><input id=u_p_window_hours type=number min=1></div>
  </div>
  <button onclick=saveUser()>Save plan + overrides</button>
  <button class=ghost onclick="clearUser('clear_daily_usd')">Clear custom free limit</button>
  <button class=ghost onclick="clearUser('clear_monthly_cap_usd')">Clear custom backstop</button>
  <button class=ghost onclick="clearUser('clear_pools')">Clear custom pools</button>
  <br><button class=ghost onclick=resetUser()>Reset window now</button>
  <label style="display:inline"><input type=checkbox id=u_month> also reset monthly backstop</label>
  <button class=danger onclick=banUser(true)>Ban</button>
  <button class=ghost onclick=banUser(false)>Unban</button>
  <div class=out id=userActOut></div>
 </div>
</div>

<h2>All users</h2>
<div class=card>
 <button class=danger onclick=resetAll()>Reset window for ALL users now</button>
 <label style="display:inline"><input type=checkbox id=all_month> also reset monthly backstops</label>
 <div class=out id=resetStatus></div>
 <div class=row><div><label>IP</label><input id=banIp></div></div>
 <button class=danger onclick=ipBan(true)>Ban IP (30 days)</button>
 <button class=ghost onclick=ipBan(false)>Unban IP</button>
 <div class=out id=miscOut></div>
</div>

<h2>Audit log</h2>
<div class=card>
 <button class=ghost onclick=loadAudit()>Refresh</button>
 <table><thead><tr><th>When (UTC)</th><th>Action</th><th>Target</th><th>Change</th></tr></thead><tbody id=auditRows></tbody></table>
</div>

<script>
const $=id=>document.getElementById(id);
const GLOBAL=['free_daily_usd','free_monthly_cap_usd','hard_ceiling_mult','normal_rpm','normal_tpm','normal_parallel','slow_rpm','slow_tpm','slow_parallel','est_input_tokens','est_output_tokens','est_image_tokens','auto_oss_group'];
const PFIELDS=['mult','frontier_share','oss_usd','frontier_usd','window_hours'];
let current=null, settings=null, models=[];
function mk(){return $('mk').value.trim()}
async function api(method,path,body){
 const r=await fetch(path,{method,headers:{'Authorization':'Bearer '+mk(),'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const t=await r.text(); let j=null; try{j=JSON.parse(t)}catch(e){}
 if(!r.ok) throw new Error(r.status+' '+(j&&j.detail?JSON.stringify(j.detail):t));
 return j;
}
function show(id,v,err){const o=$(id);o.className='out'+(err?' err':'');o.textContent=typeof v==='string'?v:JSON.stringify(v,null,1)}
function el(tag,attrs,text){const e=document.createElement(tag);for(const k in (attrs||{}))e[k]=attrs[k];if(text!==undefined)e.textContent=text;return e}
function cell(tr,v,cls){const td=el('td',{},(v===null||v===undefined)?'—':String(v));if(cls)td.className=cls;tr.appendChild(td);return td}
function num(v){v=String(v).trim();return v===''?null:Number(v)}
function money(v){return '$'+Number(v||0).toFixed(2)}
async function loadAll(){await loadSettings();await loadModels();await loadAudit();pollReset()}
async function loadSettings(){
 try{const j=await api('GET','/admin/settings');settings=j.settings;
  for(const k of GLOBAL)$('g_'+k).value=settings[k];
  const f=settings.free_daily_usd,c=settings.free_monthly_cap_usd;
  $('backstopNote').textContent=f>0&&c>0?'Now: '+money(f)+'/day and '+money(c)+'/30 days, so a user spending the full daily amount stops after about '+Math.ceil(c/f)+' day(s).':'';
  renderPlans();
  const sel=$('u_tier');sel.textContent='';for(const p of settings.plans)sel.appendChild(el('option',{value:p.id},p.name+' ('+p.id+(p.aliases.length?' / '+p.aliases.join(','):'')+')'+(p.enabled?'':' [disabled]')));
  show('globalOut',j.users+' known users');
 }catch(e){show('globalOut',String(e),true)}
}
async function saveGlobal(){
 const b={reapply:true};for(const k of GLOBAL){const v=$('g_'+k).value;b[k]=k==='auto_oss_group'?v.trim():num(v)}
 try{const j=await api('POST','/admin/settings',b);show('globalOut',{saved:true,reapplied:j.reapplied});loadSettings();loadAudit()}catch(e){show('globalOut',String(e),true)}
}
function planRow(p,isNew){
 const tr=el('tr');const inp=(k,type,v)=>{const td=el('td');const i=el('input',{type:type||'text',value:v??''});i.dataset.k=k;if(type==='number')i.step='any';td.appendChild(i);tr.appendChild(td);return i};
 const id=inp('id','text',p.id);if(!isNew)id.readOnly=true;
 inp('name','text',p.name);inp('price_usd','number',p.price_usd);
 const td=el('td');const cb=el('input',{type:'checkbox',checked:p.enabled!==false});cb.dataset.k='enabled';td.appendChild(cb);tr.appendChild(td);
 inp('aliases','text',(p.aliases||[]).join(','));
 const tk=el('td');const sel=el('select');sel.dataset.k='kind';for(const k of ['shared','split'])sel.appendChild(el('option',{value:k,selected:p.kind===k},k));tk.appendChild(sel);tr.appendChild(tk);
 inp('window_hours','number',p.window_hours);inp('mult','number',p.mult);inp('frontier_share','number',p.frontier_share);inp('oss_usd','number',p.oss_usd);inp('frontier_usd','number',p.frontier_usd);
 const ts=el('td');const b=el('button',{className:'sm'},'Save');b.onclick=()=>savePlan(tr);ts.appendChild(b);tr.appendChild(ts);
 return tr;
}
function renderPlans(){const tb=$('planRows');tb.textContent='';for(const p of settings.plans)tb.appendChild(planRow(p,false))}
function addPlanRow(){$('planRows').appendChild(planRow({kind:'split',window_hours:24,enabled:false,aliases:[]},true))}
async function savePlan(tr){
 const b={reapply:true};for(const i of tr.querySelectorAll('[data-k]')){const k=i.dataset.k;
  if(k==='enabled')b[k]=i.checked;else if(k==='aliases')b[k]=i.value.split(',').map(x=>x.trim()).filter(Boolean);
  else if(['id','name','kind'].includes(k))b[k]=i.value.trim();else{const v=num(i.value);if(v!==null)b[k]=v}}
 try{const j=await api('POST','/admin/plans',b);show('planOut',{saved:b.id,reapplied:j.reapplied});loadSettings();loadAudit()}catch(e){show('planOut',String(e),true)}
}
async function loadModels(){
 try{const j=await api('GET','/admin/models');models=j.models;const tb=$('classRows');tb.textContent='';
  for(const m of models){if(m.hidden)continue;const tr=el('tr');cell(tr,m.name+(m.members?' (auto: '+m.members.join(', ')+')':''));cell(tr,m.kind);
   const td=el('td');if(m.members||m.kind==='image'){td.textContent=m.members?'by served model':'frontier'}else{const s=el('select');s.dataset.model=m.id;for(const c of ['oss','frontier'])s.appendChild(el('option',{value:c,selected:m.class===c},c));td.appendChild(s)}
   tr.appendChild(td);cell(tr,m.input_cost_per_token,'num');cell(tr,m.output_cost_per_token,'num');cell(tr,m.output_cost_per_image,'num');tb.appendChild(tr)}
 }catch(e){show('classOut',String(e),true)}
}
async function saveClasses(){
 const keep=(settings.oss_models||[]).filter(m=>!models.some(x=>x.id===m));
 const oss=[...keep,...[...document.querySelectorAll('#classRows select')].filter(s=>s.value==='oss').map(s=>s.dataset.model)];
 try{await api('POST','/admin/settings',{oss_models:oss,reapply:false});show('classOut','saved: '+oss.join(', '));loadSettings();loadAudit()}catch(e){show('classOut',String(e),true)}
}
async function lookup(){
 const q=$('q').value.trim();if(!q)return;
 try{current=await api('GET','/admin/user?q='+encodeURIComponent(q));renderUser();show('userOut','')}
 catch(e){$('userBox').style.display='none';show('userOut',String(e),true)}
}
function renderUser(){
 const u=current,t=u.today,kv=$('userKv');kv.textContent='';const ps=u.pool_state_usd;
 const pool=n=>ps[n]?money(ps[n].spent)+' of '+money(ps[n].cap)+' · left '+money(ps[n].remaining):'—';
 const rows=[['uid',u.uid],['email',u.email],['plan',u.plan.name+' ('+u.plan.id+', stored as '+u.tier+', '+u.plan.kind+')'],['banned',u.banned||'no'],
  ['free allowance / 24h',money(u.free_daily_usd)+(u.override_daily_usd!==null?' (custom)':' (global)')],
  ['custom pools',u.override_pools?JSON.stringify(u.override_pools):'none'],
  ['window',u.window+': '+u.window_start+' → '+u.resets_at],
  ['pool all',pool('all')],['pool oss',pool('oss')+(u.slow_mode?' · SLOW MODE':'')],['pool frontier',pool('frontier')],
  ['window usage',t.requests+' requests · '+t.input_tokens+' in / '+t.output_tokens+' out tokens · '+t.images+' images · '+t.auto_requests+' via auto · spend '+money(t.spend_usd)],
  ['monthly backstop',money(u.month_spent_usd)+' of '+money(u.month_cap_usd)+(u.override_monthly_cap_usd!==null?' (custom)':'')],
  ['app pools',u.app_view.pools.map(p=>p.class+' '+Math.round(p.remaining_fraction*100)+'%'+(p.slow_mode?' slow':'')).join(' · ')],
  ['keys',u.keys.map(k=>k.platform+': spend '+money(k.spend_usd)+' / '+(k.max_budget_usd??'?')+' per '+(k.budget_duration||'?')+' · rpm '+(k.rpm_limit??'?')+(k.blocked?' BLOCKED':'')).join(' · ')||'none']];
 for(const [k,v] of rows){kv.appendChild(el('div',{},k));kv.appendChild(el('div',{},v==null?'—':String(v)))}
 const tb=$('modelRows');tb.textContent='';
 for(const m of u.app_view.models){const tr=el('tr');const bm=t.by_model[m.id]||{};
  cell(tr,m.name+(m.auto?' (auto: '+(m.members||[]).join(', ')+')':''));cell(tr,m.class+' / '+m.pool+(m.slow_mode?' (slow)':''));
  cell(tr,!m.priced?'unpriced':(m.kind==='image'?m.remaining_images+' images':m.remaining_messages+' messages'),'num');
  cell(tr,m.estimate);cell(tr,bm.requests||0,'num');cell(tr,(bm.input_tokens||0)+' / '+(bm.output_tokens||0),'num');cell(tr,bm.images||0,'num');tb.appendChild(tr)}
 $('u_tier').value=u.plan.id;$('u_daily').value=u.override_daily_usd??'';$('u_cap').value=u.override_monthly_cap_usd??'';
 for(const f of PFIELDS)$('u_p_'+f).value=(u.override_pools||{})[f]??'';
 $('userBox').style.display='block';
}
async function userCall(b){try{show('userActOut',await api('POST','/admin/user/update',b));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
function saveUser(){
 if(!current)return;const b={uid:current.uid,tier:$('u_tier').value};
 const d=num($('u_daily').value),c=num($('u_cap').value);if(d!==null)b.daily_usd=d;if(c!==null)b.monthly_cap_usd=c;
 const p={};for(const f of PFIELDS){const v=num($('u_p_'+f).value);if(v!==null)p[f]=v}if(Object.keys(p).length)b.pools=p;
 userCall(b)
}
function clearUser(flag){if(current)userCall({uid:current.uid,[flag]:true})}
async function resetUser(){if(!current||!confirm('Restart the window now for '+current.uid+'?'))return;
 try{show('userActOut',await api('POST','/admin/reset-window',{uid:current.uid,reset_month_free:$('u_month').checked}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function banUser(on){if(!current)return;
 try{show('userActOut',await api('POST',on?'/admin/ban':'/admin/unban',{uid:current.uid}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function resetAll(){if(!confirm('Restart the window now for ALL users?'))return;
 try{show('resetStatus',await api('POST','/admin/reset-window',{reset_month_free:$('all_month').checked}));loadAudit();pollReset()}catch(e){show('resetStatus',String(e),true)}}
async function pollReset(){
 try{const s=await api('GET','/admin/reset-status');if(s.state==='never')return;
  show('resetStatus','Last global reset: '+s.state+' · '+s.done+'/'+s.total+' users'+(s.errors?' · '+s.errors+' errors':'')+' · '+(s.at||''));
  if(s.state==='running')setTimeout(pollReset,2000)}catch(e){}
}
async function ipBan(on){const ip=$('banIp').value.trim();if(!ip)return;
 try{show('miscOut',await api('POST',on?'/admin/ban':'/admin/unban',{ip}));loadAudit()}catch(e){show('miscOut',String(e),true)}}
async function loadAudit(){
 try{const j=await api('GET','/admin/audit?limit=200');const tb=$('auditRows');tb.textContent='';
  for(const e of j.entries){const tr=el('tr');cell(tr,e.ts);cell(tr,e.action);cell(tr,typeof e.target==='string'?e.target:JSON.stringify(e.target));
   cell(tr,JSON.stringify({before:e.before,after:e.after,result:e.result}));tb.appendChild(tr)}
 }catch(e){}
}
</script></body></html>"""


@app.get("/admin", response_class=HTMLResponse)
@app.get("/admin/ui", response_class=HTMLResponse)
def admin_ui():
    return HTMLResponse(_ADMIN_HTML, headers={
        "Cache-Control": "no-store",
        "X-Frame-Options": "DENY",
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; "
                                   "style-src 'unsafe-inline'; frame-ancestors 'none'",
    })


# ── Ovid image routes (mounted on this mint app; no separate service) ──
# Mounts /v1/images/* using this app's existing auth + Redis budget authority.
# Guarded so a missing key/config never blocks mint startup.
if os.environ.get("MINT_MOUNT_IMAGES", "true").lower() == "true":
    try:
        import images_gateway  # noqa: E402,F401
    except Exception as _image_mount_error:  # noqa: BLE001
        print(f"images_mount import skipped: {_image_mount_error}")


@app.on_event("startup")
def _start_monitors() -> None:
    try:
        restore_settings_if_missing()
        written = ensure_default_settings()
        if written:
            print(f"[mint] seeded unset settings: {', '.join(written)}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] settings init error: {type(e).__name__}", flush=True)
    if os.environ.get("MINT_SPEND_MONITOR", "true").lower() == "true":
        threading.Thread(target=_spend_monitor, daemon=True).start()
        threading.Thread(target=_sweeper, daemon=True).start()
