# IP-hop guard

Impossible-travel and country-burst detection for authenticated account
requests. A flag blocks the newer session, keeps the older one, writes an audit
row and claims exactly one alert per account/window.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `IP_HOP_DATABASE_URL` | unset | PostgreSQL DSN shared by all API instances. Takes precedence over the SQLite path. |
| `IP_HOP_DATABASE_PATH` | unset | Absolute path to a local SQLite authority (development / single host). |
| `IP_HOP_POSTGRES_ENSURE_SCHEMA` | `true` | Apply `schema_postgres.sql` at startup. Set `false` when migrations own the schema. |
| `IP_HOP_GEOIP_DB` | unset | Local MaxMind GeoLite2/GeoIP2 **City** (or Country) `.mmdb`. |
| `IP_HOP_GEOIP_ASN_DB` | unset | Optional MaxMind ASN `.mmdb`; requires `IP_HOP_GEOIP_DB`. |
| `IP_HOP_TRUST_GEO_HEADERS` | `false` | Trust `X-Ovid-*` ASN/city/coordinates from a proxy that strips client values. |
| `IP_HOP_FAIL_CLOSED` | `false` | Reject requests the guard cannot evaluate (see below). |
| `IP_HOP_EMAIL_FACTORY` | unset | `module:attribute` returning the alert callable. |

With **no** database configured the guard is disabled. `IP_HOP_FAIL_CLOSED=true`
without a database is a startup error, because a disabled guard would silently
fail open.

### Stores

- **PostgreSQL** (`PostgresIpHopStore`) is required for more than one API
  instance: observations, blocks, overrides, audit and alert claims are shared
  and each statement autocommits. Provision with
  `psql "$IP_HOP_DATABASE_URL" -f server/security/schema_postgres.sql`, or leave
  `IP_HOP_POSTGRES_ENSURE_SCHEMA=true` to apply the idempotent DDL at startup.
- **SQLite** (`SqliteIpHopStore`) remains the single-host development default
  (`server/security/schema.sql`).

### Location resolution

1. `IP_HOP_GEOIP_DB` → `MaxMindGeoResolver` (coordinates, country, city) plus
   `IP_HOP_GEOIP_ASN_DB` for ASN. Requires the `maxminddb` package (installed
   with the account requirements).
2. No database → `HeaderGeoResolver` in **country-only** mode: `CF-IPCountry`
   is used and no coordinates are produced. Country bursts are still detected;
   impossible-travel speed checks are skipped because there is no distance.
3. With a database the resolver chain prefers GeoIP fields and fills a missing
   country from the edge header.

The MaxMind file is opened at startup; to publish a new database, replace the
file and restart the service. A configured but unreadable database is a startup
error rather than a silent fallback.

`FakeGeoResolver` (exact IP + CIDR + default) is the deterministic test double;
`StaticGeoResolver` remains an exact-IP alias for existing tests.

## Fail-open vs fail-closed

- **Fail-open (default):** if the store or resolver is unavailable, the guard
  records nothing and returns `Decision(recorded=False,
  reason="guard_unavailable")`; authentication continues. A resolver failure
  degrades to prefix/country detection.
- **Fail-closed:** `IpHopGuard(..., fail_closed=True)` /
  `IP_HOP_FAIL_CLOSED=true` raises `IpHopUnavailable` (`503`,
  `ip_hop_unavailable`) when the store cannot be read/written or the request has
  no usable IP address. An already blocked session still returns the normal
  `403 session_blocked_ip_hop`.

## Per-key IP fan-out (`key_ip_fanout.py`)

One key belongs to one account on one platform, so a key seen from many
unrelated networks at once is a leaked or shared key.

- Every sighting of a key records the coarse prefix (IPv4 `/24`, IPv6 `/48`).
- More than `limit` distinct prefixes inside `window_seconds` → the key is
  blocked for `block_seconds`, callers get `403 key_ip_fanout`, and exactly one
  operator email event is queued **per block event** (the event key is claimed
  once; repeated sightings of an already-blocked key never re-alert).
- At or below the limit is allowed: Wi-Fi + carrier + a commute is normal
  mobile use.
- Admin unblock clears the block *and* the observation window so a reviewed
  key does not instantly re-block, and writes an `unblock` audit row.
- The email payload carries `key_ref` (truncated SHA-256 fingerprint), the uid,
  the platform, the coarse prefixes and counters — never the key, its full
  hash, a bearer token or a full IP address.

| Variable | Default | Purpose |
| --- | --- | --- |
| `KEY_IP_FANOUT_LIMIT` | `5` | Distinct prefixes allowed inside the window. |
| `KEY_IP_FANOUT_WINDOW_S` | `900` | Observation window (15 min). |
| `KEY_IP_FANOUT_BLOCK_S` | `86400` | Block duration. |

Stores: `MemoryKeyIpStore` (tests) and `RedisKeyIpStore` (production, the mint
Redis db 2). The guard is used by mint's `/mint` and `/usage`; the same module
can be mounted in the account service.

## Retention

`guard.prune(now)` removes observations older than `retention_seconds`, bounds
each account to `max_observations_per_account`, drops expired blocks and
overrides, and applies audit/alert retention. It runs on observation traffic
with a 60-second throttle; deployments with idle periods should also call
`guard.prune()` from the retention timer.
