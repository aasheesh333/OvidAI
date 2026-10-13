# Ovid Cloud — mint verifier service
#
# Runs on the VPS next to LiteLLM (NO Firebase Blaze). It:
#   1. verifies the Google ID token (Firebase Auth) against Google's public JWKS
#   2. verifies the Firebase App Check token against Firebase's public JWKS
#   3. mints/returns the caller's per-user LiteLLM virtual key (tier budget)
#   4. enforces the $10/calendar-month free-tier cap via Redis
#
# Everything stays on the box. The APK only ever receives its own virtual key.

import os
import time
import threading
import json
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

# Tier MULTIPLIERS. The BASE daily budget is admin-editable at runtime (stored
# in Redis under config:base_daily_usd); each tier's effective daily budget is
# base × multiplier, applied PER USER (every user gets their own independent
# budget — never a shared pool). Set the base once → all users scale by tier.
BASE_DAILY_USD = float(os.environ.get("BASE_DAILY_USD", "0.50"))
TIER_MULT = {"free": 1, "3x": 3, "7x": 7, "15x": 15}
TIERS = {t: {"mult": m} for t, m in TIER_MULT.items()}
# All known user ids (so an admin base-budget change can be re-applied to every
# existing user at once).
ALL_UIDS_SET = "ovid:uids"
BASE_BUDGET_KEY = "config:base_daily_usd"


def get_base_daily() -> float:
    """Admin-editable base daily budget (Redis), falling back to the env seed."""
    v = rds.get(BASE_BUDGET_KEY)
    try:
        return float(v) if v is not None else BASE_DAILY_USD
    except (TypeError, ValueError):
        return BASE_DAILY_USD


def tier_daily(uid: str, tier: str) -> float:
    """Per-user base amount = base × tier multiplier, unless a per-user override
    is set by the admin. Independent per user (not a shared pool)."""
    override = rds.get(f"user:{uid}:dailyUsd")
    if override:
        try:
            return float(override)
        except (TypeError, ValueError):
            pass
    return get_base_daily() * TIER_MULT.get(tier, 1)


def tier_budget(uid: str, tier: str) -> tuple[float, str]:
    """Return (max_budget, budget_duration) for a user.

    FREE tier has a 24h cap (resets daily). PAID tiers (3x/7x/15x) have NO
    daily wall — they draw a MONTHLY pool (base × multiplier), resetting every
    30 days. So a paid user is never cut off at a daily limit; only free users
    reset every 24h.
    """
    amount = tier_daily(uid, tier)
    if tier == "free":
        return amount, "24h"
    # Monthly pool sized as 30 days of the tier's daily amount, so every paid
    # tier gets more than free (free: base/day; 15x: 15 x base/day).
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
            with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
                r = c.get("/global/spend", headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}"})
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
    ym = datetime.datetime.utcnow().strftime("%Y-%m")
    return f"freecap:{uid}:{ym}"


def free_cap_usd(uid: str) -> float:
    override = rds.get(f"user:{uid}:monthlyCapUsd")
    return float(override) if override else FREE_MONTHLY_CAP_USD


def month_spent(uid: str) -> float:
    """User-level spend over the current 30d window, from LiteLLM."""
    try:
        with httpx.Client(base_url=LITELLM_BASE, timeout=10) as c:
            r = c.get("/user/info", headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}"},
                      params={"user_id": uid})
        if r.status_code == 200:
            return float((r.json().get("user_info") or {}).get("spend") or 0.0)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] user/info error: {type(e).__name__}", flush=True)
    return 0.0


def ensure_user_budget(c: httpx.Client, headers: dict, uid: str, tier: str) -> None:
    """LiteLLM enforces the monthly cap across all of the user's keys.
    Free: FREE_MONTHLY_CAP_USD per 30d. Paid: same as the key's 30d pool."""
    if tier == "free":
        budget, duration = free_cap_usd(uid), "30d"
    else:
        budget, duration = tier_budget(uid, tier)
    r = c.post("/user/update", headers=headers,
               json={"user_id": uid, "max_budget": budget, "budget_duration": duration})
    if r.status_code >= 300:
        print(f"[mint] user/update {r.status_code} for {uid[:6]}", flush=True)


def free_cap_remaining(uid: str) -> float:
    spent = month_spent(uid)
    override = rds.get(f"user:{uid}:monthlyCapUsd")
    cap = float(override) if override else FREE_MONTHLY_CAP_USD
    return max(0.0, cap - spent)


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
def _key_usable(c: httpx.Client, headers: dict, key_id: str) -> bool:
    """False only when LiteLLM says the key is gone, rejected or expired.
    Upstream errors/timeouts count as usable (never churn keys on outages).
    Admin-blocked keys stay as they are (ban/unban manages them)."""
    try:
        r = c.get("/key/info", headers=headers, params={"key": key_id})
    except Exception:  # noqa: BLE001
        return True
    if r.status_code in (401, 403, 404):
        return False
    if r.status_code != 200:
        return True
    info = r.json().get("info") or {}
    exp = info.get("expires")
    if exp:
        try:
            when = datetime.datetime.fromisoformat(str(exp).replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=datetime.timezone.utc)
            if when <= datetime.datetime.now(datetime.timezone.utc):
                return False
        except ValueError:
            pass
    return True


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
    headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
    with httpx.Client(base_url=LITELLM_BASE, timeout=20) as c:
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
        if existing and _key_usable(c, headers, existing):
            r = c.post("/key/update", headers=headers, json={"key": existing, **body})
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
    # Re-apply the new tier's budget to the live key immediately.
    key = rds.get(f"user:{uid}:keyid")
    if key:
        try:
            budget, duration = tier_budget(uid, tier)
            with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
                h = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
                c.post(
                    "/key/update",
                    headers=h,
                    json={"key": key, "max_budget": budget, "budget_duration": duration},
                )
                _safe_user_budget(c, h, uid, tier)
        except Exception as e:  # noqa: BLE001
            print(f"upgrade reapply error: {e}")
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


class UsageResp(BaseModel):
    tier: str
    is_paid: bool
    # Server-authoritative spend numbers (USD). Free tier hides these in the app.
    daily_spent_usd: float
    daily_budget_usd: float
    daily_remaining_usd: float
    month_free_spent_usd: float
    month_free_cap_usd: float
    requests_today: int
    # The budget window ('24h' free, '30d' paid) and the shared remaining-% of
    # the pool, plus every available model with its price. Using a costly model
    # drains the shared pool faster → every model's remaining-% drops together.
    budget_window: str
    remaining_pct: float
    models: list[dict]


def _available_models() -> list[dict]:
    """Owner-published models + their per-token pricing (from LiteLLM)."""
    out: list[dict] = []
    try:
        headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
        with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
            r = c.get("/model/info", headers=headers)
            if r.status_code == 200:
                for m in r.json().get("data", []):
                    name = m.get("model_name") or ""
                    info = m.get("model_info", {}) or {}
                    if not name:
                        continue
                    out.append({
                        "model": name,
                        "input_cost_per_token": info.get("input_cost_per_token"),
                        "output_cost_per_token": info.get("output_cost_per_token"),
                    })
    except Exception as e:  # noqa: BLE001
        print(f"model/info error: {e}")
    # De-dupe by public name (auto pool shares one name).
    seen = {}
    for m in out:
        seen[m["model"]] = m
    return list(seen.values())


@app.post("/usage", response_model=UsageResp)
def usage(
    authorization: str = Header(...),
    x_firebase_appcheck: str = Header(default=""),
):
    """Server-authoritative usage for the signed-in user.

    Spend is read from LiteLLM (the source of truth), NOT computed on the
    device. The app renders this directly; the free tier hides the numbers.
    """
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer id token")
    id_token = authorization.split(" ", 1)[1]
    if APPCHECK_ENABLED and not x_firebase_appcheck:
        raise HTTPException(401, "missing app check token")
    platform = verify_app_check(x_firebase_appcheck)
    claims = verify_google_id_token(id_token)
    uid = claims["sub"]

    tier = effective_tier(uid)
    budget, window = tier_budget(uid, tier)

    # Pull live spend for this user's key from LiteLLM (authoritative).
    spent = 0.0
    requests_today = 0
    key_token = rds.get(f"user:{uid}:keyid")
    if key_token:
        try:
            headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
            with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
                r = c.get("/key/info", headers=headers, params={"key": key_token})
                if r.status_code == 200:
                    info = r.json().get("info", r.json())
                    spent = float(info.get("spend", 0.0) or 0.0)
        except Exception as e:  # noqa: BLE001 — usage must never hard-fail
            print(f"usage key/info error: {e}")

    month_cap = FREE_MONTHLY_CAP_USD
    cap_override = rds.get(f"user:{uid}:monthlyCapUsd")
    if cap_override:
        month_cap = float(cap_override)
    month_free_spent = month_spent(uid)

    remaining = max(0.0, budget - spent)
    remaining_pct = (remaining / budget) if budget > 0 else 0.0

    # Each available model carries the SHARED remaining-% of the dollar pool,
    # plus its price so the app can show "costly model drains faster".
    models = _available_models()
    for m in models:
        m["remaining_pct"] = round(remaining_pct, 4)

    return UsageResp(
        tier=tier,
        is_paid=(tier != "free"),
        daily_spent_usd=round(spent, 6),
        daily_budget_usd=round(budget, 6),
        daily_remaining_usd=round(remaining, 6),
        month_free_spent_usd=round(month_free_spent, 6),
        month_free_cap_usd=round(month_cap, 6),
        requests_today=requests_today,
        budget_window=window,
        remaining_pct=round(remaining_pct, 4),
        models=models,
    )


# ── admin: ban / unban / set-tier (master-key protected) ──
def _require_admin(authorization: str) -> None:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing admin key")
    token = authorization.split(" ", 1)[1]
    if token != LITELLM_MASTER_KEY:
        raise HTTPException(403, "not admin")


class AdminAction(BaseModel):
    uid: str | None = None
    ip: str | None = None
    tier: str | None = None
    daily_usd: float | None = None
    monthly_cap_usd: float | None = None


def _set_key_blocked(uid: str, blocked: bool) -> None:
    for ns in ("", "web:"):
        _set_one_key_blocked(uid, ns, blocked)


def _set_one_key_blocked(uid: str, ns: str, blocked: bool) -> None:
    key = rds.get(f"user:{uid}:{ns}keyid")
    if not key:
        return
    try:
        with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
            r = c.post("/key/block" if blocked else "/key/unblock",
                       headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}, json={"key": key})
        print(f"[mint] key {'block' if blocked else 'unblock'} {r.status_code} for {uid[:6]}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[mint] key block error: {type(e).__name__}", flush=True)


@app.post("/admin/ban")
def admin_ban(body: AdminAction, authorization: str = Header(...)):
    _require_admin(authorization)
    if body.uid:
        rds.set(f"user:{body.uid}:banned", "admin")
        _set_key_blocked(body.uid, True)
    if body.ip:
        rds.setex(f"ban:ip:{body.ip}", 30 * 24 * 3600, "admin")
    return {"ok": True}


@app.post("/admin/unban")
def admin_unban(body: AdminAction, authorization: str = Header(...)):
    _require_admin(authorization)
    if body.uid:
        rds.delete(f"user:{body.uid}:banned")
        _set_key_blocked(body.uid, False)
    if body.ip:
        rds.delete(f"ban:ip:{body.ip}")
    return {"ok": True}


@app.post("/admin/set-tier")
def admin_set_tier(body: AdminAction, authorization: str = Header(...)):
    """Admin changes a single user's tier and/or per-user limit overrides."""
    _require_admin(authorization)
    if not body.uid:
        raise HTTPException(400, "uid required")
    if body.tier and body.tier in TIERS:
        rds.set(f"user:{body.uid}:tier", body.tier)
    if body.daily_usd is not None:
        rds.set(f"user:{body.uid}:dailyUsd", str(body.daily_usd))
    if body.monthly_cap_usd is not None:
        rds.set(f"user:{body.uid}:monthlyCapUsd", str(body.monthly_cap_usd))
    # Re-apply this user's budget to their live key immediately.
    tier = effective_tier(body.uid)
    key = rds.get(f"user:{body.uid}:keyid")
    if key:
        try:
            headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
            with httpx.Client(base_url=LITELLM_BASE, timeout=15) as c:
                c.post(
                    "/key/update",
                    headers=headers,
                    json={
                        "key": key,
                        "max_budget": tier_budget(body.uid, tier)[0],
                        "budget_duration": tier_budget(body.uid, tier)[1],
                    },
                )
                _safe_user_budget(c, headers, body.uid, tier)
        except Exception as e:  # noqa: BLE001
            print(f"set-tier reapply error: {e}")
    return {"ok": True}


class BaseBudgetAction(BaseModel):
    daily_usd: float
    reapply: bool = True


@app.post("/admin/set-base-budget")
def admin_set_base_budget(
    body: BaseBudgetAction, authorization: str = Header(...)
):
    """Set the BASE daily budget for ALL users at once (new, old, current).

    Every tier is base × its multiplier, applied PER USER (independent budgets,
    not a shared pool). E.g. base $5 → free users $5/day, 3x plan users $15/day.
    With reapply=true (default) every existing user's live key is updated now;
    new users pick it up automatically at mint.
    """
    _require_admin(authorization)
    if body.daily_usd < 0:
        raise HTTPException(400, "daily_usd must be >= 0")
    rds.set(BASE_BUDGET_KEY, str(body.daily_usd))
    updated = 0
    if body.reapply:
        headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
        uids = rds.smembers(ALL_UIDS_SET)
        with httpx.Client(base_url=LITELLM_BASE, timeout=20) as c:
            for uid in uids:
                key = rds.get(f"user:{uid}:keyid")
                if not key:
                    continue
                tier = effective_tier(uid)
                try:
                    c.post(
                        "/key/update",
                        headers=headers,
                        json={
                            "key": key,
                            "max_budget": tier_budget(uid, tier)[0],
                            "budget_duration": tier_budget(uid, tier)[1],
                        },
                    )
                    updated += 1
                except Exception as e:  # noqa: BLE001
                    print(f"base-budget reapply error for {uid}: {e}")
    return {"ok": True, "base_daily_usd": body.daily_usd, "reapplied": updated}


class ResetAction(BaseModel):
    uid: str | None = None  # omit → reset ALL users
    reset_month_free: bool = True


@app.post("/admin/reset-usage")
def admin_reset_usage(body: ResetAction, authorization: str = Header(...)):
    """Reset usage. One user (uid) or ALL users (uid omitted).

    Resets the live key's budget window (fresh 24h) and clears the monthly
    free-cap counter. For a single user it's immediate; for ALL it loops every
    known user.
    """
    _require_admin(authorization)
    headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
    targets = [body.uid] if body.uid else list(rds.smembers(ALL_UIDS_SET))
    reset = 0
    import datetime as _dt
    ym = _dt.datetime.utcnow().strftime("%Y-%m")
    with httpx.Client(base_url=LITELLM_BASE, timeout=20) as c:
        for uid in targets:
            if not uid:
                continue
            key = rds.get(f"user:{uid}:keyid")
            tier = effective_tier(uid)
            if key:
                try:
                    # Re-applying the budget window resets the spend clock.
                    c.post(
                        "/key/update",
                        headers=headers,
                        json={
                            "key": key,
                            "max_budget": tier_budget(uid, tier)[0],
                            "budget_duration": tier_budget(uid, tier)[1],
                            "spend": 0,
                        },
                    )
                    reset += 1
                except Exception as e:  # noqa: BLE001
                    print(f"reset-usage error for {uid}: {e}")
            if body.reset_month_free:
                rds.delete(f"freecap:{uid}:{ym}")
    return {"ok": True, "reset": reset}


# ── Admin web page (localhost / SSH-tunnel only — NOT routed publicly) ──
# This page is served by the mint service on port 8090. Caddy's public vhost
# only exposes /v1, /mint, /usage, /healthz — NOT /admin — so this console is
# reachable ONLY through an SSH tunnel to 127.0.0.1:8090. It calls the admin
# endpoints with the master key you paste in (kept in the tab's memory only).
_ADMIN_HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Ovid Admin</title>
<style>
 body{font:15px/1.5 system-ui,sans-serif;max-width:720px;margin:0 auto;padding:24px;background:#0d1117;color:#e6edf3}
 h1{font-size:20px}h2{font-size:15px;margin:22px 0 8px;color:#8b949e;text-transform:uppercase;letter-spacing:.08em}
 .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:16px;margin:10px 0}
 label{display:block;font-size:12px;color:#8b949e;margin:8px 0 4px}
 input,select{width:100%;box-sizing:border-box;padding:10px;border-radius:8px;border:1px solid #30363d;background:#0d1117;color:#e6edf3;font-size:14px}
 button{margin-top:12px;padding:10px 16px;border:0;border-radius:8px;background:#2f81f7;color:#fff;font-size:14px;font-weight:600;cursor:pointer}
 button.danger{background:#da3633}
 .row{display:flex;gap:10px}.row>div{flex:1}
 .out{margin-top:10px;font-size:12px;color:#7ee787;white-space:pre-wrap;font-family:ui-monospace,monospace}
 .err{color:#ff7b72}.muted{color:#8b949e;font-size:12px}
</style></head><body>
<h1>Ovid Cloud — Admin</h1>
<div class=card>
 <label>Master key (stays in this tab only)</label>
 <input id=mk type=password placeholder="sk-ovid-...">
 <div class=muted>Paste once. Used to authorize the actions below.</div>
</div>

<h2>Free base limit (applies to ALL users)</h2>
<div class=card>
 <label>Daily free budget (USD) — paid plans auto-scale: free × 5 / 10 / 20</label>
 <input id=base type=number step=0.01 value=0.50>
 <button onclick=setBase()>Apply to ALL users</button>
 <div class=muted>New + existing users updated at once. 3x=base×3, 7x=base×7, 15x=base×15 (per user, not shared).</div>
 <div class=out id=baseOut></div>
</div>

<h2>Reset usage</h2>
<div class=card>
 <button class=danger onclick=resetAll()>Reset usage for ALL users</button>
 <div class=row>
  <div><label>Or one user (uid)</label><input id=resetUid placeholder="firebase uid"></div>
 </div>
 <button onclick=resetOne()>Reset this user</button>
 <div class=out id=resetOut></div>
</div>

<h2>Per-user override</h2>
<div class=card>
 <label>User id (uid)</label><input id=uid placeholder="firebase uid">
 <div class=row>
  <div><label>Tier</label><select id=tier><option value="">(no change)</option><option>free</option><option>3x</option><option>7x</option><option>15x</option></select></div>
  <div><label>Daily USD (optional)</label><input id=duid type=number step=0.01 placeholder="auto"></div>
 </div>
 <button onclick=setTier()>Apply to user</button>
 <div class=out id=tierOut></div>
</div>

<h2>Ban / unban</h2>
<div class=card>
 <div class=row>
  <div><label>uid</label><input id=banUid></div>
  <div><label>ip (optional)</label><input id=banIp></div>
 </div>
 <button class=danger onclick=ban()>Ban</button>
 <button onclick=unban()>Unban</button>
 <div class=out id=banOut></div>
</div>

<script>
function mk(){return document.getElementById('mk').value.trim()}
async function call(path,body,outId){
 const o=document.getElementById(outId);o.className='out';o.textContent='…';
 try{
  const r=await fetch(path,{method:'POST',headers:{'Authorization':'Bearer '+mk(),'Content-Type':'application/json'},body:JSON.stringify(body||{})});
  const t=await r.text();
  if(!r.ok){o.className='out err';o.textContent=r.status+' '+t;return}
  o.textContent=t;
 }catch(e){o.className='out err';o.textContent=String(e)}
}
function setBase(){call('/admin/set-base-budget',{daily_usd:parseFloat(document.getElementById('base').value),reapply:true},'baseOut')}
function resetAll(){if(confirm('Reset usage for ALL users?'))call('/admin/reset-usage',{},'resetOut')}
function resetOne(){call('/admin/reset-usage',{uid:document.getElementById('resetUid').value.trim()},'resetOut')}
function setTier(){const b={uid:document.getElementById('uid').value.trim()};const t=document.getElementById('tier').value;const d=document.getElementById('duid').value;if(t)b.tier=t;if(d)b.daily_usd=parseFloat(d);call('/admin/set-tier',b,'tierOut')}
function ban(){call('/admin/ban',{uid:document.getElementById('banUid').value.trim()||null,ip:document.getElementById('banIp').value.trim()||null},'banOut')}
function unban(){call('/admin/unban',{uid:document.getElementById('banUid').value.trim()||null,ip:document.getElementById('banIp').value.trim()||null},'banOut')}
</script></body></html>"""


@app.get("/admin", response_class=HTMLResponse)
@app.get("/admin/ui", response_class=HTMLResponse)
def admin_ui():
    return HTMLResponse(_ADMIN_HTML)


# ── Ovid image routes (mounted on this mint app; no separate service) ──
# Mounts /v1/images/* using this app's existing auth + Redis budget authority.
# Guarded so a missing key/config never blocks mint startup.
try:
    import images_gateway  # noqa: E402,F401
except Exception as _image_mount_error:  # noqa: BLE001
    print(f"images_mount import skipped: {_image_mount_error}")


@app.on_event("startup")
def _start_monitors() -> None:
    threading.Thread(target=_spend_monitor, daemon=True).start()
