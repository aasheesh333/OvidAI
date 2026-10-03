"""Private image routing and durable, decimal-exact metering.

No provider key, identifier, response error, or upstream price crosses the
public boundary. An interrupted job stays pending for operator reconciliation;
it is never automatically re-submitted after a process restart.
"""
import base64
import hashlib
import io
import json
import math
import re
import sqlite3
import time
import warnings
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, localcontext

from PIL import Image

ALIAS = 'ovid-image'
MULTIPLIER = Decimal('0.30')
MAX_BYTES = 16 * 1024 * 1024
MAX_PIXELS = 4096 * 4096
REPLAY_RETENTION = 24 * 60 * 60
RECEIPT_RETENTION = 90 * 24 * 60 * 60
SIZES = ('1024x1024', '1536x1024', '1024x1536', '2048x2048')


class ImageError(Exception):
    def __init__(self, status=503, code='image_unavailable', *, receipt=None):
        self.status, self.code = status, code
        self.receipt = receipt
        super().__init__(code)


class UpstreamError(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__('upstream request failed')


class UpstreamNotAccepted(UpstreamError):
    """Adapter-verified nonacceptance, not an inference from HTTP status.

    Emit only with authoritative evidence that this attempt was not accepted
    for execution/billing (for example, a verified pre-submission rejection).
    No currently wired InferHub response supplies such evidence.
    """


def money(value):
    try:
        if isinstance(value, (float, bool)) or not isinstance(value, (str, int, Decimal)):
            raise ValueError()
        result = Decimal(str(value))
        if not result.is_finite() or result < 0:
            raise ValueError()
        # Bound untrusted exponents/precision before exact arithmetic or storage.
        if len(result.as_tuple().digits) > 128 or not -128 <= result.as_tuple().exponent <= 128 or result.adjusted() > 128:
            raise ValueError()
        return result
    except (ValueError, InvalidOperation):
        raise ImageError(502, 'invalid_image_response') from None


def discounted(value):
    value = money(value)
    with localcontext() as context:
        context.prec = len(value.as_tuple().digits) + 2
        return value * MULTIPLIER


def exact_sum(values):
    values = list(values)
    if not values:
        return Decimal(0)
    with localcontext() as context:
        context.prec = max(v.adjusted() for v in values) - min(v.as_tuple().exponent for v in values) + len(str(len(values))) + 2
        return sum(values, Decimal(0))


def validate_image(encoded, mime=None):
    try:
        if not isinstance(encoded, str) or len(encoded) > (MAX_BYTES + 2) // 3 * 4:
            raise ValueError()
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) > MAX_BYTES:
            raise ValueError()
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(raw)) as im:
                if im.format not in ('PNG', 'JPEG', 'WEBP') or getattr(im, 'n_frames', 1) != 1:
                    raise ValueError()
                if not 0 < im.width <= 4096 or not 0 < im.height <= 4096 or im.width * im.height > MAX_PIXELS:
                    raise ValueError()
                actual = Image.MIME[im.format]
                if mime and actual != mime:
                    raise ValueError()
                im.verify()
            with Image.open(io.BytesIO(raw)) as im:
                im.load()  # Header sniffing alone accepts truncated images.
        return actual
    except Exception:
        raise ImageError(400, 'invalid_image') from None


@dataclass(frozen=True)
class Backend:
    model: str
    sizes: tuple[str, ...]
    edit: bool


class Ledger:
    """One shared SQLite database on the verifier host, never per worker.

    Account is a stable verified UID; idempotency survives budget-window resets.
    Reservations persist until settled/reconciled. Never expire a pending job.
    """
    def __init__(self, path, *, clock=time.time, replay_retention=REPLAY_RETENTION,
                 receipt_retention=RECEIPT_RETENTION):
        self.path = str(path)
        durations = (replay_retention, receipt_retention)
        if (any(isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) for value in durations)
                or not 0 < replay_retention <= receipt_retention):
            raise ValueError('Invalid image retention policy')
        self.clock = clock
        self.replay_retention = replay_retention
        self.receipt_retention = receipt_retention
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('BEGIN IMMEDIATE')
            db.execute('''CREATE TABLE IF NOT EXISTS image_jobs (
                account TEXT NOT NULL, request TEXT NOT NULL, fingerprint TEXT NOT NULL,
                state TEXT NOT NULL, reserved TEXT NOT NULL, charged TEXT NOT NULL DEFAULT '0',
                actual TEXT, response TEXT, budget_window TEXT NOT NULL,
                PRIMARY KEY(account, request))''')
            columns = {row[1] for row in db.execute('PRAGMA table_info(image_jobs)')}
            if 'replay_until' not in columns:
                db.execute('ALTER TABLE image_jobs ADD COLUMN replay_until INTEGER')
                db.execute('ALTER TABLE image_jobs ADD COLUMN receipt_until INTEGER')
                # Legacy blobs have no creation time: do not grant a new replay
                # lease on every upgrade/restart. Preserve exact paid receipts.
                db.execute("UPDATE image_jobs SET response=NULL, replay_until=0, receipt_until=? WHERE state IN ('done','failed')",
                           (int(self.clock()) + receipt_retention,))
            db.execute('''CREATE TABLE IF NOT EXISTS image_deleted_accounts (
                account TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL)''')

    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def _receipt(row):
        return {'account_id': row['account'], 'request_id': row['request'],
                'fingerprint': row['fingerprint'],
                'state': 'confirmed' if row['state'] == 'done' else row['state'],
                'charged': row['charged'] if row['state'] in ('done', 'failed') else None}

    def receipt(self, account, request):
        with self.connect() as db:
            self._require_account(db, account)
            row = db.execute('SELECT * FROM image_jobs WHERE account=? AND request=?', (account, request)).fetchone()
            if row is None:
                raise ImageError(404, 'image_request_not_found')
            if row['receipt_until'] is not None and self.clock() >= row['receipt_until']:
                raise ImageError(410, 'image_receipt_expired')
            return self._receipt(row)

    def _response(self, row):
        if row['response'] is None or row['replay_until'] is None or self.clock() >= row['replay_until']:
            receipt = self._receipt(row) if row['receipt_until'] is None or self.clock() < row['receipt_until'] else None
            raise ImageError(410, 'image_replay_expired', receipt=receipt)
        return {**json.loads(row['response']), 'receipt': self._receipt(row)}

    @staticmethod
    def _deleted(db, account):
        return db.execute('SELECT 1 FROM image_deleted_accounts WHERE account=?', (account,)).fetchone() is not None

    def _require_account(self, db, account):
        if self._deleted(db, account):
            raise ImageError(410, 'image_account_deleted')

    def purge_expired(self):
        """Scheduled local cleanup; never removes dedup or unresolved charges."""
        now = int(self.clock())
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('UPDATE image_jobs SET response=NULL WHERE replay_until<=?', (now,))
            db.execute('UPDATE image_jobs SET actual=NULL WHERE receipt_until<=?', (now,))

    def delete_account(self, account):
        """Idempotent local deletion adapter; caller supplies verified stable UID.

        Retain minimal billing/dedup tombstones, including unresolved reserves.
        Settlement may still account for already-paid work, never republish it.
        """
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('INSERT OR IGNORE INTO image_deleted_accounts VALUES (?,?)', (account, int(self.clock())))
            db.execute('UPDATE image_jobs SET response=NULL, actual=NULL, replay_until=0, receipt_until=0 WHERE account=?', (account,))

    def spent(self, account, include_pending=False, budget_window=None):
        with self.connect() as db:
            rows = db.execute('SELECT state,reserved,charged FROM image_jobs WHERE account=? AND (? IS NULL OR budget_window=?)',
                              (account, budget_window, budget_window)).fetchall()
        return exact_sum(Decimal(r if include_pending and s in ('pending', 'unknown') else c) for s, r, c in rows)

    def begin(self, account, request, fingerprint, reservation, budget, budget_window):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            self._require_account(db, account)
            row = db.execute('SELECT * FROM image_jobs WHERE account=? AND request=?', (account, request)).fetchone()
            if row:
                if row['fingerprint'] != fingerprint:
                    raise ImageError(409, 'idempotency_conflict')
                if row['state'] == 'done':
                    return self._response(row)
                if row['receipt_until'] is not None and self.clock() >= row['receipt_until']:
                    raise ImageError(410, 'image_receipt_expired')
                raise ImageError(409, 'image_request_pending' if row['state'] in ('pending', 'unknown') else 'image_request_failed', receipt=self._receipt(row))
            rows = db.execute("SELECT state,reserved,charged FROM image_jobs WHERE account=? AND (budget_window=? OR state IN ('pending','unknown'))", (account, budget_window)).fetchall()
            spent = exact_sum(Decimal(r if s in ('pending', 'unknown') else c) for s, r, c in rows)
            if exact_sum((spent, money(reservation))) > money(budget):
                raise ImageError(402, 'image_limit_reached')
            db.execute('INSERT INTO image_jobs(account,request,fingerprint,state,reserved,budget_window) VALUES(?,?,?,?,?,?)',
                       (account, request, fingerprint, 'pending', str(reservation), budget_window))
        return None

    def settle(self, account, request, actual, response):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            deleted = self._deleted(db, account)
            row = db.execute('SELECT * FROM image_jobs WHERE account=? AND request=?', (account, request)).fetchone()
            if row is None:
                raise ImageError(404, 'image_request_not_found')
            if row['state'] == 'done':
                self._require_account(db, account)
                return self._response(row)
            if row['state'] not in ('pending', 'unknown'):
                raise ImageError(409, 'image_request_failed', receipt=self._receipt(row))
            actual = money(actual)
            now = int(self.clock())
            db.execute("UPDATE image_jobs SET state='done', actual=?, charged=?, response=?, replay_until=?, receipt_until=? WHERE account=? AND request=?",
                       (None if deleted else str(actual), str(discounted(actual)),
                        None if deleted else json.dumps(response),
                        0 if deleted else now + self.replay_retention,
                        0 if deleted else now + self.receipt_retention, account, request))
            row = db.execute('SELECT * FROM image_jobs WHERE account=? AND request=?', (account, request)).fetchone()
            result = None if deleted else self._response(row)
        if deleted:
            # Raise after committing the charge for work accepted before deletion.
            raise ImageError(410, 'image_account_deleted')
        return result

    def unknown(self, account, request):
        with self.connect() as db:
            db.execute("UPDATE image_jobs SET state='unknown' WHERE account=? AND request=? AND state='pending'", (account, request))

    def fail(self, account, request):
        with self.connect() as db:
            db.execute("UPDATE image_jobs SET state='failed', reserved='0', receipt_until=? WHERE account=? AND request=? AND state='pending'",
                       (int(self.clock()) + self.receipt_retention, account, request))


class ImageService:
    def __init__(self, backends, ledger, send, max_upstream_cost):
        if not 2 <= len(backends) <= 3 or len({b.model for b in backends}) != len(backends):
            raise ValueError('Configure two or three distinct verified image backends')
        if any(not b.sizes or not set(b.sizes) <= set(SIZES) for b in backends):
            raise ValueError('Unsupported configured sizes')
        self.backends, self.ledger, self.send = backends, ledger, send
        # This is an owner-enforced maximum, NOT a catalog estimate or a price.
        self.max_upstream_cost = money(max_upstream_cost)
        if not self.max_upstream_cost:
            raise ValueError('A positive enforced upstream cost bound is required')

    def catalog(self):
        return {'model': ALIAS, 'operations': {
            op: sorted({size for b in self.backends if op == 'generate' or b.edit for size in b.sizes})
            for op in ('generate', 'edit')}}

    def execute(self, account, request, operation, body, budget, *, budget_window='default'):
        if not isinstance(request, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{8,128}', request):
            raise ImageError(400, 'invalid_request_id')
        if operation not in ('generate', 'edit') or not isinstance(body, dict):
            raise ImageError(400, 'invalid_image_request')
        allowed = {'model', 'prompt', 'size'} | ({'image'} if operation == 'edit' else set())
        if set(body) - allowed or body.get('model') != ALIAS:
            raise ImageError(400, 'invalid_image_request')
        prompt, size = body.get('prompt'), body.get('size', '1024x1024')
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 8000 or not isinstance(size, str) or size not in SIZES:
            raise ImageError(400, 'invalid_image_request')
        if operation == 'edit':
            image = body.get('image')
            match = re.fullmatch(r'data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)', image) if isinstance(image, str) else None
            if not match:
                raise ImageError(400, 'invalid_image')
            validate_image(match[2], match[1])
        candidates = [b for b in self.backends if size in b.sizes and (operation == 'generate' or b.edit)]
        if not candidates:
            raise ImageError(422, 'unsupported_image_operation')
        fingerprint = hashlib.sha256(json.dumps([operation, body], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        replay = self.ledger.begin(account, request, fingerprint, discounted(self.max_upstream_cost), budget, budget_window)
        if replay is not None:
            return replay
        for backend in candidates:
            # A deletion committed during an explicit refusal must fence the
            # next backend too, not just initial admission and late settlement.
            self.ledger.receipt(account, request)
            payload = {**body, 'model': backend.model, 'size': size, 'n': 1, 'response_format': 'b64_json'}
            try:
                response = self.send(backend, operation, payload)
            except UpstreamError as error:
                # Status alone cannot establish that execution/billing did not
                # occur. Only an adapter's verified nonacceptance permits release
                # or fallback; bare 429/503 are unknown too.
                if not isinstance(error, UpstreamNotAccepted):
                    raise self._unknown(account, request, fingerprint) from None
                if error.status in (429, 503):
                    continue
                if error.status not in (400, 401, 403, 404, 422):
                    raise self._unknown(account, request, fingerprint) from None
                self.ledger.fail(account, request)
                raise ImageError(400 if error.status in (400, 422) else 503, 'image_request_failed', receipt=self.ledger.receipt(account, request)) from None
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
            try:
                actual = money(response['usage']['cost'])
                rows = response['data']
                if not isinstance(rows, list) or len(rows) != 1:
                    raise ValueError()
                encoded = rows[0]['b64_json']
                mime = validate_image(encoded)
                result = {'model': ALIAS, 'data': [{'b64_json': encoded, 'mime_type': mime}]}
            except Exception:
                # A successful upstream response may already have been billed.
                # Keep its reservation for reconciliation; never retry it.
                raise self._unknown(account, request, fingerprint) from None
            try:
                return self.ledger.settle(account, request, actual, result)
            except ImageError:
                raise
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
        self.ledger.fail(account, request)
        raise ImageError(receipt=self.ledger.receipt(account, request))

    def _unknown(self, account, request, fingerprint):
        receipt = {'account_id': account, 'request_id': request,
                   'fingerprint': fingerprint, 'state': 'unknown', 'charged': None}
        try:
            self.ledger.unknown(account, request)
            receipt = self.ledger.receipt(account, request)
        except Exception:
            # Even a failed status write cannot undo the durable admission.
            pass
        return ImageError(409, 'image_request_pending', receipt=receipt)
