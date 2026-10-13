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
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from pydantic import BaseModel

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


# ── usage limits: owner-editable settings ──
#
# Every user has an independent allowance (never a shared pool):
#   free allowance  = user:{uid}:dailyUsd override, else the global free daily
#                     amount (config:base_daily_usd, seeded from BASE_DAILY_USD)
#   paid allowance  = that user's free allowance × the plan multiplier
#   paid window     = "30d" (monthly pool = allowance × 30, the original
#                     behaviour and the default) or "24h" (daily allowance)
#   free backstop   = LiteLLM user budget over 30d (FREE_MONTHLY_CAP_USD,
#                     admin-editable, per-user override user:{uid}:monthlyCapUsd)
# All of these are editable from the /admin console; every change is re-applied
# to every key (android + web) and to the LiteLLM user budget, and audited.
BASE_DAILY_USD = float(os.environ.get("BASE_DAILY_USD", "0.50"))
# Plan ids are fixed (they are stored on users and sold in the app); their
# multipliers are editable. TIER_MULT keeps the seed values for back-compat;
# the live values come from get_tier_mult().
TIER_MULT = {"free": 1, "3x": 3, "7x": 7, "15x": 15}
TIERS = {t: {"mult": m} for t, m in TIER_MULT.items()}
PAID_TIERS = ("3x", "7x", "15x")
PAID_WINDOWS = ("24h", "30d")
PAID_WINDOW_DEFAULT = os.environ.get("PAID_WINDOW", "30d")
if PAID_WINDOW_DEFAULT not in PAID_WINDOWS:
    PAID_WINDOW_DEFAULT = "30d"
# "Typical message" used to turn the remaining budget into a message count.
EST_INPUT_TOKENS = int(os.environ.get("EST_INPUT_TOKENS", "2000"))
EST_OUTPUT_TOKENS = int(os.environ.get("EST_OUTPUT_TOKENS", "600"))
# Output tokens of a typical image when a model has no per-image price.
EST_IMAGE_TOKENS = int(os.environ.get("EST_IMAGE_TOKENS", "1500"))
# Settings + audit mirrors on the mint volume (mintdata:/data), so a Redis loss
# does not lose the owner's limits or the audit trail.
MINT_STATE_DIR = os.environ.get("MINT_STATE_DIR", "/data")
# Above this many users a "re-apply to everyone" runs in the background.
REAPPLY_SYNC_MAX = int(os.environ.get("REAPPLY_SYNC_MAX", "200"))

# All known user ids (so an admin change can be re-applied to every existing
# user at once).
ALL_UIDS_SET = "ovid:uids"
BASE_BUDGET_KEY = "config:base_daily_usd"
LIMITS_HASH = "config:limits"          # mult:<tier>, paid_window, free_monthly_cap_usd, est_*
REAPPLY_STATUS_KEY = "config:reapply_status"
AUDIT_LIST = "audit:admin"
AUDIT_MAX = int(os.environ.get("AUDIT_MAX", "5000"))
KEY_NAMESPACES = ("", "web:")          # android key, web key
WINDOW_SECONDS = {"24h": 86400, "30d": 30 * 86400}


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


def get_base_daily() -> float:
    """Global free allowance per user per 24h (Redis), falling back to env."""
    return _float_or(rds.get(BASE_BUDGET_KEY), BASE_DAILY_USD)


def get_tier_mult() -> dict:
    out = dict(TIER_MULT)
    for t in PAID_TIERS:
        out[t] = _float_or(rds.hget(LIMITS_HASH, f"mult:{t}"), TIER_MULT[t])
    out["free"] = 1
    return out


def get_paid_window() -> str:
    w = rds.hget(LIMITS_HASH, "paid_window")
    return w if w in PAID_WINDOWS else PAID_WINDOW_DEFAULT


def get_free_monthly_cap() -> float:
    return _float_or(rds.hget(LIMITS_HASH, "free_monthly_cap_usd"), FREE_MONTHLY_CAP_USD)


def get_settings() -> dict:
    return {
        "free_daily_usd": get_base_daily(),
        "tier_mult": get_tier_mult(),
        "paid_window": get_paid_window(),
        "free_monthly_cap_usd": get_free_monthly_cap(),
        "est_input_tokens": _int_or(rds.hget(LIMITS_HASH, "est_input_tokens"), EST_INPUT_TOKENS),
        "est_output_tokens": _int_or(rds.hget(LIMITS_HASH, "est_output_tokens"), EST_OUTPUT_TOKENS),
        "est_image_tokens": _int_or(rds.hget(LIMITS_HASH, "est_image_tokens"), EST_IMAGE_TOKENS),
    }


def _store_settings(s: dict) -> None:
    rds.set(BASE_BUDGET_KEY, str(s["free_daily_usd"]))
    fields = {f"mult:{t}": str(s["tier_mult"][t]) for t in PAID_TIERS}
    fields.update({
        "paid_window": s["paid_window"],
        "free_monthly_cap_usd": str(s["free_monthly_cap_usd"]),
        "est_input_tokens": str(s["est_input_tokens"]),
        "est_output_tokens": str(s["est_output_tokens"]),
        "est_image_tokens": str(s["est_image_tokens"]),
    })
    rds.hset(LIMITS_HASH, mapping=fields)
    _persist_settings(s)


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
        _store_settings(_validate_settings(s))
        print("[mint] limits restored from volume mirror", flush=True)
        return True
    except (OSError, ValueError, HTTPException) as e:
        print(f"[mint] settings restore failed: {type(e).__name__}", flush=True)
        return False


def _validate_settings(s: dict) -> dict:
    def num(name, v, lo, hi):
        try:
            f = float(v)
        except (TypeError, ValueError):
            raise HTTPException(400, f"{name} must be a number")
        if not (lo <= f <= hi) or math.isnan(f):
            raise HTTPException(400, f"{name} must be between {lo} and {hi}")
        return f

    out = dict(s)
    out["free_daily_usd"] = num("free_daily_usd", s["free_daily_usd"], 0, 10000)
    out["free_monthly_cap_usd"] = num("free_monthly_cap_usd", s["free_monthly_cap_usd"], 0, 100000)
    mult = {"free": 1}
    for t in PAID_TIERS:
        mult[t] = num(f"tier_mult.{t}", s["tier_mult"].get(t, TIER_MULT[t]), 1, 1000)
    out["tier_mult"] = mult
    if s["paid_window"] not in PAID_WINDOWS:
        raise HTTPException(400, "paid_window must be '24h' or '30d'")
    for k in ("est_input_tokens", "est_output_tokens", "est_image_tokens"):
        out[k] = int(num(k, s[k], 1, 10_000_000))
    return out


def user_free_daily(uid: str) -> float:
    """This user's free allowance per 24h: per-user override or the global."""
    override = rds.get(f"user:{uid}:dailyUsd")
    if override not in (None, ""):
        try:
            return float(override)
        except (TypeError, ValueError):
            pass
    return get_base_daily()


def tier_daily(uid: str, tier: str) -> float:
    """Per-user daily amount = the user's FREE allowance × plan multiplier.
    (Fixes L2: an override is the user's free allowance and scales with the
    plan, instead of replacing the plan amount.)"""
    return user_free_daily(uid) * get_tier_mult().get(tier, 1)


def tier_budget(uid: str, tier: str) -> tuple[float, str]:
    """Return (max_budget, budget_duration) for a user.

    FREE: the free allowance per 24h. PAID: allowance × multiplier, either per
    24h (paid_window "24h") or as a 30-day pool of 30 × that amount
    (paid_window "30d", the default and the original behaviour).
    """
    amount = tier_daily(uid, tier)
    if tier == "free":
        return round(amount, 6), "24h"
    if get_paid_window() == "24h":
        return round(amount, 6), "24h"
    return round(amount * 30, 6), "30d"


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




# ── tier + free-cap ──
def effective_tier(uid: str) -> str:
    t = rds.get(f"user:{uid}:tier")
    return t if t in TIERS else "free"


def month_key(uid: str) -> str:
    """Legacy counter key (never written; kept so old deletes stay harmless)."""
    ym = _now().strftime("%Y-%m")
    return f"freecap:{uid}:{ym}"


def free_cap_usd(uid: str) -> float:
    return _float_or(rds.get(f"user:{uid}:monthlyCapUsd"), get_free_monthly_cap())


def month_spent(uid: str) -> float:
    """User-level spend over the current 30d window, from LiteLLM."""
    try:
        with litellm_client(10) as c:
            r = c.get("/user/info", headers=_admin_headers(), params={"user_id": uid})
        if r.status_code == 200:
            return float((r.json().get("user_info") or {}).get("spend") or 0.0)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user/info error: {type(e).__name__}", flush=True)
    return 0.0


def user_budget_target(uid: str, tier: str) -> tuple[float, str]:
    """LiteLLM user budget (enforced across all of the user's keys).
    Free: the monthly backstop per 30d. Paid: the same as the key budget."""
    if tier == "free":
        return free_cap_usd(uid), "30d"
    return tier_budget(uid, tier)


def ensure_user_budget(c: httpx.Client, headers: dict, uid: str, tier: str) -> None:
    budget, duration = user_budget_target(uid, tier)
    body = {"user_id": uid, "max_budget": budget}
    # Only send budget_duration when it changes: LiteLLM restarts the budget
    # clock (budget_reset_at = now + duration) whenever it is sent, so sending
    # it on every mint would keep pushing the reset out.
    current = None
    try:
        r = c.get("/user/info", headers=headers, params={"user_id": uid})
        if r.status_code == 200:
            current = (r.json().get("user_info") or {}).get("budget_duration")
        elif r.status_code != 404:
            current = "unknown"  # outage: don't touch the clock
    except Exception:  # noqa: BLE001
        current = "unknown"
    if current != duration and current != "unknown":
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
                     info: dict | None, extra: dict | None = None) -> bool:
    """Set a key's budget; send budget_duration only when it changes (see
    ensure_user_budget). Returns True when LiteLLM accepted the update."""
    body = {"key": key_id, "max_budget": budget, **(extra or {})}
    if info is not None and info.get("budget_duration") != duration:
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


def reapply_user(c: httpx.Client, uid: str, extra: dict | None = None) -> dict:
    """Re-apply this user's budgets to EVERY key (android + web — fixes L3) and
    to the LiteLLM user budget. `extra` adds fields to each key update (e.g.
    spend=0 for a reset)."""
    tier = effective_tier(uid)
    budget, duration = tier_budget(uid, tier)
    keys = errors = 0
    for _ns, key_id in user_key_ids(uid).items():
        try:
            if apply_key_budget(c, key_id, budget, duration, _key_info(c, key_id), extra):
                keys += 1
            else:
                errors += 1
        except Exception as e:  # noqa: BLE001
            errors += 1
            print(f"[mint] reapply key error: {type(e).__name__}", flush=True)
    try:
        ensure_user_budget(c, _admin_headers(), uid, tier)
    except Exception as e:  # noqa: BLE001
        errors += 1
        print(f"[mint] reapply user error: {type(e).__name__}", flush=True)
    return {"keys": keys, "errors": errors}


def reapply_all(uids: list[str] | None = None) -> dict:
    uids = list(uids if uids is not None else rds.smembers(ALL_UIDS_SET))
    total = {"users": 0, "keys": 0, "errors": 0}
    rds.set(REAPPLY_STATUS_KEY, json.dumps({"state": "running", "total": len(uids), "done": 0}))
    with litellm_client(20) as c:
        for i, uid in enumerate(uids, 1):
            res = reapply_user(c, uid)
            total["users"] += 1
            total["keys"] += res["keys"]
            total["errors"] += res["errors"]
            if i % 50 == 0:
                rds.set(REAPPLY_STATUS_KEY, json.dumps({"state": "running", "total": len(uids), "done": i}))
    rds.set(REAPPLY_STATUS_KEY, json.dumps({"state": "done", "total": len(uids), "done": len(uids),
                                            **total, "at": _now_iso()}))
    return total


def reapply_everyone() -> dict:
    """Re-apply to all users now (small) or in the background (large)."""
    uids = list(rds.smembers(ALL_UIDS_SET))
    if len(uids) <= REAPPLY_SYNC_MAX:
        return {"mode": "sync", **reapply_all(uids)}
    threading.Thread(target=reapply_all, args=(uids,), daemon=True).start()
    return {"mode": "background", "users": len(uids)}


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
            "rpm_limit": KEY_RPM,
            "tpm_limit": KEY_TPM,
            "max_parallel_requests": KEY_MAX_PARALLEL,
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
    tier: str  # free | 3x | 7x | 15x


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
    tier = body.tier if body.tier in TIER_MULT else "free"
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
        tier=tier,
        base_url=os.environ.get("PUBLIC_BASE_URL", "https://cloud.dhanuksoftwares.com/v1"),
    )



# ── usage: counts + per-model remaining (no prices shown to users) ──
AUTO_MODEL = os.environ.get("AUTO_MODEL_GROUP", "auto")
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


def model_catalog(c: httpx.Client) -> dict:
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
        if under and name != AUTO_MODEL:
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
    if group == AUTO_MODEL:
        return (_public_for(cat, under) or AUTO_MODEL), True
    if group in groups:
        return group, False
    pub = _public_for(cat, under)
    if pub:
        return pub, False
    if under in groups:
        return under, False
    return (group or under or "unknown"), False


def count_usage(rows: list[dict], cat: dict) -> tuple[dict, float, dict]:
    """(today counts, logged spend USD, measured avg image tokens per model)."""
    today = {"requests": 0, "input_tokens": 0, "output_tokens": 0, "images": 0,
             "auto_requests": 0, "by_model": {}}
    spend = 0.0
    img_tokens: dict = {}
    for row in rows:
        if str(row.get("status") or "success").lower() == "failure":
            continue
        mid, via_auto = attribute_row(row, cat)
        is_image = (str(row.get("call_type") or "") in IMAGE_CALL_TYPES
                    or _group_kind(cat["groups"].get(mid)) == "image")
        pin = _int_or(row.get("prompt_tokens"), 0)
        pout = _int_or(row.get("completion_tokens"), 0)
        spend += _float_or(row.get("spend"), 0.0)
        bm = today["by_model"].setdefault(mid, {"requests": 0, "input_tokens": 0, "output_tokens": 0,
                                                "images": 0, "via_auto": 0})
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
    return today, spend, measured


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


def model_estimates(cat: dict, remaining_usd: float, remaining_fraction: float,
                    settings: dict, measured_img: dict | None = None) -> list[dict]:
    measured_img = measured_img or {}
    groups = cat["groups"]
    out = []
    for gid, g in groups.items():
        is_auto = gid == AUTO_MODEL
        kind = "chat" if is_auto else _group_kind(g)
        entry = {"id": gid, "name": g["name"], "kind": kind, "auto": is_auto,
                 "estimate": "typical"}
        if is_auto:
            members = sorted({p for u in g["underlying"] for p in [_public_for(cat, u)]
                              if p and p != AUTO_MODEL and p in groups})
            costs = [c for c in (_unit_cost(groups[m], settings, measured_img) for m in members) if c]
            own = _unit_cost(g, settings, measured_img)
            if own:
                costs.append(own)
            cost = max(costs) if costs else None
            entry["estimate"] = "conservative"  # priced at the most expensive member
            entry["members"] = members
        else:
            cost = _unit_cost(g, settings, measured_img)
        priced = cost is not None and cost > 0
        entry["priced"] = priced
        remaining = math.floor(max(0.0, remaining_usd) / cost + 1e-9) if priced else None
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


def _month_spent_c(c: httpx.Client, uid: str) -> float:
    try:
        r = c.get("/user/info", headers=_admin_headers(), params={"user_id": uid})
        if r.status_code == 200:
            return float((r.json().get("user_info") or {}).get("spend") or 0.0)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user/info error: {type(e).__name__}", flush=True)
    return 0.0


def compute_usage(uid: str) -> tuple[dict, dict]:
    """(public /usage body, admin-only detail). Spend comes from LiteLLM for
    ALL of the user's keys (android + web — fixes L5)."""
    tier = effective_tier(uid)
    settings = get_settings()
    budget, window = tier_budget(uid, tier)
    dur = datetime.timedelta(seconds=WINDOW_SECONDS[window])
    now = _now()
    keys = user_key_ids(uid)
    key_detail = []
    key_spend, key_spend_known, resets = 0.0, False, []
    rows: list[dict] = []
    with litellm_client(15) as c:
        for ns, kid in keys.items():
            info = _key_info(c, kid)
            d = {"platform": "web" if ns else "android", "present": True}
            if info is not None:
                key_spend_known = True
                key_spend += _float_or(info.get("spend"), 0.0)
                t = _parse_time(info.get("budget_reset_at"))
                if t is not None and t > now:
                    resets.append(t)
                d.update(spend_usd=_float_or(info.get("spend"), 0.0),
                         max_budget_usd=info.get("max_budget"),
                         budget_duration=info.get("budget_duration"),
                         budget_reset_at=info.get("budget_reset_at"),
                         blocked=bool(info.get("blocked")))
            key_detail.append(d)
        resets_at = min(resets + [now + dur])
        start = resets_at - dur
        for kid in keys.values():
            rows.extend(_spend_logs(c, _token_id(kid), start, now))
        cat = model_catalog(c)
        month_free_spent = _month_spent_c(c, uid) if keys else 0.0
    today, log_spend, measured = count_usage(rows, cat)
    spent = key_spend if key_spend_known else log_spend
    month_cap = free_cap_usd(uid)
    remaining = max(0.0, budget - spent)
    if tier == "free":
        # The monthly backstop can bind before the daily allowance does.
        remaining = min(remaining, max(0.0, month_cap - month_free_spent))
    fraction = min(1.0, remaining / budget) if budget > 0 else 0.0
    body = {
        "tier": tier,
        "is_paid": tier != "free",
        # Back-compat / internal USD (never rendered by the app).
        "daily_spent_usd": round(spent, 6),
        "daily_budget_usd": round(budget, 6),
        "daily_remaining_usd": round(remaining, 6),
        "month_free_spent_usd": round(month_free_spent, 6),
        "month_free_cap_usd": round(month_cap, 6),
        "requests_today": today["requests"],
        "budget_window": window,
        "remaining_pct": round(fraction, 4),
        # Display-safe fields (no money).
        "window": window,
        "resets_at": _iso(resets_at),
        "today": today,
        "remaining_fraction": round(fraction, 4),
        "models": model_estimates(cat, remaining, fraction, settings, measured),
    }
    detail = {"keys": key_detail, "spend_usd": round(spent, 6), "logged_spend_usd": round(log_spend, 6),
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
    window: str
    resets_at: str
    today: dict
    remaining_fraction: float
    models: list[dict]


@app.post("/usage", response_model=UsageResp)
def usage(
    authorization: str = Header(...),
    x_firebase_appcheck: str = Header(default=""),
):
    """Server-authoritative usage for the signed-in user.

    Spend and counts are read from LiteLLM (the source of truth), NOT computed
    on the device. Users never see prices: per-model availability is expressed
    as remaining messages / images.
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
    return {"tier": effective_tier(uid),
            "daily_usd_override": rds.get(f"user:{uid}:dailyUsd"),
            "monthly_cap_override": rds.get(f"user:{uid}:monthlyCapUsd"),
            "banned": rds.get(f"user:{uid}:banned")}


class AdminAction(BaseModel):
    uid: str | None = None
    ip: str | None = None
    tier: str | None = None
    daily_usd: float | None = None          # user's FREE allowance per 24h
    monthly_cap_usd: float | None = None    # user's free monthly backstop
    clear_daily_usd: bool = False
    clear_monthly_cap_usd: bool = False


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


@app.post("/admin/set-tier")
def admin_set_tier(body: AdminAction, request: Request, authorization: str = Header(default="")):
    """Change one user's plan and/or per-user overrides, then re-apply the
    user's budgets to all of their keys (android + web)."""
    _require_admin(authorization)
    if not body.uid:
        raise HTTPException(400, "uid required")
    uid = body.uid.strip()
    if body.tier and body.tier not in TIERS:
        raise HTTPException(400, "unknown tier")
    for name, v in (("daily_usd", body.daily_usd), ("monthly_cap_usd", body.monthly_cap_usd)):
        if v is not None and (v < 0 or math.isnan(v)):
            raise HTTPException(400, f"{name} must be >= 0")
    before = _user_state(uid)
    if body.tier:
        rds.set(f"user:{uid}:tier", body.tier)
    if body.clear_daily_usd:
        rds.delete(f"user:{uid}:dailyUsd")
    elif body.daily_usd is not None:
        rds.set(f"user:{uid}:dailyUsd", str(body.daily_usd))
    if body.clear_monthly_cap_usd:
        rds.delete(f"user:{uid}:monthlyCapUsd")
    elif body.monthly_cap_usd is not None:
        rds.set(f"user:{uid}:monthlyCapUsd", str(body.monthly_cap_usd))
    with litellm_client(15) as c:
        res = reapply_user(c, uid)
    _drop_usage_cache([uid])
    after = _user_state(uid)
    audit(request, "set-user", uid, before, after, res)
    return {"ok": True, "user": after, "reapplied": res}


class SettingsUpdate(BaseModel):
    free_daily_usd: float | None = None
    tier_mult: dict[str, float] | None = None
    paid_window: str | None = None
    free_monthly_cap_usd: float | None = None
    est_input_tokens: int | None = None
    est_output_tokens: int | None = None
    est_image_tokens: int | None = None
    reapply: bool = True


def _apply_settings(request: Request | None, changes: dict, reapply: bool, action: str) -> dict:
    before = get_settings()
    merged = dict(before)
    for k, v in changes.items():
        if v is None:
            continue
        if k == "tier_mult":
            unknown = set(v) - set(PAID_TIERS) - {"free"}
            if unknown:
                raise HTTPException(400, f"unknown tier(s): {sorted(unknown)}")
            merged["tier_mult"] = {**before["tier_mult"], **v}
        else:
            merged[k] = v
    after = _validate_settings(merged)
    _store_settings(after)
    result = reapply_everyone() if reapply else {"mode": "skipped"}
    audit(request, action, "global", before, after, result)
    return {"ok": True, "settings": get_settings(), "reapplied": result}


@app.get("/admin/settings")
def admin_get_settings(authorization: str = Header(default="")):
    _require_admin(authorization)
    status = rds.get(REAPPLY_STATUS_KEY)
    return {"settings": get_settings(), "tiers": list(TIER_MULT),
            "paid_windows": list(PAID_WINDOWS), "users": rds.scard(ALL_UIDS_SET),
            "reapply_status": json.loads(status) if status else None}


@app.post("/admin/settings")
def admin_set_settings(body: SettingsUpdate, request: Request, authorization: str = Header(default="")):
    """Owner settings: global free allowance, plan multipliers, paid window,
    free monthly backstop and the message/image estimate. Re-applied to every
    key (android + web) and every LiteLLM user budget."""
    _require_admin(authorization)
    changes = body.model_dump(exclude={"reapply"})
    return _apply_settings(request, changes, body.reapply, "settings")


class BaseBudgetAction(BaseModel):
    daily_usd: float
    reapply: bool = True


@app.post("/admin/set-base-budget")
def admin_set_base_budget(body: BaseBudgetAction, request: Request,
                          authorization: str = Header(default="")):
    """Legacy: set the global FREE allowance per user per 24h. Paid plans are
    free allowance × multiplier. Re-applies to all keys (android + web)."""
    _require_admin(authorization)
    if body.daily_usd < 0:
        raise HTTPException(400, "daily_usd must be >= 0")
    res = _apply_settings(request, {"free_daily_usd": body.daily_usd}, body.reapply, "set-base-budget")
    r = res["reapplied"]
    return {"ok": True, "base_daily_usd": body.daily_usd,
            "reapplied": r.get("keys", r.get("users", 0)) if isinstance(r, dict) else 0,
            "detail": r}


class ResetAction(BaseModel):
    uid: str | None = None  # omit → reset ALL users
    reset_month_free: bool = True


def _reset_users(uids: list[str], reset_month_free: bool) -> dict:
    out = {"users": 0, "keys": 0, "errors": 0}
    with litellm_client(20) as c:
        for uid in uids:
            if not uid:
                continue
            # spend=0 on every key restarts the window's usage.
            res = reapply_user(c, uid, extra={"spend": 0})
            out["users"] += 1
            out["keys"] += res["keys"]
            out["errors"] += res["errors"]
            if reset_month_free:
                # L4: the monthly backstop is LiteLLM's USER spend; zero it.
                try:
                    r = c.post("/user/update", headers=_admin_headers(),
                               json={"user_id": uid, "spend": 0})
                    if r.status_code >= 300:
                        out["errors"] += 1
                except Exception:  # noqa: BLE001
                    out["errors"] += 1
                rds.delete(month_key(uid))  # legacy key, harmless
            rds.delete(f"usagecache:{uid}")
    return out


@app.post("/admin/reset-usage")
def admin_reset_usage(body: ResetAction, request: Request, authorization: str = Header(default="")):
    """Reset usage for one user (uid) or ALL users (uid omitted): zero the
    spend on every key (android + web) and, with reset_month_free, the LiteLLM
    user spend that carries the monthly backstop."""
    _require_admin(authorization)
    targets = [body.uid.strip()] if body.uid else list(rds.smembers(ALL_UIDS_SET))
    if len(targets) > REAPPLY_SYNC_MAX:
        threading.Thread(target=_reset_users, args=(targets, body.reset_month_free), daemon=True).start()
        res = {"mode": "background", "users": len(targets)}
    else:
        res = _reset_users(targets, body.reset_month_free)
    audit(request, "reset-usage", body.uid or "ALL", None,
          {"reset_month_free": body.reset_month_free}, res)
    return {"ok": True, "reset": res.get("keys", 0), "detail": res}


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


@app.get("/admin/user")
def admin_user(q: str, authorization: str = Header(default="")):
    """Look a user up by uid or email: plan, overrides, window usage (requests,
    tokens, images, spend) and the per-model table exactly as the app sees it."""
    _require_admin(authorization)
    uid = _resolve_uid(q)
    if not uid:
        raise HTTPException(404, "user not found")
    body, detail = compute_usage(uid)
    tier = body["tier"]
    s = get_settings()
    return {
        "uid": uid,
        "email": rds.get(f"user:{uid}:email"),
        "tier": tier,
        "banned": rds.get(f"user:{uid}:banned"),
        "override_daily_usd": rds.get(f"user:{uid}:dailyUsd"),
        "override_monthly_cap_usd": rds.get(f"user:{uid}:monthlyCapUsd"),
        "free_daily_usd": user_free_daily(uid),
        "multiplier": s["tier_mult"].get(tier, 1),
        "allowance_usd": body["daily_budget_usd"],
        "window": body["window"],
        "resets_at": body["resets_at"],
        "today": {**body["today"], "spend_usd": detail["spend_usd"]},
        "month_spent_usd": body["month_free_spent_usd"],
        "month_cap_usd": body["month_free_cap_usd"],
        "remaining_usd": detail["remaining_usd"],
        "remaining_fraction": body["remaining_fraction"],
        "keys": detail["keys"],
        "window_start": detail["window_start"],
        "app_view": body,
    }


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
# This page is served by the mint service on port 8090. Caddy's public vhost
# only exposes /v1, /mint, /usage, /healthz — NOT /admin — so this console is
# reachable ONLY through an SSH tunnel to 127.0.0.1:8090. It calls the admin
# endpoints with the master key you paste in (kept in the tab's memory only).
_ADMIN_HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=referrer content=no-referrer>
<title>Ovid Admin</title>
<style>
 body{font:15px/1.5 system-ui,sans-serif;max-width:980px;margin:0 auto;padding:24px;background:#0d1117;color:#e6edf3}
 h1{font-size:20px}h2{font-size:15px;margin:26px 0 8px;color:#8b949e;text-transform:uppercase;letter-spacing:.08em}
 .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:16px;margin:10px 0}
 label{display:block;font-size:12px;color:#8b949e;margin:8px 0 4px}
 input,select{width:100%;box-sizing:border-box;padding:9px;border-radius:8px;border:1px solid #30363d;background:#0d1117;color:#e6edf3;font-size:14px}
 button{margin:12px 8px 0 0;padding:9px 14px;border:0;border-radius:8px;background:#2f81f7;color:#fff;font-size:14px;font-weight:600;cursor:pointer}
 button.danger{background:#da3633}button.ghost{background:#30363d}
 .row{display:flex;gap:10px;flex-wrap:wrap}.row>div{flex:1;min-width:120px}
 .out{margin-top:10px;font-size:12px;color:#7ee787;white-space:pre-wrap;font-family:ui-monospace,monospace}
 .err{color:#ff7b72}.muted{color:#8b949e;font-size:12px}.warn{color:#d29922;font-size:13px}
 table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px}
 th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #30363d;vertical-align:top}
 th{color:#8b949e;font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums}
 .kv{display:grid;grid-template-columns:200px 1fr;gap:4px 12px;font-size:13px}.kv div:nth-child(odd){color:#8b949e}
</style></head><body>
<h1>Ovid Cloud — Admin</h1>
<div class=card>
 <label>Master key (stays in this tab only)</label>
 <input id=mk type=password placeholder="sk-..." autocomplete=off>
 <button onclick=loadAll()>Load</button>
 <div class=muted>Every change below is re-applied to all affected keys (android + web) and written to the audit log.</div>
</div>

<h2>Usage limits (all users)</h2>
<div class=card>
 <div class=row>
  <div><label>Free allowance per user per 24h (USD)</label><input id=s_free type=number step=0.01 min=0 oninput=preview()></div>
  <div><label>Free monthly backstop per user (USD / 30 days)</label><input id=s_cap type=number step=0.01 min=0 oninput=preview()></div>
 </div>
 <div class=row>
  <div><label>3x plan multiplier</label><input id=s_m3 type=number step=0.1 min=1 oninput=preview()></div>
  <div><label>7x plan multiplier</label><input id=s_m7 type=number step=0.1 min=1 oninput=preview()></div>
  <div><label>15x plan multiplier</label><input id=s_m15 type=number step=0.1 min=1 oninput=preview()></div>
  <div><label>Paid window</label><select id=s_win onchange=preview()><option value=30d>30d — monthly pool</option><option value=24h>24h — daily allowance</option></select></div>
 </div>
 <div class=row>
  <div><label>Typical message: input tokens</label><input id=s_ein type=number min=1></div>
  <div><label>Typical message: output tokens</label><input id=s_eout type=number min=1></div>
  <div><label>Typical image: output tokens (no per-image price)</label><input id=s_eimg type=number min=1></div>
 </div>
 <div class=out id=preview style="color:#e6edf3"></div>
 <div class=muted>Paid allowance = the user's free allowance × plan multiplier. With the <b>30d</b> window a paid user gets a monthly pool of 30 × that amount; with <b>24h</b> it resets every 24 hours.
 The <b>monthly backstop</b> is a second, 30-day cap on free users (LiteLLM user budget across all their keys): with a high daily free amount it cuts users off after a few days — e.g. $3/day with a $10 backstop stops a heavy user on day 4. Raise it together with the daily amount if that is not intended.</div>
 <button onclick=saveSettings()>Save and re-apply to all users</button>
 <div class=out id=settingsOut></div>
</div>

<h2>User</h2>
<div class=card>
 <div class=row><div><label>uid or email</label><input id=q placeholder="firebase uid or user@gmail.com" onkeydown="if(event.key==='Enter')lookup()"></div></div>
 <button onclick=lookup()>Look up</button>
 <div class=out id=userOut></div>
 <div id=userBox style="display:none">
  <div class=kv id=userKv style="margin-top:12px"></div>
  <h2>Models as the app sees them</h2>
  <table><thead><tr><th>Model</th><th>Kind</th><th class=num>Remaining</th><th>Estimate</th><th class=num>Requests (window)</th><th class=num>Tokens in / out</th><th class=num>Images</th></tr></thead><tbody id=modelRows></tbody></table>
  <h2>Change this user</h2>
  <div class=row>
   <div><label>Plan</label><select id=u_tier><option>free</option><option>3x</option><option>7x</option><option>15x</option></select></div>
   <div><label>Free allowance override (USD / 24h, empty = global)</label><input id=u_daily type=number step=0.01 min=0></div>
   <div><label>Monthly backstop override (USD, empty = global)</label><input id=u_cap type=number step=0.01 min=0></div>
  </div>
  <button onclick=saveUser()>Save user</button>
  <button class=ghost onclick=resetUser()>Reset this user's usage</button>
  <button class=danger onclick=banUser(true)>Ban</button>
  <button class=ghost onclick=banUser(false)>Unban</button>
  <div class=out id=userActOut></div>
 </div>
</div>

<h2>Reset / IP ban</h2>
<div class=card>
 <button class=danger onclick=resetAll()>Reset usage for ALL users</button>
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
let current=null, settings=null;
function mk(){return $('mk').value.trim()}
async function api(method,path,body){
 const r=await fetch(path,{method,headers:{'Authorization':'Bearer '+mk(),'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const t=await r.text(); let j=null; try{j=JSON.parse(t)}catch(e){}
 if(!r.ok) throw new Error(r.status+' '+(j&&j.detail?JSON.stringify(j.detail):t));
 return j;
}
function show(id,v,err){const o=$(id);o.className='out'+(err?' err':'');o.textContent=typeof v==='string'?v:JSON.stringify(v,null,1)}
function cell(tr,v,cls){const td=document.createElement('td');td.textContent=(v===null||v===undefined)?'—':String(v);if(cls)td.className=cls;tr.appendChild(td)}
function num(id){const v=$(id).value.trim();return v===''?null:parseFloat(v)}
function money(v){return '$'+Number(v||0).toFixed(2)}
async function loadAll(){await loadSettings();await loadAudit()}
async function loadSettings(){
 try{const j=await api('GET','/admin/settings');settings=j.settings;
  $('s_free').value=settings.free_daily_usd;$('s_cap').value=settings.free_monthly_cap_usd;
  $('s_m3').value=settings.tier_mult['3x'];$('s_m7').value=settings.tier_mult['7x'];$('s_m15').value=settings.tier_mult['15x'];
  $('s_win').value=settings.paid_window;$('s_ein').value=settings.est_input_tokens;$('s_eout').value=settings.est_output_tokens;$('s_eimg').value=settings.est_image_tokens;
  preview();show('settingsOut',j.users+' known users'+(j.reapply_status?' · last re-apply: '+JSON.stringify(j.reapply_status):''));
 }catch(e){show('settingsOut',String(e),true)}
}
function preview(){
 const f=num('s_free')||0,cap=num('s_cap')||0,w=$('s_win').value;
 const lines=['Free: '+money(f)+' per 24h'+(f>0&&cap>0?' · monthly backstop '+money(cap)+' (a user spending the full daily amount is stopped after ~'+Math.ceil(cap/f)+' day(s))':'')];
 for(const [t,id] of [['3x','s_m3'],['7x','s_m7'],['15x','s_m15']]){const m=num(id)||1;lines.push(t+': ×'+m+' = '+money(f*m)+' per 24h'+(w==='30d'?' → pool '+money(f*m*30)+' per 30 days':''))}
 $('preview').textContent=lines.join('\\n');
}
async function saveSettings(){
 if(!confirm('Apply these limits to ALL users now?'))return;
 const b={free_daily_usd:num('s_free'),free_monthly_cap_usd:num('s_cap'),paid_window:$('s_win').value,
  tier_mult:{'3x':num('s_m3'),'7x':num('s_m7'),'15x':num('s_m15')},
  est_input_tokens:num('s_ein'),est_output_tokens:num('s_eout'),est_image_tokens:num('s_eimg'),reapply:true};
 try{const j=await api('POST','/admin/settings',b);show('settingsOut',{saved:j.settings,reapplied:j.reapplied});loadAudit()}catch(e){show('settingsOut',String(e),true)}
}
async function lookup(){
 const q=$('q').value.trim();if(!q)return;
 try{current=await api('GET','/admin/user?q='+encodeURIComponent(q));renderUser();show('userOut','')}
 catch(e){$('userBox').style.display='none';show('userOut',String(e),true)}
}
function renderUser(){
 const u=current,t=u.today,kv=$('userKv');kv.textContent='';
 const rows=[['uid',u.uid],['email',u.email],['plan',u.tier+' (×'+u.multiplier+')'],['banned',u.banned||'no'],
  ['free allowance / 24h',money(u.free_daily_usd)+(u.override_daily_usd!==null?' (override)':' (global)')],
  ['allowance this window',money(u.allowance_usd)+' per '+u.window],['window',u.window_start+' → '+u.resets_at],
  ['window usage',t.requests+' requests · '+t.input_tokens+' in / '+t.output_tokens+' out tokens · '+t.images+' images · '+t.auto_requests+' via auto'],
  ['window spend',money(t.spend_usd)+' · remaining '+money(u.remaining_usd)+' ('+Math.round(u.remaining_fraction*100)+'%)'],
  ['monthly backstop',money(u.month_spent_usd)+' of '+money(u.month_cap_usd)+(u.override_monthly_cap_usd!==null?' (override)':'')+(u.tier==='free'?'':' (paid: user budget = plan pool)')],
  ['keys',u.keys.map(k=>k.platform+': spend '+money(k.spend_usd)+' / '+(k.max_budget_usd??'?')+' per '+(k.budget_duration||'?')+(k.blocked?' BLOCKED':'')).join(' · ')||'none']];
 for(const [k,v] of rows){const a=document.createElement('div');a.textContent=k;const b=document.createElement('div');b.textContent=v==null?'—':String(v);kv.appendChild(a);kv.appendChild(b)}
 const tb=$('modelRows');tb.textContent='';
 for(const m of u.app_view.models){const tr=document.createElement('tr');const bm=t.by_model[m.id]||{};
  cell(tr,m.name+(m.auto?' (auto: '+(m.members||[]).join(', ')+')':''));cell(tr,m.kind);
  cell(tr,!m.priced?'unpriced':(m.kind==='image'?m.remaining_images+' images':m.remaining_messages+' messages'),'num');
  cell(tr,m.estimate);cell(tr,bm.requests||0,'num');cell(tr,(bm.input_tokens||0)+' / '+(bm.output_tokens||0),'num');cell(tr,bm.images||0,'num');tb.appendChild(tr)}
 $('u_tier').value=u.tier;$('u_daily').value=u.override_daily_usd??'';$('u_cap').value=u.override_monthly_cap_usd??'';
 $('userBox').style.display='block';
}
async function saveUser(){
 if(!current)return;const b={uid:current.uid,tier:$('u_tier').value};
 const d=num('u_daily'),c=num('u_cap');if(d===null)b.clear_daily_usd=true;else b.daily_usd=d;if(c===null)b.clear_monthly_cap_usd=true;else b.monthly_cap_usd=c;
 try{const j=await api('POST','/admin/set-tier',b);show('userActOut',j);await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}
}
async function resetUser(){if(!current||!confirm('Reset usage for '+current.uid+'?'))return;
 try{show('userActOut',await api('POST','/admin/reset-usage',{uid:current.uid}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function banUser(on){if(!current)return;
 try{show('userActOut',await api('POST',on?'/admin/ban':'/admin/unban',{uid:current.uid}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function resetAll(){if(!confirm('Reset usage for ALL users?'))return;
 try{show('miscOut',await api('POST','/admin/reset-usage',{}));loadAudit()}catch(e){show('miscOut',String(e),true)}}
async function ipBan(on){const ip=$('banIp').value.trim();if(!ip)return;
 try{show('miscOut',await api('POST',on?'/admin/ban':'/admin/unban',{ip}));loadAudit()}catch(e){show('miscOut',String(e),true)}}
async function loadAudit(){
 try{const j=await api('GET','/admin/audit?limit=200');const tb=$('auditRows');tb.textContent='';
  for(const e of j.entries){const tr=document.createElement('tr');cell(tr,e.ts);cell(tr,e.action);cell(tr,typeof e.target==='string'?e.target:JSON.stringify(e.target));
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
    except Exception as e:  # noqa: BLE001
        print(f"[mint] settings restore error: {type(e).__name__}", flush=True)
    if os.environ.get("MINT_SPEND_MONITOR", "true").lower() == "true":
        threading.Thread(target=_spend_monitor, daemon=True).start()
