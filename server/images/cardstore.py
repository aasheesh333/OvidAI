"""SQLite persistence for capability cards, history and probe accounting.

Same style as the ledger: its own WAL file next to it, one connection per call.
"""
import json
import sqlite3
import time
from contextlib import contextmanager


class CardStore:
    def __init__(self, path, *, clock=time.time):
        self.path, self.clock = str(path), clock
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('''CREATE TABLE IF NOT EXISTS image_cards (
                model TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, state TEXT NOT NULL,
                card TEXT NOT NULL, updated_at INTEGER NOT NULL, probed_at INTEGER)''')
            db.execute('''CREATE TABLE IF NOT EXISTS image_card_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, fingerprint TEXT NOT NULL,
                state TEXT NOT NULL, card TEXT NOT NULL, at INTEGER NOT NULL)''')
            db.execute('''CREATE TABLE IF NOT EXISTS image_probe_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, probe TEXT NOT NULL,
                ok INTEGER NOT NULL, error_class TEXT, latency_ms INTEGER, cost_usd REAL NOT NULL DEFAULT 0,
                at INTEGER NOT NULL)''')
            db.execute('''CREATE TABLE IF NOT EXISTS image_probe_state (
                model TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT)''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def get(self, model):
        with self.connect() as db:
            row = db.execute('SELECT card FROM image_cards WHERE model=?', (model,)).fetchone()
        return json.loads(row['card']) if row else None

    def all(self):
        with self.connect() as db:
            rows = db.execute('SELECT card FROM image_cards ORDER BY model').fetchall()
        return [json.loads(r['card']) for r in rows]

    def put(self, card):
        now = int(self.clock())
        blob = json.dumps(card, sort_keys=True)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('''INSERT INTO image_cards(model,fingerprint,state,card,updated_at,probed_at)
                VALUES(?,?,?,?,?,?) ON CONFLICT(model) DO UPDATE SET fingerprint=excluded.fingerprint,
                state=excluded.state, card=excluded.card, updated_at=excluded.updated_at,
                probed_at=excluded.probed_at''',
                       (card['model'], card['fingerprint'], card['state'], blob, now, card.get('probed_at')))
            db.execute('INSERT INTO image_card_history(model,fingerprint,state,card,at) VALUES(?,?,?,?,?)',
                       (card['model'], card['fingerprint'], card['state'], blob, now))

    def history(self, model, limit=20):
        with self.connect() as db:
            rows = db.execute('SELECT fingerprint,state,at FROM image_card_history WHERE model=? ORDER BY id DESC LIMIT ?',
                              (model, limit)).fetchall()
        return [dict(r) for r in rows]

    def log_probe(self, model, probe, ok, error_class, latency_ms, cost_usd):
        with self.connect() as db:
            db.execute('INSERT INTO image_probe_log(model,probe,ok,error_class,latency_ms,cost_usd,at) VALUES(?,?,?,?,?,?,?)',
                       (model, probe, int(bool(ok)), error_class, latency_ms, float(cost_usd or 0), int(self.clock())))

    def spent_since(self, since):
        with self.connect() as db:
            row = db.execute('SELECT COALESCE(SUM(cost_usd),0) AS s FROM image_probe_log WHERE at>=?', (int(since),)).fetchone()
        return float(row['s'])

    def probe_state(self, model):
        with self.connect() as db:
            row = db.execute('SELECT * FROM image_probe_state WHERE model=?', (model,)).fetchone()
        return dict(row) if row else {'model': model, 'attempts': 0, 'next_attempt_at': 0, 'last_error': None}

    def set_probe_state(self, model, attempts, next_attempt_at, last_error=None):
        with self.connect() as db:
            db.execute('''INSERT INTO image_probe_state(model,attempts,next_attempt_at,last_error) VALUES(?,?,?,?)
                ON CONFLICT(model) DO UPDATE SET attempts=excluded.attempts,
                next_attempt_at=excluded.next_attempt_at, last_error=excluded.last_error''',
                       (model, attempts, int(next_attempt_at), last_error))
