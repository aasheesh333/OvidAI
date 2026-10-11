"""Durable purchase-token ledger (SQLite) and tier sinks.

One row per Play purchase token. A token is bound to exactly one Firebase UID
the first time it is verified; replaying it from another account is refused.
All writes are upserts keyed by token, so repeated ``/billing/verify`` calls and
Pub/Sub redeliveries are idempotent.
"""
import sqlite3
import threading
from contextlib import contextmanager

from .domain import BillingError
from .products import TIER_RANK

# Terminal local states that a later Play read must not undo.
STICKY = frozenset({'revoked', 'replaced'})

SCHEMA = """
CREATE TABLE IF NOT EXISTS play_purchases (
  token TEXT PRIMARY KEY,
  uid TEXT,
  product_id TEXT NOT NULL,
  tier TEXT NOT NULL,
  status TEXT NOT NULL,
  expires_at INTEGER,
  auto_renewing INTEGER NOT NULL DEFAULT 0,
  linked_token TEXT,
  account_hash TEXT,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS play_purchases_uid ON play_purchases(uid);
"""


class PurchaseStore:
    def __init__(self, path):
        self._path = path
        self._lock = threading.Lock()
        self._memory = None
        if path == ':memory:':
            self._memory = self._connect()
        db = self._memory or self._connect()
        try:
            db.executescript(SCHEMA)
        finally:
            if self._memory is None:
                db.close()

    def _connect(self):
        # Autocommit mode: transactions are explicit (BEGIN IMMEDIATE) below.
        return sqlite3.connect(self._path, timeout=30, isolation_level=None,
                               check_same_thread=False)

    @contextmanager
    def _db(self):
        with self._lock:
            db = self._memory or self._connect()
            try:
                db.execute('BEGIN IMMEDIATE')
                yield db
                db.execute('COMMIT')
            except BaseException:
                db.execute('ROLLBACK')
                raise
            finally:
                if self._memory is None:
                    db.close()

    @staticmethod
    def _row(row):
        if row is None:
            return None
        keys = ('token', 'uid', 'product_id', 'tier', 'status', 'expires_at',
                'auto_renewing', 'linked_token', 'account_hash', 'updated_at')
        out = dict(zip(keys, row))
        out['auto_renewing'] = bool(out['auto_renewing'])
        return out

    def get(self, token):
        with self._db() as db:
            return self._row(db.execute(
                'SELECT * FROM play_purchases WHERE token=?', (token,)).fetchone())

    def record(self, token, entitlement, now, uid=None):
        """Upsert ``token`` with a fresh Play evaluation. Returns the row.

        ``uid`` binds an unbound token; a different existing owner raises 409.
        Sticky local states (revoked/replaced) are never overwritten.
        """
        with self._db() as db:
            existing = self._row(db.execute(
                'SELECT * FROM play_purchases WHERE token=?', (token,)).fetchone())
            owner = existing['uid'] if existing else None
            if uid is not None and owner is not None and owner != uid:
                raise BillingError(409, 'purchase_owned_by_another_account')
            owner = owner or uid
            status = entitlement.status
            tier = entitlement.tier
            if existing and existing['status'] in STICKY:
                status, tier = existing['status'], 'free'
            db.execute(
                'INSERT INTO play_purchases(token,uid,product_id,tier,status,expires_at,'
                'auto_renewing,linked_token,account_hash,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?) '
                'ON CONFLICT(token) DO UPDATE SET uid=excluded.uid, product_id=excluded.product_id, '
                'tier=excluded.tier, status=excluded.status, expires_at=excluded.expires_at, '
                'auto_renewing=excluded.auto_renewing, linked_token=excluded.linked_token, '
                'account_hash=excluded.account_hash, updated_at=excluded.updated_at',
                (token, owner, entitlement.product_id, tier, status, entitlement.expires_at,
                 int(entitlement.auto_renewing), entitlement.linked_token,
                 entitlement.account_hash, now))
            if entitlement.linked_token and entitlement.linked_token != token:
                # Upgrade/downgrade/resubscribe: the old token no longer grants.
                db.execute("UPDATE play_purchases SET status='replaced', tier='free', "
                           "auto_renewing=0, updated_at=? WHERE token=?",
                           (now, entitlement.linked_token))
            return self._row(db.execute(
                'SELECT * FROM play_purchases WHERE token=?', (token,)).fetchone())

    def mark(self, token, status, now):
        if status not in STICKY:
            raise ValueError(status)
        with self._db() as db:
            db.execute('UPDATE play_purchases SET status=?, tier=\'free\', auto_renewing=0, '
                       'updated_at=? WHERE token=?', (status, now, token))
            return self._row(db.execute(
                'SELECT * FROM play_purchases WHERE token=?', (token,)).fetchone())

    def effective(self, uid, now):
        """Best currently-active purchase for ``uid`` (or None => free)."""
        with self._db() as db:
            rows = [self._row(r) for r in db.execute(
                "SELECT * FROM play_purchases WHERE uid=? AND status='active' "
                'AND expires_at > ?', (uid, now)).fetchall()]
        if not rows:
            return None
        rows.sort(key=lambda r: (TIER_RANK.get(r['tier'], 0), r['expires_at'] or 0), reverse=True)
        return rows[0]


class RedisTierSink:
    """Writes the tier mint already reads (``user:{uid}:tier``).

    The paid tier key expires on its own at the subscription expiry (plus a
    small clock-skew slack), so a missed RTDN can never leave a user on a paid
    tier forever. ``user:{uid}:tier_expires_at`` lets mint's ``/usage`` show
    "Renews on / Ends on". On downgrade to free both keys are deleted, which
    mint's ``effective_tier`` must treat as ``free`` (its existing default).
    """
    SKEW_SECONDS = 600

    def __init__(self, rds):
        self.rds = rds

    def __call__(self, uid, tier, expires_at):
        key = f'user:{uid}:tier'
        if tier == 'free' or tier not in TIER_RANK:
            self.rds.delete(key, f'user:{uid}:tier_expires_at')
            return
        at = int(expires_at) + self.SKEW_SECONDS
        self.rds.set(key, tier, exat=at)
        self.rds.set(f'user:{uid}:tier_expires_at', int(expires_at), exat=at)
