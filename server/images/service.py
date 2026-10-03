"""Private image routing and durable, decimal-exact metering.

No provider key, identifier, response error, or upstream price crosses the
public boundary. An interrupted job stays pending for operator reconciliation;
it is never automatically re-submitted after a process restart.
"""
import base64
import hashlib
import io
import json
import re
import sqlite3
import warnings
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

from PIL import Image

ALIAS = 'ovid-image'
MULTIPLIER = Decimal('0.30')
MAX_BYTES = 16 * 1024 * 1024
MAX_PIXELS = 4096 * 4096
SIZES = ('1024x1024', '1536x1024', '1024x1536', '2048x2048')


class ImageError(Exception):
    def __init__(self, status=503, code='image_unavailable'):
        self.status, self.code = status, code
        super().__init__(code)


class UpstreamError(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__('upstream request failed')


def money(value):
    try:
        result = Decimal(str(value))
        if not result.is_finite() or result < 0:
            raise ValueError()
        return result
    except (ValueError, InvalidOperation):
        raise ImageError(502, 'invalid_image_response') from None


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
    def __init__(self, path):
        self.path = str(path)
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('''CREATE TABLE IF NOT EXISTS image_jobs (
                account TEXT NOT NULL, request TEXT NOT NULL, fingerprint TEXT NOT NULL,
                state TEXT NOT NULL, reserved TEXT NOT NULL, charged TEXT NOT NULL DEFAULT '0',
                actual TEXT, response TEXT, budget_window TEXT NOT NULL,
                PRIMARY KEY(account, request))''')

    def connect(self):
        return sqlite3.connect(self.path, timeout=30)

    def spent(self, account, include_pending=False, budget_window=None):
        with self.connect() as db:
            rows = db.execute('SELECT state,reserved,charged FROM image_jobs WHERE account=? AND (? IS NULL OR budget_window=?)',
                              (account, budget_window, budget_window)).fetchall()
        return sum((Decimal(r if include_pending and s == 'pending' else c) for s, r, c in rows), Decimal(0))

    def begin(self, account, request, fingerprint, reservation, budget, budget_window):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT fingerprint,state,response FROM image_jobs WHERE account=? AND request=?', (account, request)).fetchone()
            if row:
                if row[0] != fingerprint:
                    raise ImageError(409, 'idempotency_conflict')
                if row[1] == 'done':
                    return json.loads(row[2])
                raise ImageError(409, 'image_request_pending' if row[1] == 'pending' else 'image_request_failed')
            rows = db.execute("SELECT state,reserved,charged FROM image_jobs WHERE account=? AND (budget_window=? OR state='pending')", (account, budget_window)).fetchall()
            spent = sum((Decimal(r if s == 'pending' else c) for s, r, c in rows), Decimal(0))
            if spent + reservation > money(budget):
                raise ImageError(402, 'image_limit_reached')
            db.execute('INSERT INTO image_jobs(account,request,fingerprint,state,reserved,budget_window) VALUES(?,?,?,?,?,?)',
                       (account, request, fingerprint, 'pending', str(reservation), budget_window))
        return None

    def settle(self, account, request, actual, response):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute("UPDATE image_jobs SET state='done', actual=?, charged=?, response=? WHERE account=? AND request=? AND state='pending'",
                       (str(actual), str(actual * MULTIPLIER), json.dumps(response), account, request))

    def fail(self, account, request):
        with self.connect() as db:
            db.execute("UPDATE image_jobs SET state='failed', reserved='0' WHERE account=? AND request=? AND state='pending'", (account, request))


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
        replay = self.ledger.begin(account, request, fingerprint, self.max_upstream_cost * MULTIPLIER, budget, budget_window)
        if replay is not None:
            return replay
        for backend in candidates:
            payload = {**body, 'model': backend.model, 'size': size, 'n': 1, 'response_format': 'b64_json'}
            try:
                response = self.send(backend, operation, payload)
            except UpstreamError as error:
                # Explicit refusals only. A transport timeout after submission
                # has an unknown outcome and must NOT start another paid job.
                if error.status in (429, 503):
                    continue
                self.ledger.fail(account, request)
                raise ImageError(400 if error.status in (400, 422) else 503, 'image_request_failed') from None
            except Exception:
                raise ImageError(409, 'image_request_pending') from None
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
                raise ImageError(502, 'invalid_image_response') from None
            self.ledger.settle(account, request, actual, result)
            return result
        self.ledger.fail(account, request)
        raise ImageError()
