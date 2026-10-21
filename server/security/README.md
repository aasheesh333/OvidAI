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

## Retention

`guard.prune(now)` removes observations older than `retention_seconds`, bounds
each account to `max_observations_per_account`, drops expired blocks and
overrides, and applies audit/alert retention. It runs on observation traffic
with a 60-second throttle; deployments with idle periods should also call
`guard.prune()` from the retention timer.
