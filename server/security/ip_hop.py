"""Impossible-travel detection for authenticated account requests.

The guard records a coarse location fingerprint (IP /24 or /48 plus optional
country, ASN, city and coordinates) for every authenticated request.  It flags
an account when two observations imply travel faster than ``max_travel_kmh`` or
when more than ``country_burst_limit`` countries appear inside the country
window.  A flag blocks the newer session, keeps the older one, writes an audit
row and claims exactly one alert per account/window.

No raw bearer token is accepted or stored here.  Callers either pass an opaque
client session id or derive one with :func:`session_from_token`, which stores
only a SHA-256 prefix.

Two durable stores implement the same :class:`LocationStore` surface:
:class:`SqliteIpHopStore` for local/development use and
:class:`PostgresIpHopStore` for multi-instance deployments.  Location lookup is
pluggable: :class:`MaxMindGeoResolver` reads a local MaxMind database,
:class:`HeaderGeoResolver` reads edge country headers only, and
:class:`FakeGeoResolver` is a deterministic test double.

Fail-open is the default: an unavailable store or resolver degrades to "record
nothing, allow the request" so authentication never depends on the guard.
``fail_closed=True`` (``IP_HOP_FAIL_CLOSED=true``) rejects the request with a
503 ``ip_hop_unavailable`` error instead.
"""

from __future__ import annotations

import hashlib
import ipaddress
import math
import os
import re
import sqlite3
import threading
import time
from contextvars import ContextVar
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Protocol

from server.account.domain import AccountError

MAX_TRAVEL_KMH = 900.0
HOP_WINDOW_SECONDS = 60 * 60
COUNTRY_BURST_LIMIT = 3
COUNTRY_WINDOW_SECONDS = 60 * 60
RETENTION_SECONDS = 7 * 24 * 60 * 60
MAX_OBSERVATIONS_PER_ACCOUNT = 256
BLOCK_SECONDS = 24 * 60 * 60
OVERRIDE_SECONDS = 60 * 60
AUDIT_RETENTION_SECONDS = 90 * 24 * 60 * 60
MIN_DISTANCE_KM = 50.0

SESSION_ID_RE = re.compile(r'[A-Za-z0-9_-]{8,128}')
COUNTRY_RE = re.compile(r'[A-Z]{2}')
ASN_RE = re.compile(r'AS[0-9]{1,10}')
UID_RE = re.compile(r'[A-Za-z0-9_-]{1,128}')

# Set by the account HTTP middleware so every admission path (account, shares,
# sync, collaboration, reports) can observe the same request without each
# module having to know about proxy headers.
_REQUEST_CONTEXT: ContextVar[tuple[str, str, Any] | None] = ContextVar(
    'ovid_ip_hop_request_context', default=None)


class IpHopBlocked(AccountError):
    """Authenticated request rejected because its session is blocked."""

    def __init__(self, session_id: str, event_id: str | None = None):
        self.session_id = session_id
        self.event_id = event_id
        super().__init__('session_blocked_ip_hop', 403)


class IpHopUnavailable(AccountError):
    """Fail-closed rejection: the guard could not evaluate this request."""

    def __init__(self):
        super().__init__('ip_hop_unavailable', 503)


@dataclass(frozen=True)
class GeoInfo:
    country: str | None = None
    asn: str | None = None
    city: str | None = None
    latitude: float | None = None
    longitude: float | None = None


@dataclass(frozen=True)
class Observation:
    uid: str
    session_id: str
    ip_prefix: str
    seen_at: float
    country: str | None = None
    asn: str | None = None
    city: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    id: int | None = None


@dataclass(frozen=True)
class Decision:
    recorded: bool
    reason: str | None = None
    blocked_session_id: str | None = None
    older_session_id: str | None = None
    event_id: str | None = None
    alerted: bool = False

    @property
    def allowed(self) -> bool:
        # A blocked current session raises IpHopBlocked instead of returning.
        return True


class GeoResolver(Protocol):
    def resolve(self, ip: str, headers: Any) -> GeoInfo | None: ...


class LocationStore(Protocol):
    def record(self, observation: Observation) -> int: ...
    def recent(self, uid: str, since: float = 0.0) -> list[Observation]: ...
    def blocked(self, uid: str, session_id: str, now: float) -> dict | None: ...
    def active_blocks(self, uid: str, now: float) -> list[dict]: ...
    def block(self, uid: str, session_id: str, reason: str, event_id: str,
              blocked_at: float, blocked_until: float) -> None: ...
    def unblock(self, uid: str, session_id: str | None, now: float) -> list[str]: ...
    def set_override(self, uid: str, session_id: str, until: float, actor: str,
                     reason: str, created_at: float) -> None: ...
    def override_active(self, uid: str, session_id: str, now: float) -> bool: ...
    def audit(self, **fields) -> None: ...
    def audit_rows(self, uid: str | None = None, limit: int = 100) -> list[dict]: ...
    def claim_alert(self, event_key: str, uid: str, now: float) -> bool: ...
    def mark_alert(self, event_key: str, status: str) -> None: ...
    def alert_rows(self, uid: str | None = None) -> list[dict]: ...
    def prune(self, now: float, *, retention_seconds: float,
              max_per_account: int,
              audit_retention_seconds: float | None = None) -> dict: ...


class FakeGeoResolver:
    """Deterministic resolver for tests and local development.

    Lookups are exact address, then the most specific matching CIDR, then
    ``default``.  Nothing here touches the network, the clock or randomness, so
    repeated runs produce identical decisions.
    """

    def __init__(self, locations: Mapping[str, GeoInfo] | None = None, *,
                 networks: Mapping[str, GeoInfo] | None = None,
                 default: GeoInfo | None = None):
        self.locations = {str(ip): geo for ip, geo in (locations or {}).items()}
        self.networks = sorted(
            ((ipaddress.ip_network(network, strict=False), geo)
             for network, geo in (networks or {}).items()),
            key=lambda item: item[0].prefixlen, reverse=True)
        self.default = default
        self.calls: list[str] = []

    def resolve(self, ip: str, headers: Any) -> GeoInfo | None:
        self.calls.append(ip)
        if ip in self.locations:
            return self.locations[ip]
        address = _address(ip)
        if address is None:
            return self.default
        for network, geo in self.networks:
            if address in network:
                return geo
        return self.default


class StaticGeoResolver(FakeGeoResolver):
    """Backward-compatible exact-IP fake."""

    def __init__(self, locations: Mapping[str, GeoInfo]):
        super().__init__(locations)


class HeaderGeoResolver:
    """Resolve coarse location from edge/proxy headers.

    ``CF-IPCountry`` is set by Cloudflare and is safe behind that edge.  ASN,
    city and coordinates are only read when ``trust_geo_headers`` is true; a
    deployment must strip client-supplied ``X-Ovid-*`` headers at the proxy.
    With the default settings this is the country-only mode: no coordinates are
    produced, so impossible-travel detection is skipped while country bursts
    are still detected.
    """

    def __init__(self, *, trust_geo_headers: bool = False):
        self.trust_geo_headers = trust_geo_headers

    def resolve(self, ip: str, headers: Any) -> GeoInfo | None:
        country = _header(headers, 'cf-ipcountry')
        asn = city = latitude = longitude = None
        if self.trust_geo_headers:
            if not country:
                country = _header(headers, 'x-ovid-country')
            asn = _header(headers, 'x-ovid-asn')
            city = _header(headers, 'x-ovid-city')
            latitude = _to_float(_header(headers, 'x-ovid-latitude'))
            longitude = _to_float(_header(headers, 'x-ovid-longitude'))
        geo = _normalize_geo(GeoInfo(country, asn, city, latitude, longitude))
        return geo


class MaxMindGeoResolver:
    """Resolve location from a local MaxMind GeoLite2/GeoIP2 database.

    ``database_path`` points at a City or Country ``.mmdb`` file.  An optional
    ``asn_database_path`` supplies autonomous system numbers from the separate
    MaxMind ASN database.  Readers are opened eagerly so a missing database or
    missing ``maxminddb`` package fails at startup instead of silently
    disabling travel detection.  ``reader_factory`` exists for deterministic
    tests that do not ship a binary database.
    """

    def __init__(self, database_path: str, *, asn_database_path: str | None = None,
                 reader_factory=None):
        if not isinstance(database_path, str) or not database_path.strip():
            raise ValueError('MaxMind database path is required')
        factory = reader_factory or _open_maxmind_database
        self.database_path = database_path
        self.asn_database_path = asn_database_path
        self._reader = factory(self.database_path)
        self._asn_reader = (factory(self.asn_database_path)
                            if asn_database_path else None)

    def resolve(self, ip: str, headers: Any) -> GeoInfo | None:
        address = _address_text(ip)
        if address is None:
            return None
        city_record = self._reader.get(address)
        asn_record = self._asn_reader.get(address) if self._asn_reader else None
        return geo_from_maxmind(city_record, asn_record)

    def close(self) -> None:
        for reader in (self._reader, self._asn_reader):
            close = getattr(reader, 'close', None)
            if callable(close):
                close()


class ChainGeoResolver:
    """Merge resolvers field by field; earlier resolvers win.

    The intended order is GeoIP first, edge headers second: the database
    supplies coordinates and the header can still fill a missing country.
    A resolver that raises is skipped so one failing data source cannot discard
    location data from the others.
    """

    def __init__(self, *resolvers: GeoResolver):
        if not resolvers:
            raise ValueError('At least one resolver is required')
        self.resolvers = tuple(resolvers)

    def resolve(self, ip: str, headers: Any) -> GeoInfo | None:
        merged: dict[str, Any] = {}
        for resolver in self.resolvers:
            try:
                geo = _normalize_geo(resolver.resolve(ip, headers))
            except Exception:
                continue
            if geo is None:
                continue
            for field in ('country', 'asn', 'city', 'latitude', 'longitude'):
                if merged.get(field) is None:
                    merged[field] = getattr(geo, field, None)
        return _normalize_geo(GeoInfo(**merged))


def build_geo_resolver(*, database_path: str | None = None,
                       asn_database_path: str | None = None,
                       trust_geo_headers: bool = False,
                       reader_factory=None) -> GeoResolver:
    """Build the deployment resolver from ``IP_HOP_GEOIP_*`` settings.

    Without a database this degrades to country-only header resolution.  With
    a database the GeoIP lookup is chained ahead of the headers.
    """
    database_path = (database_path or '').strip() or None
    asn_database_path = (asn_database_path or '').strip() or None
    if asn_database_path and not database_path:
        raise ValueError('IP_HOP_GEOIP_ASN_DB requires IP_HOP_GEOIP_DB')
    header = HeaderGeoResolver(trust_geo_headers=trust_geo_headers)
    if database_path is None:
        return header
    return ChainGeoResolver(
        MaxMindGeoResolver(database_path, asn_database_path=asn_database_path,
                           reader_factory=reader_factory),
        header)


def geo_from_maxmind(city_record: Mapping | None,
                     asn_record: Mapping | None = None) -> GeoInfo | None:
    """Convert MaxMind City/ASN records into a normalized :class:`GeoInfo`."""
    city_record = city_record if isinstance(city_record, Mapping) else {}
    asn_record = asn_record if isinstance(asn_record, Mapping) else {}
    country = (_nested_text(city_record, 'country', 'iso_code') or
               _nested_text(city_record, 'registered_country', 'iso_code'))
    city = _localized_name(_nested(city_record, 'city', 'names'))
    latitude = _nested(city_record, 'location', 'latitude')
    longitude = _nested(city_record, 'location', 'longitude')
    asn_number = asn_record.get('autonomous_system_number')
    asn = None
    if isinstance(asn_number, int) and not isinstance(asn_number, bool) and asn_number > 0:
        asn = f'AS{asn_number}'
    elif isinstance(asn_number, str) and asn_number.strip():
        asn = asn_number.strip()
    return _normalize_geo(GeoInfo(country, asn, city, latitude, longitude))


def _open_maxmind_database(path: str):
    try:
        import maxminddb
    except ImportError as error:  # pragma: no cover - exercised without the extra
        raise RuntimeError(
            "IP_HOP_GEOIP_DB requires the 'maxminddb' package "
            "(pip install maxminddb)") from error
    return maxminddb.open_database(path)


def _nested(record: Mapping, *keys: str):
    value: Any = record
    for key in keys:
        if not isinstance(value, Mapping):
            return None
        value = value.get(key)
    return value


def _nested_text(record: Mapping, *keys: str) -> str | None:
    value = _nested(record, *keys)
    return value.strip() if isinstance(value, str) and value.strip() else None


def _localized_name(names: Any) -> str | None:
    if not isinstance(names, Mapping):
        return None
    preferred = names.get('en')
    if isinstance(preferred, str) and preferred.strip():
        return preferred.strip()
    for value in names.values():
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _address(ip: str):
    """Return an ``ipaddress`` object with IPv4-mapped addresses unwrapped."""
    if not isinstance(ip, str) or not ip.strip():
        return None
    try:
        address = ipaddress.ip_address(ip.strip())
    except ValueError:
        return None
    if address.version == 6 and address.ipv4_mapped is not None:
        return address.ipv4_mapped
    return address


def _address_text(ip: str) -> str | None:
    address = _address(ip)
    return str(address) if address is not None else None


class SqliteIpHopStore:
    """Durable, bounded local authority for observations, blocks and audit."""

    def __init__(self, path: str = ':memory:'):
        self.path = path
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False, timeout=15)
        self._db.row_factory = sqlite3.Row
        if path != ':memory:':
            self._db.execute('PRAGMA journal_mode=WAL')
        with self._lock, self._db:
            self._db.executescript('''
                CREATE TABLE IF NOT EXISTS ip_hop_observations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uid TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    ip_prefix TEXT NOT NULL,
                    country TEXT,
                    asn TEXT,
                    city TEXT,
                    latitude REAL,
                    longitude REAL,
                    seen_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS ip_hop_observations_uid_seen
                    ON ip_hop_observations (uid, seen_at);
                CREATE INDEX IF NOT EXISTS ip_hop_observations_seen
                    ON ip_hop_observations (seen_at);
                CREATE TABLE IF NOT EXISTS ip_hop_blocks (
                    uid TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    event_id TEXT NOT NULL,
                    blocked_at REAL NOT NULL,
                    blocked_until REAL NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (uid, session_id)
                );
                CREATE INDEX IF NOT EXISTS ip_hop_blocks_uid_active
                    ON ip_hop_blocks (uid, active, blocked_until);
                CREATE TABLE IF NOT EXISTS ip_hop_overrides (
                    uid TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    until_at REAL NOT NULL,
                    actor TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (uid, session_id)
                );
                CREATE TABLE IF NOT EXISTS ip_hop_audit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL,
                    uid TEXT NOT NULL,
                    action TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    actor TEXT,
                    session_id TEXT,
                    older_session_id TEXT,
                    ip_prefix TEXT,
                    older_ip_prefix TEXT,
                    country TEXT,
                    older_country TEXT,
                    asn TEXT,
                    older_asn TEXT,
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS ip_hop_audit_uid_created
                    ON ip_hop_audit (uid, created_at);
                CREATE TABLE IF NOT EXISTS ip_hop_alerts (
                    event_key TEXT PRIMARY KEY,
                    uid TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    status TEXT NOT NULL
                );
            ''')

    def close(self):
        with self._lock:
            self._db.close()

    def record(self, observation: Observation) -> int:
        with self._lock, self._db:
            cursor = self._db.execute('''
                INSERT INTO ip_hop_observations
                    (uid, session_id, ip_prefix, country, asn, city,
                     latitude, longitude, seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (observation.uid, observation.session_id, observation.ip_prefix,
                  observation.country, observation.asn, observation.city,
                  observation.latitude, observation.longitude, observation.seen_at))
            return int(cursor.lastrowid)

    def recent(self, uid: str, since: float = 0.0) -> list[Observation]:
        with self._lock:
            rows = self._db.execute('''
                SELECT * FROM ip_hop_observations
                WHERE uid = ? AND seen_at >= ?
                ORDER BY seen_at ASC, id ASC
            ''', (uid, since)).fetchall()
        return [_observation(row) for row in rows]

    def blocked(self, uid: str, session_id: str, now: float) -> dict | None:
        with self._lock, self._db:
            row = self._db.execute('''
                SELECT * FROM ip_hop_blocks
                WHERE uid = ? AND session_id = ? AND active = 1
            ''', (uid, session_id)).fetchone()
            if row is None:
                return None
            if row['blocked_until'] <= now:
                self._db.execute('''
                    UPDATE ip_hop_blocks SET active = 0
                    WHERE uid = ? AND session_id = ? AND active = 1
                ''', (uid, session_id))
                return None
            return dict(row)

    def block(self, uid: str, session_id: str, reason: str, event_id: str,
              blocked_at: float, blocked_until: float) -> None:
        with self._lock, self._db:
            self._db.execute('''
                INSERT INTO ip_hop_blocks
                    (uid, session_id, reason, event_id, blocked_at, blocked_until, active)
                VALUES (?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT (uid, session_id) DO UPDATE SET
                    reason = excluded.reason,
                    event_id = excluded.event_id,
                    blocked_at = excluded.blocked_at,
                    blocked_until = excluded.blocked_until,
                    active = 1
            ''', (uid, session_id, reason, event_id, blocked_at, blocked_until))

    def unblock(self, uid: str, session_id: str | None, now: float) -> list[str]:
        with self._lock, self._db:
            if session_id is None:
                rows = self._db.execute('''
                    SELECT session_id FROM ip_hop_blocks
                    WHERE uid = ? AND active = 1
                ''', (uid,)).fetchall()
            else:
                rows = self._db.execute('''
                    SELECT session_id FROM ip_hop_blocks
                    WHERE uid = ? AND session_id = ? AND active = 1
                ''', (uid, session_id)).fetchall()
            sessions = [row['session_id'] for row in rows]
            for blocked_session in sessions:
                self._db.execute('''
                    UPDATE ip_hop_blocks SET active = 0
                    WHERE uid = ? AND session_id = ? AND active = 1
                ''', (uid, blocked_session))
            return sessions

    def set_override(self, uid: str, session_id: str, until: float, actor: str,
                     reason: str, created_at: float) -> None:
        with self._lock, self._db:
            self._db.execute('''
                INSERT INTO ip_hop_overrides
                    (uid, session_id, until_at, actor, reason, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (uid, session_id) DO UPDATE SET
                    until_at = excluded.until_at,
                    actor = excluded.actor,
                    reason = excluded.reason,
                    created_at = excluded.created_at
            ''', (uid, session_id, until, actor, reason, created_at))

    def override_active(self, uid: str, session_id: str, now: float) -> bool:
        with self._lock, self._db:
            row = self._db.execute('''
                SELECT until_at FROM ip_hop_overrides
                WHERE uid = ? AND session_id = ?
            ''', (uid, session_id)).fetchone()
            if row is None:
                return False
            if row['until_at'] <= now:
                self._db.execute('''
                    DELETE FROM ip_hop_overrides
                    WHERE uid = ? AND session_id = ?
                ''', (uid, session_id))
                return False
            return True

    def audit(self, **fields) -> None:
        allowed = ('event_id', 'uid', 'action', 'reason', 'actor', 'session_id',
                   'older_session_id', 'ip_prefix', 'older_ip_prefix', 'country',
                   'older_country', 'asn', 'older_asn', 'created_at')
        values = {key: fields.get(key) for key in allowed}
        with self._lock, self._db:
            self._db.execute('''
                INSERT INTO ip_hop_audit
                    (event_id, uid, action, reason, actor, session_id,
                     older_session_id, ip_prefix, older_ip_prefix, country,
                     older_country, asn, older_asn, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', tuple(values[key] for key in allowed))

    def audit_rows(self, uid: str | None = None, limit: int = 100) -> list[dict]:
        with self._lock:
            if uid is None:
                rows = self._db.execute('''
                    SELECT * FROM ip_hop_audit ORDER BY id DESC LIMIT ?
                ''', (limit,)).fetchall()
            else:
                rows = self._db.execute('''
                    SELECT * FROM ip_hop_audit WHERE uid = ?
                    ORDER BY id DESC LIMIT ?
                ''', (uid, limit)).fetchall()
        return [dict(row) for row in rows]

    def claim_alert(self, event_key: str, uid: str, now: float) -> bool:
        with self._lock, self._db:
            cursor = self._db.execute('''
                INSERT OR IGNORE INTO ip_hop_alerts
                    (event_key, uid, created_at, status)
                VALUES (?, ?, ?, 'claimed')
            ''', (event_key, uid, now))
            return cursor.rowcount == 1

    def mark_alert(self, event_key: str, status: str) -> None:
        with self._lock, self._db:
            self._db.execute('''
                UPDATE ip_hop_alerts SET status = ? WHERE event_key = ?
            ''', (status, event_key))

    def alert_rows(self, uid: str | None = None) -> list[dict]:
        with self._lock:
            if uid is None:
                rows = self._db.execute('''
                    SELECT * FROM ip_hop_alerts ORDER BY created_at DESC
                ''').fetchall()
            else:
                rows = self._db.execute('''
                    SELECT * FROM ip_hop_alerts WHERE uid = ?
                    ORDER BY created_at DESC
                ''', (uid,)).fetchall()
        return [dict(row) for row in rows]

    def active_blocks(self, uid: str, now: float) -> list[dict]:
        with self._lock:
            rows = self._db.execute('''
                SELECT * FROM ip_hop_blocks
                WHERE uid = ? AND active = 1 AND blocked_until > ?
                ORDER BY blocked_at ASC
            ''', (uid, now)).fetchall()
        return [dict(row) for row in rows]

    def prune(self, now: float, *, retention_seconds: float,
              max_per_account: int, audit_retention_seconds: float | None = None) -> dict:
        if retention_seconds < 0 or max_per_account < 1:
            raise ValueError('Invalid retention policy')
        cutoff = now - retention_seconds
        with self._lock, self._db:
            observations = self._db.execute('''
                DELETE FROM ip_hop_observations WHERE seen_at < ?
            ''', (cutoff,)).rowcount
            bounded = 0
            groups = self._db.execute('''
                SELECT uid, COUNT(*) AS total FROM ip_hop_observations
                GROUP BY uid HAVING COUNT(*) > ?
            ''', (max_per_account,)).fetchall()
            for group in groups:
                excess = group['total'] - max_per_account
                rows = self._db.execute('''
                    SELECT id FROM ip_hop_observations WHERE uid = ?
                    ORDER BY seen_at ASC, id ASC LIMIT ?
                ''', (group['uid'], excess)).fetchall()
                if rows:
                    self._db.executemany(
                        'DELETE FROM ip_hop_observations WHERE id = ?',
                        [(row['id'],) for row in rows])
                    bounded += len(rows)
            blocks = self._db.execute('''
                DELETE FROM ip_hop_blocks WHERE blocked_until <= ?
            ''', (now,)).rowcount
            overrides = self._db.execute('''
                DELETE FROM ip_hop_overrides WHERE until_at <= ?
            ''', (now,)).rowcount
            audit = 0
            if audit_retention_seconds is not None:
                audit = self._db.execute('''
                    DELETE FROM ip_hop_audit WHERE created_at < ?
                ''', (now - audit_retention_seconds,)).rowcount
            alert_cutoff = now - (audit_retention_seconds
                                  if audit_retention_seconds is not None
                                  else retention_seconds)
            alerts = self._db.execute('''
                DELETE FROM ip_hop_alerts WHERE created_at < ?
            ''', (alert_cutoff,)).rowcount
        return {'observations': observations + bounded, 'blocks': blocks,
                'overrides': overrides, 'audit': audit, 'alerts': alerts}


class PostgresIpHopStore:
    """PostgreSQL authority shared by every API instance.

    The surface is identical to :class:`SqliteIpHopStore`.  ``dsn`` may carry a
    ``search_path`` option (``?options=-csearch_path%3D...``) for scoped
    deployments.  A single connection is reused under a lock and re-opened once
    after an operational failure; each statement is autocommitted so a block
    written by one instance is immediately visible to the others.
    """

    def __init__(self, dsn: str, *, ensure_schema: bool = True):
        if not isinstance(dsn, str) or not dsn.strip():
            raise ValueError('PostgreSQL DSN is required')
        try:
            import psycopg
            from psycopg.rows import dict_row
        except ImportError as error:  # pragma: no cover - psycopg is a deployment extra
            raise RuntimeError(
                'PostgresIpHopStore requires psycopg (pip install "psycopg[binary]")'
            ) from error
        self.dsn = dsn
        self._psycopg = psycopg
        self._dict_row = dict_row
        self._lock = threading.RLock()
        self._db = None
        self._pid = os.getpid()
        self._connect()
        if ensure_schema:
            try:
                self._ensure_schema()
            except Exception:
                self._reset()
                raise

    def close(self) -> None:
        with self._lock:
            self._reset()

    def _connect(self):
        self._db = self._psycopg.connect(
            self.dsn, autocommit=True, connect_timeout=10,
            row_factory=self._dict_row)
        return self._db

    def _connection(self):
        # A connection created before a pre-fork worker split must not be
        # shared with the parent or sibling workers.
        if self._pid != os.getpid():
            self._reset()
            self._pid = os.getpid()
        if self._db is None or self._db.closed:
            self._connect()
        return self._db

    def _reset(self) -> None:
        connection, self._db = self._db, None
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass

    def _run(self, operation):
        """Run one operation, retrying once with a fresh connection."""
        with self._lock:
            try:
                return operation(self._connection())
            except self._psycopg.OperationalError:
                self._reset()
                return operation(self._connection())

    def _ensure_schema(self) -> None:
        statements = _schema_statements(
            Path(__file__).with_name('schema_postgres.sql').read_text(encoding='utf-8'))

        def apply(connection):
            for statement in statements:
                connection.execute(statement)

        self._run(apply)

    def record(self, observation: Observation) -> int:
        def operation(connection):
            row = connection.execute('''
                INSERT INTO ip_hop_observations
                    (uid, session_id, ip_prefix, country, asn, city,
                     latitude, longitude, seen_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
            ''', (observation.uid, observation.session_id,
                  observation.ip_prefix, observation.country, observation.asn,
                  observation.city, observation.latitude, observation.longitude,
                  observation.seen_at)).fetchone()
            return int(row['id'])

        return self._run(operation)

    def recent(self, uid: str, since: float = 0.0) -> list[Observation]:
        def operation(connection):
            rows = connection.execute('''
                SELECT * FROM ip_hop_observations
                WHERE uid = %s AND seen_at >= %s
                ORDER BY seen_at ASC, id ASC
            ''', (uid, since)).fetchall()
            return [_observation(row) for row in rows]

        return self._run(operation)

    def blocked(self, uid: str, session_id: str, now: float) -> dict | None:
        def operation(connection):
            row = connection.execute('''
                SELECT * FROM ip_hop_blocks
                WHERE uid = %s AND session_id = %s AND active = TRUE
            ''', (uid, session_id)).fetchone()
            if row is None:
                return None
            if row['blocked_until'] <= now:
                connection.execute('''
                    UPDATE ip_hop_blocks SET active = FALSE
                    WHERE uid = %s AND session_id = %s AND active = TRUE
                ''', (uid, session_id))
                return None
            return dict(row)

        return self._run(operation)

    def block(self, uid: str, session_id: str, reason: str, event_id: str,
              blocked_at: float, blocked_until: float) -> None:
        def operation(connection):
            connection.execute('''
                INSERT INTO ip_hop_blocks
                    (uid, session_id, reason, event_id, blocked_at, blocked_until, active)
                VALUES (%s, %s, %s, %s, %s, %s, TRUE)
                ON CONFLICT (uid, session_id) DO UPDATE SET
                    reason = excluded.reason,
                    event_id = excluded.event_id,
                    blocked_at = excluded.blocked_at,
                    blocked_until = excluded.blocked_until,
                    active = TRUE
            ''', (uid, session_id, reason, event_id, blocked_at, blocked_until))

        self._run(operation)

    def unblock(self, uid: str, session_id: str | None, now: float) -> list[str]:
        def operation(connection):
            if session_id is None:
                rows = connection.execute('''
                    SELECT session_id FROM ip_hop_blocks
                    WHERE uid = %s AND active = TRUE
                ''', (uid,)).fetchall()
            else:
                rows = connection.execute('''
                    SELECT session_id FROM ip_hop_blocks
                    WHERE uid = %s AND session_id = %s AND active = TRUE
                ''', (uid, session_id)).fetchall()
            sessions = [row['session_id'] for row in rows]
            for blocked_session in sessions:
                connection.execute('''
                    UPDATE ip_hop_blocks SET active = FALSE
                    WHERE uid = %s AND session_id = %s AND active = TRUE
                ''', (uid, blocked_session))
            return sessions

        return self._run(operation)

    def set_override(self, uid: str, session_id: str, until: float, actor: str,
                     reason: str, created_at: float) -> None:
        def operation(connection):
            connection.execute('''
                INSERT INTO ip_hop_overrides
                    (uid, session_id, until_at, actor, reason, created_at)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (uid, session_id) DO UPDATE SET
                    until_at = excluded.until_at,
                    actor = excluded.actor,
                    reason = excluded.reason,
                    created_at = excluded.created_at
            ''', (uid, session_id, until, actor, reason, created_at))

        self._run(operation)

    def override_active(self, uid: str, session_id: str, now: float) -> bool:
        def operation(connection):
            row = connection.execute('''
                SELECT until_at FROM ip_hop_overrides
                WHERE uid = %s AND session_id = %s
            ''', (uid, session_id)).fetchone()
            if row is None:
                return False
            if row['until_at'] <= now:
                connection.execute('''
                    DELETE FROM ip_hop_overrides
                    WHERE uid = %s AND session_id = %s
                ''', (uid, session_id))
                return False
            return True

        return self._run(operation)

    def audit(self, **fields) -> None:
        allowed = ('event_id', 'uid', 'action', 'reason', 'actor', 'session_id',
                   'older_session_id', 'ip_prefix', 'older_ip_prefix', 'country',
                   'older_country', 'asn', 'older_asn', 'created_at')
        values = tuple(fields.get(key) for key in allowed)

        def operation(connection):
            connection.execute('''
                INSERT INTO ip_hop_audit
                    (event_id, uid, action, reason, actor, session_id,
                     older_session_id, ip_prefix, older_ip_prefix, country,
                     older_country, asn, older_asn, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ''', values)

        self._run(operation)

    def audit_rows(self, uid: str | None = None, limit: int = 100) -> list[dict]:
        def operation(connection):
            if uid is None:
                rows = connection.execute('''
                    SELECT * FROM ip_hop_audit ORDER BY id DESC LIMIT %s
                ''', (limit,)).fetchall()
            else:
                rows = connection.execute('''
                    SELECT * FROM ip_hop_audit WHERE uid = %s
                    ORDER BY id DESC LIMIT %s
                ''', (uid, limit)).fetchall()
            return [dict(row) for row in rows]

        return self._run(operation)

    def claim_alert(self, event_key: str, uid: str, now: float) -> bool:
        def operation(connection):
            cursor = connection.execute('''
                INSERT INTO ip_hop_alerts (event_key, uid, created_at, status)
                VALUES (%s, %s, %s, 'claimed')
                ON CONFLICT (event_key) DO NOTHING
            ''', (event_key, uid, now))
            return cursor.rowcount == 1

        return self._run(operation)

    def mark_alert(self, event_key: str, status: str) -> None:
        def operation(connection):
            connection.execute('''
                UPDATE ip_hop_alerts SET status = %s WHERE event_key = %s
            ''', (status, event_key))

        self._run(operation)

    def alert_rows(self, uid: str | None = None) -> list[dict]:
        def operation(connection):
            if uid is None:
                rows = connection.execute(
                    'SELECT * FROM ip_hop_alerts ORDER BY created_at DESC').fetchall()
            else:
                rows = connection.execute('''
                    SELECT * FROM ip_hop_alerts WHERE uid = %s
                    ORDER BY created_at DESC
                ''', (uid,)).fetchall()
            return [dict(row) for row in rows]

        return self._run(operation)

    def active_blocks(self, uid: str, now: float) -> list[dict]:
        def operation(connection):
            rows = connection.execute('''
                SELECT * FROM ip_hop_blocks
                WHERE uid = %s AND active = TRUE AND blocked_until > %s
                ORDER BY blocked_at ASC
            ''', (uid, now)).fetchall()
            return [dict(row) for row in rows]

        return self._run(operation)

    def prune(self, now: float, *, retention_seconds: float,
              max_per_account: int, audit_retention_seconds: float | None = None) -> dict:
        if retention_seconds < 0 or max_per_account < 1:
            raise ValueError('Invalid retention policy')
        cutoff = now - retention_seconds

        def operation(connection):
            observations = connection.execute('''
                DELETE FROM ip_hop_observations WHERE seen_at < %s
            ''', (cutoff,)).rowcount
            bounded = connection.execute('''
                WITH ranked AS (
                    SELECT id, row_number() OVER (
                        PARTITION BY uid ORDER BY seen_at DESC, id DESC) AS ranked_position
                    FROM ip_hop_observations
                )
                DELETE FROM ip_hop_observations AS observation
                USING ranked
                WHERE observation.id = ranked.id AND ranked.ranked_position > %s
            ''', (max_per_account,)).rowcount
            blocks = connection.execute('''
                DELETE FROM ip_hop_blocks WHERE blocked_until <= %s
            ''', (now,)).rowcount
            overrides = connection.execute('''
                DELETE FROM ip_hop_overrides WHERE until_at <= %s
            ''', (now,)).rowcount
            audit = 0
            if audit_retention_seconds is not None:
                audit = connection.execute('''
                    DELETE FROM ip_hop_audit WHERE created_at < %s
                ''', (now - audit_retention_seconds,)).rowcount
            alert_cutoff = now - (audit_retention_seconds
                                  if audit_retention_seconds is not None
                                  else retention_seconds)
            alerts = connection.execute('''
                DELETE FROM ip_hop_alerts WHERE created_at < %s
            ''', (alert_cutoff,)).rowcount
            return {'observations': observations + bounded, 'blocks': blocks,
                    'overrides': overrides, 'audit': audit, 'alerts': alerts}

        return self._run(operation)


def _schema_statements(sql_text: str) -> list[str]:
    """Split a DDL file into statements, ignoring ``--`` comment lines."""
    lines = [line for line in sql_text.splitlines()
             if not line.lstrip().startswith('--')]
    return [statement.strip() for statement in '\n'.join(lines).split(';')
            if statement.strip()]


class IpHopGuard:
    def __init__(self, store: LocationStore, *, resolver: GeoResolver | None = None,
                 email_hook=None, max_travel_kmh: float = MAX_TRAVEL_KMH,
                 hop_window_seconds: float = HOP_WINDOW_SECONDS,
                 country_burst_limit: int = COUNTRY_BURST_LIMIT,
                 country_window_seconds: float = COUNTRY_WINDOW_SECONDS,
                 retention_seconds: float = RETENTION_SECONDS,
                 max_observations_per_account: int = MAX_OBSERVATIONS_PER_ACCOUNT,
                 block_seconds: float = BLOCK_SECONDS,
                 override_seconds: float = OVERRIDE_SECONDS,
                 audit_retention_seconds: float = AUDIT_RETENTION_SECONDS,
                 min_distance_km: float = MIN_DISTANCE_KM,
                 prune_interval_seconds: float = 60.0,
                 fail_closed: bool = False,
                 clock=time.time):
        if max_travel_kmh <= 0 or hop_window_seconds <= 0:
            raise ValueError('Invalid hop thresholds')
        if country_burst_limit < 1 or country_window_seconds <= 0:
            raise ValueError('Invalid country burst policy')
        if retention_seconds < 0 or max_observations_per_account < 1:
            raise ValueError('Invalid retention policy')
        if not isinstance(fail_closed, bool):
            raise ValueError('fail_closed must be a boolean')
        self.store = store
        self.resolver = resolver
        self.email_hook = email_hook
        self.max_travel_kmh = max_travel_kmh
        self.hop_window_seconds = hop_window_seconds
        self.country_burst_limit = country_burst_limit
        self.country_window_seconds = country_window_seconds
        self.retention_seconds = retention_seconds
        self.max_observations_per_account = max_observations_per_account
        self.block_seconds = block_seconds
        self.override_seconds = override_seconds
        self.audit_retention_seconds = audit_retention_seconds
        self.min_distance_km = min_distance_km
        self.prune_interval_seconds = prune_interval_seconds
        self.fail_closed = fail_closed
        self.clock = clock
        self._prune_lock = threading.Lock()
        self._last_prune = float('-inf')

    def observe(self, uid: str, session_id: str, ip: str, *,
                headers: Any = None, now: float | None = None) -> Decision:
        if not isinstance(uid, str) or UID_RE.fullmatch(uid) is None:
            raise ValueError('Invalid account identity')
        if not isinstance(session_id, str) or SESSION_ID_RE.fullmatch(session_id) is None:
            raise ValueError('Invalid session identity')
        now = self.clock() if now is None else float(now)
        try:
            return self._observe(uid, session_id, ip, headers=headers, now=now)
        except IpHopBlocked:
            raise
        except Exception as error:
            # Fail-open (default): an unavailable guard must not break
            # authentication. Fail-closed: reject because the request could not
            # be evaluated.
            if self.fail_closed:
                raise IpHopUnavailable() from error
            return Decision(recorded=False, reason='guard_unavailable')

    def _observe(self, uid: str, session_id: str, ip: str, *,
                 headers: Any = None, now: float) -> Decision:
        # Enforce an existing block even when the request has no usable IP.
        existing = self.store.blocked(uid, session_id, now)
        if existing is not None:
            raise IpHopBlocked(session_id, existing.get('event_id'))

        try:
            prefix = coarse_prefix(ip)
        except ValueError:
            if self.fail_closed:
                raise IpHopUnavailable() from None
            return Decision(recorded=False, reason='invalid_address')

        geo = self._resolve(ip, headers)
        current = Observation(uid=uid, session_id=session_id, ip_prefix=prefix,
                              seen_at=now, country=geo.country if geo else None,
                              asn=geo.asn if geo else None,
                              city=geo.city if geo else None,
                              latitude=geo.latitude if geo else None,
                              longitude=geo.longitude if geo else None)
        self._maybe_prune(now)
        active_blocks = getattr(self.store, 'active_blocks', None)
        blocked_sessions = ({item['session_id'] for item in active_blocks(uid, now)}
                            if active_blocks else set())
        recent = [item for item in self.store.recent(uid, now - self.hop_window_seconds)
                  if item.session_id not in blocked_sessions]
        current = _with_id(current, self.store.record(current))

        if self.store.override_active(uid, session_id, now):
            return Decision(recorded=True, reason='admin_override')

        reason, evidence = self._detect(current, recent)
        if reason is None:
            return Decision(recorded=True)
        return self._flag(uid, current, recent, reason, evidence, now)

    def prune(self, now: float | None = None) -> dict:
        now = self.clock() if now is None else float(now)
        return self.store.prune(
            now, retention_seconds=self.retention_seconds,
            max_per_account=self.max_observations_per_account,
            audit_retention_seconds=self.audit_retention_seconds)

    def admin_unblock(self, uid: str, session_id: str | None, *, actor: str,
                      reason: str, now: float | None = None,
                      override_seconds: float | None = None) -> int:
        if not isinstance(uid, str) or UID_RE.fullmatch(uid) is None:
            raise ValueError('Invalid account identity')
        if session_id is not None and (
                not isinstance(session_id, str) or
                SESSION_ID_RE.fullmatch(session_id) is None):
            raise ValueError('Invalid session identity')
        if not isinstance(actor, str) or not actor.strip() or len(actor) > 128:
            raise ValueError('Invalid admin actor')
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 500:
            raise ValueError('Invalid unblock reason')
        now = self.clock() if now is None else float(now)
        sessions = self.store.unblock(uid, session_id, now)
        until = now + (self.override_seconds if override_seconds is None
                       else float(override_seconds))
        for blocked_session in sessions:
            self.store.set_override(uid, blocked_session, until, actor, reason, now)
        event_id = f'{uid}:{int(now)}:unblock:{session_id or "all"}'
        self.store.audit(event_id=event_id, uid=uid, action='unblock',
                         reason=reason, actor=actor, session_id=session_id,
                         created_at=now)
        return len(sessions)

    def unblock(self, uid: str, session_id: str | None = None, *, actor: str,
                reason: str, now: float | None = None,
                override_seconds: float | None = None) -> int:
        """Alias for administrative override/unblock callers."""
        return self.admin_unblock(uid, session_id, actor=actor, reason=reason,
                                  now=now, override_seconds=override_seconds)

    def _resolve(self, ip: str, headers: Any) -> GeoInfo | None:
        if self.resolver is None:
            return None
        try:
            return _normalize_geo(self.resolver.resolve(ip, headers))
        except Exception:
            # A location lookup failure must not take down authentication.
            return None

    def _detect(self, current: Observation, recent: list[Observation]):
        for other in sorted(recent, key=lambda item: (item.seen_at, item.id or 0),
                            reverse=True):
            if _same_place(current, other):
                continue
            elapsed = current.seen_at - other.seen_at
            if elapsed <= 0 or elapsed > self.hop_window_seconds:
                continue
            distance = _distance_km(current, other)
            if distance is None or distance < self.min_distance_km:
                continue
            speed = distance / (elapsed / 3600.0)
            if speed > self.max_travel_kmh:
                return 'impossible_travel', {
                    'other': other, 'distance_km': distance,
                    'speed_kmh': speed, 'elapsed_seconds': elapsed,
                }

        window = [item for item in recent
                  if current.seen_at - item.seen_at <= self.country_window_seconds]
        countries = {item.country for item in window if item.country}
        if current.country:
            countries.add(current.country)
        if len(countries) > self.country_burst_limit:
            return 'country_burst', {'countries': sorted(countries)}
        return None, None

    def _flag(self, uid: str, current: Observation, recent: list[Observation],
              reason: str, evidence: dict, now: float) -> Decision:
        first_seen = {}
        for item in [*recent, current]:
            first_seen[item.session_id] = min(
                first_seen.get(item.session_id, item.seen_at), item.seen_at)
        newest_session = max(
            first_seen,
            key=lambda value: (first_seen[value], value == current.session_id, value))
        older_session = min((value for value in first_seen if value != newest_session),
                            key=lambda value: first_seen[value], default=None)
        bucket = int(now // self.hop_window_seconds)
        event_id = f'{uid}:{bucket}:{reason}:{newest_session}'
        alert_key = f'{uid}:{bucket}'

        self.store.block(uid, newest_session, reason, event_id, now,
                         now + self.block_seconds)
        other = evidence.get('other')
        self.store.audit(
            event_id=event_id, uid=uid, action='block', reason=reason,
            session_id=newest_session, older_session_id=older_session,
            ip_prefix=current.ip_prefix,
            older_ip_prefix=other.ip_prefix if other else None,
            country=current.country, older_country=other.country if other else None,
            asn=current.asn, older_asn=other.asn if other else None,
            created_at=now)

        alerted = False
        if self.store.claim_alert(alert_key, uid, now):
            alerted = True
            event = self._alert_event(uid, current, other, reason, event_id,
                                      alert_key, newest_session, older_session,
                                      evidence, now)
            if self.email_hook is None:
                self.store.mark_alert(alert_key, 'not_configured')
            else:
                try:
                    self._enqueue_email(event)
                    self.store.mark_alert(alert_key, 'sent')
                except Exception:
                    # Authentication must not depend on the email transport.
                    # The claimed row remains for operator inspection/retry.
                    self.store.mark_alert(alert_key, 'failed')

        if newest_session == current.session_id:
            raise IpHopBlocked(newest_session, event_id)
        return Decision(recorded=True, reason=reason,
                        blocked_session_id=newest_session,
                        older_session_id=older_session, event_id=event_id,
                        alerted=alerted)

    def _enqueue_email(self, event: dict) -> None:
        hook = self.email_hook
        if callable(hook):
            hook(event)
            return
        enqueue = getattr(hook, 'enqueue', None) or getattr(hook, 'send', None)
        if not callable(enqueue):
            raise TypeError('Email hook must be callable or expose enqueue/send')
        enqueue(event)

    def _alert_event(self, uid: str, current: Observation, other: Observation | None,
                     reason: str, event_id: str, alert_key: str,
                     blocked_session: str, older_session: str | None,
                     evidence: dict, now: float) -> dict:
        # Deliberately no Authorization header, token, or raw IP address.
        # Session identifiers are hashed so even a caller that mistakenly uses
        # a token as its session id cannot leak it through the email hook.
        return {
            'type': 'ip_hop_block',
            'event_id': event_id,
            'alert_key': alert_key,
            'uid': uid,
            'reason': reason,
            'at': int(now),
            'blocked_session_ref': _session_ref(blocked_session),
            'older_session_ref': _session_ref(older_session) if older_session else None,
            'location': _location(current),
            'previous_location': _location(other) if other else None,
            'distance_km': (round(evidence['distance_km'], 1)
                            if 'distance_km' in evidence else None),
            'speed_kmh': (round(evidence['speed_kmh'], 1)
                          if 'speed_kmh' in evidence else None),
            'elapsed_seconds': evidence.get('elapsed_seconds'),
            'distinct_countries': evidence.get('countries'),
        }

    def _maybe_prune(self, now: float) -> None:
        with self._prune_lock:
            if now - self._last_prune < self.prune_interval_seconds:
                return
            self._last_prune = now
        prune = getattr(self.store, 'prune', None)
        if prune is not None:
            try:
                self.prune(now)
            except Exception:
                # Housekeeping must never break authentication.
                pass


def coarse_prefix(ip: str) -> str:
    """Return IPv4 /24 or IPv6 /48 for an address; reject invalid input."""
    if not isinstance(ip, str) or not ip.strip():
        raise ValueError('Invalid address')
    address = ipaddress.ip_address(ip.strip())
    if address.version == 6 and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    bits = 24 if address.version == 4 else 48
    return str(ipaddress.ip_network(f'{address}/{bits}', strict=False))


def session_from_token(token: str) -> str:
    """Opaque session identity derived from a bearer token (never the token)."""
    if not isinstance(token, str) or not token:
        raise ValueError('Invalid token')
    return 'tok_' + hashlib.sha256(token.encode('utf-8')).hexdigest()[:24]


def bearer_token(headers: Any) -> str:
    value = _header(headers, 'authorization') or ''
    if value[:7].lower() != 'bearer ':
        return ''
    return value[7:].strip()


def client_ip(headers: Any) -> str:
    # Cloudflare's connecting IP is authoritative at that edge. Fall back to
    # X-Forwarded-For only for deployments that explicitly terminate there.
    return (_header(headers, 'cf-connecting-ip') or
            _header(headers, 'x-real-ip') or
            ((_header(headers, 'x-forwarded-for') or '').split(',')[0].strip()))


def request_context(request: Any):
    """Extract (ip, opaque session id, headers) from a Starlette-like request."""
    headers = getattr(request, 'headers', None)
    if headers is None and isinstance(request, Mapping):
        headers = request
    if headers is None:
        headers = {}
    ip = client_ip(headers)
    session_id = _header(headers, 'x-session-id') or ''
    if SESSION_ID_RE.fullmatch(session_id) is None:
        token = bearer_token(headers)
        session_id = session_from_token(token) if token else ''
    if not session_id:
        session_id = 'sess_' + hashlib.sha256(
            (ip or 'unknown').encode('utf-8')).hexdigest()[:16]
    return ip, session_id, headers


def set_request_context(value: tuple[str, str, Any]):
    return _REQUEST_CONTEXT.set(value)


def reset_request_context(token) -> None:
    _REQUEST_CONTEXT.reset(token)


def current_request_context():
    return _REQUEST_CONTEXT.get()


def _header(headers: Any, name: str) -> str | None:
    if headers is None:
        return None
    try:
        items = headers.items()
    except AttributeError:
        return None
    for key, value in items:
        if isinstance(key, str) and key.lower() == name:
            if isinstance(value, str):
                return value.strip()
            return None
    return None


def _to_float(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _normalize_geo(geo: GeoInfo | Mapping | None) -> GeoInfo | None:
    if geo is None:
        return None
    if isinstance(geo, Mapping):
        geo = GeoInfo(country=geo.get('country'), asn=geo.get('asn'),
                      city=geo.get('city'), latitude=geo.get('latitude'),
                      longitude=geo.get('longitude'))
    country = geo.country.strip().upper() if isinstance(geo.country, str) else None
    if country in ('', 'XX') or (country and COUNTRY_RE.fullmatch(country) is None):
        country = None
    asn = geo.asn.strip().upper() if isinstance(geo.asn, str) else None
    if asn:
        if not asn.startswith('AS'):
            asn = 'AS' + asn
        if ASN_RE.fullmatch(asn) is None:
            asn = None
    city = geo.city.strip()[:64] if isinstance(geo.city, str) and geo.city.strip() else None
    latitude = _to_float(geo.latitude) if not isinstance(geo.latitude, bool) else None
    longitude = _to_float(geo.longitude) if not isinstance(geo.longitude, bool) else None
    if (latitude is None or longitude is None or
            not -90 <= latitude <= 90 or not -180 <= longitude <= 180):
        latitude = longitude = None
    if country is None and asn is None and city is None and latitude is None:
        return None
    return GeoInfo(country, asn, city, latitude, longitude)


def _observation(row: Mapping) -> Observation:
    return Observation(uid=row['uid'], session_id=row['session_id'],
                       ip_prefix=row['ip_prefix'], seen_at=row['seen_at'],
                       country=row['country'], asn=row['asn'], city=row['city'],
                       latitude=row['latitude'], longitude=row['longitude'],
                       id=row['id'])


def _with_id(observation: Observation, identifier: int) -> Observation:
    return Observation(uid=observation.uid, session_id=observation.session_id,
                       ip_prefix=observation.ip_prefix, seen_at=observation.seen_at,
                       country=observation.country, asn=observation.asn,
                       city=observation.city, latitude=observation.latitude,
                       longitude=observation.longitude, id=identifier)


def _same_place(first: Observation, second: Observation) -> bool:
    if first.ip_prefix == second.ip_prefix:
        return True
    if first.asn and second.asn and first.asn == second.asn:
        return True
    if (first.country and second.country and first.country == second.country and
            first.city and second.city and
            first.city.casefold() == second.city.casefold()):
        return True
    return False


def _distance_km(first: Observation, second: Observation) -> float | None:
    if (first.latitude is None or first.longitude is None or
            second.latitude is None or second.longitude is None):
        return None
    return _haversine_km(first.latitude, first.longitude,
                         second.latitude, second.longitude)


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371.0088
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = (math.sin(dphi / 2) ** 2 +
         math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2)
    return 2 * radius * math.asin(min(1.0, math.sqrt(a)))


def _location(observation: Observation | None) -> dict | None:
    if observation is None:
        return None
    return {'ip_prefix': observation.ip_prefix, 'country': observation.country,
            'asn': observation.asn, 'city': observation.city}


def _session_ref(session_id: str) -> str:
    return hashlib.sha256(session_id.encode('utf-8')).hexdigest()[:16]
