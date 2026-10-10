"""Explicit schema deployment and OFFLINE SQLite -> PostgreSQL import.

Usage (DSN comes from the named environment variable, never from defaults):
  python -m server.collaboration.migrate --destination-dsn-env COLLAB_DSN schema
  python -m server.collaboration.migrate --destination-dsn-env COLLAB_DSN identity
  python -m server.collaboration.migrate --destination-dsn-env COLLAB_DSN import-sqlite \
    --source-sqlite /absolute/collab.sqlite --confirm-source /absolute/collab.sqlite \
    --confirm-destination collaboration:postgres:<uuid> --offline

Stop ALL source and destination API/cleanup/retention processes first and restart
them after import: constructors cache the signing secret. --offline explicitly
acknowledges this requirement. SQLite's exclusive transaction prevents writers
while reading; PostgreSQL ACCESS EXCLUSIVE locks prevent partial publication.
The destination must be empty except for bootstrap secrets. No merge or overwrite
mode exists. The destination authority identity stays stable. Every source row,
including hashes, secret material, raw envelopes and request-result bytes, is
copied without re-encoding. Unknown layouts are rejected rather than guessed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

from . import events as ev


SOURCE_COLUMNS = {
    'collab_sessions': ('session_id', 'token_hash', 'owner_uid', 'request_id', 'lifecycle',
                        'generation', 'next_sequence', 'created_at', 'closed_at'),
    'collab_memberships': ('session_id', 'uid', 'participant_id', 'role', 'status', 'generation',
                           'revoked_generation', 'joined_order', 'created_at', 'updated_at',
                           'revoked_at', 'cursor_epoch'),
    'collab_invites': ('invite_id', 'session_id', 'code_hash', 'issued_generation', 'max_uses',
                       'uses', 'revoked', 'created_at', 'expires_at'),
    'collab_invite_requests': ('session_id', 'owner_uid', 'request_id', 'invite_id'),
    'collab_events': ('session_id', 'sequence', 'event_id', 'sender_participant_id', 'kind',
                      'envelope', 'fingerprint', 'size', 'created_at'),
    'collab_requests': ('session_id', 'uid', 'operation', 'request_id', 'fingerprint',
                        'membership_epoch', 'result'),
    'collab_rates': ('session_id', 'operation', 'created_at'),
    'deleted_accounts': ('uid',),
    'deleted_sessions': ('session_id', 'token_hash'),
    'collab_secrets': ('name', 'secret'),
}


class MigrationError(ValueError):
    """Only fixed non-sensitive codes are exposed to command-line callers."""


def _configure(db, schema):
    if type(schema) is not str or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', schema):
        raise MigrationError('invalid_schema')
    db.execute(sql.SQL('SET LOCAL search_path TO {}').format(sql.Identifier(schema)))
    db.execute("SET LOCAL lock_timeout = '10s'")


def initialize_schema(*, dsn, schema='public'):
    """DDL is only available through this explicit deployment operation."""
    with psycopg.connect(dsn) as db:
        _configure(db, schema)
        # Serialize explicit deployments; not the lifecycle UID advisory lock.
        db.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s, 734128))', (schema,))
        db.execute(Path(__file__).parents[1].joinpath('account/schema_collaboration.sql').read_text())


def authority_identity(*, dsn, schema='public'):
    with psycopg.connect(dsn) as db:
        _configure(db, schema)
        row = db.execute("SELECT secret FROM collab_secrets WHERE name='authority'").fetchone()
        if row is None:
            raise MigrationError('destination_not_initialized')
        return row[0]


def _source_layout(source):
    tables = {r[0] for r in source.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    relevant = {name for name in tables if name.startswith('collab_') or name in ('deleted_accounts', 'deleted_sessions')}
    if relevant != set(SOURCE_COLUMNS):
        raise MigrationError('unsupported_source_schema')
    for table, expected in SOURCE_COLUMNS.items():
        columns = tuple(r[1] for r in source.execute(f'PRAGMA table_info({table})'))
        if columns != expected:
            raise MigrationError('unsupported_source_schema')


def _validate_import(db):
    """Validate authoritative relationships after copying, before atomic commit."""
    bad = db.execute("""
        SELECT 1 FROM collab_sessions s WHERE
          EXISTS (SELECT 1 FROM deleted_accounts d WHERE d.uid=s.owner_uid) OR
          EXISTS (SELECT 1 FROM deleted_sessions d WHERE d.session_id=s.session_id OR d.token_hash=s.token_hash) OR
          NOT EXISTS (SELECT 1 FROM collab_memberships m WHERE m.session_id=s.session_id
                      AND m.uid=s.owner_uid AND m.role='owner' AND m.status='active') OR
          s.next_sequence <> coalesce((SELECT max(e.sequence)+1 FROM collab_events e
                                      WHERE e.session_id=s.session_id),1) OR
          s.next_sequence-1 <> (SELECT count(*) FROM collab_events e
                               WHERE e.session_id=s.session_id) OR
          (SELECT count(*) FROM collab_memberships m WHERE m.session_id=s.session_id AND m.status='active')>10
        LIMIT 1
    """).fetchone()
    if bad:
        raise MigrationError('invalid_source_data')
    for table in ('collab_memberships', 'collab_invites', 'collab_events'):
        if db.execute(sql.SQL('SELECT 1 FROM {} c WHERE NOT EXISTS '
                              '(SELECT 1 FROM collab_sessions s WHERE s.session_id=c.session_id) LIMIT 1')
                      .format(sql.Identifier(table))).fetchone():
            raise MigrationError('invalid_source_data')
    if db.execute("""SELECT 1 FROM collab_memberships m JOIN collab_sessions s USING(session_id)
        WHERE (m.status='active' AND m.generation<>s.generation) OR
              EXISTS (SELECT 1 FROM deleted_accounts d WHERE d.uid=m.uid) LIMIT 1""").fetchone():
        raise MigrationError('invalid_source_data')
    # Server-side cursors bound memory even for the largest retained histories.
    with db.cursor(name='validate_events') as cursor:
        cursor.execute('SELECT * FROM collab_events')
        for row in cursor:
            try:
                envelope = json.loads(row['envelope'])
                fingerprint = hashlib.sha256(ev.canonical_bytes([
                    row['sender_participant_id'], row['kind'], envelope['payload']])).hexdigest()
                valid = (envelope['schemaVersion'] == ev.SCHEMA_VERSION and
                         envelope['sessionId'] == row['session_id'] and
                         envelope['eventSequence'] == row['sequence'] and
                         envelope['eventId'] == row['event_id'] and
                         envelope['senderParticipantId'] == row['sender_participant_id'] and
                         envelope['kind'] == row['kind'] and fingerprint == row['fingerprint'] and
                         len(row['envelope'].encode()) == row['size'])
                if not valid:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise MigrationError('invalid_source_data') from None
    with db.cursor(name='validate_requests') as cursor:
        cursor.execute('SELECT result FROM collab_requests')
        for row in cursor:
            try:
                if type(json.loads(row['result'])) is not dict:
                    raise ValueError()
            except (TypeError, ValueError):
                raise MigrationError('invalid_source_data') from None


def import_sqlite(*, source, dsn, schema='public', confirm_source,
                  confirm_destination, offline=False):
    if offline is not True:
        raise MigrationError('offline_confirmation_required')
    path = Path(source).resolve(strict=True)
    if str(path) != confirm_source:
        raise MigrationError('source_confirmation_mismatch')
    # mode=rw never creates an accidentally misspelled source database. No DDL
    # or repository constructor is run against the source.
    local = sqlite3.connect(path.as_uri() + '?mode=rw', uri=True, timeout=10, isolation_level=None)
    try:
        local.execute('BEGIN EXCLUSIVE')
        _source_layout(local)
        with psycopg.connect(dsn, row_factory=dict_row, connect_timeout=10) as db:
            _configure(db, schema)
            # Lifecycle validates its saved authority context before every
            # remaining step, even when collaboration is already complete and
            # only Auth remains. Cutover cannot translate those obligations.
            # Block checkpoint writers through commit so the preflight cannot
            # race a newly prepared cleanup. Never rewrite lifecycle records.
            db.execute('LOCK TABLE account_deletions IN SHARE MODE')
            if db.execute("""SELECT 1 FROM account_deletions
                WHERE state IN ('pending','fenced','deleting')
                  AND (record ? 'cleanup_context' OR
                       coalesce(record->'completed', '[]'::jsonb) <> '[]'::jsonb)
                LIMIT 1""").fetchone():
                raise MigrationError('unfinished_account_cleanup')
            tables = sorted(set(SOURCE_COLUMNS) | {'collab_accounts'})
            db.execute(sql.SQL('LOCK TABLE {} IN ACCESS EXCLUSIVE MODE').format(
                sql.SQL(',').join(map(sql.Identifier, tables))))
            identity = db.execute("SELECT secret FROM collab_secrets WHERE name='authority'").fetchone()
            if identity is None or identity['secret'] != confirm_destination:
                raise MigrationError('destination_confirmation_mismatch')
            for table in tables:
                if table != 'collab_secrets' and db.execute(
                        sql.SQL('SELECT 1 FROM {} LIMIT 1').format(sql.Identifier(table))).fetchone():
                    raise MigrationError('destination_not_empty')
            if db.execute("SELECT 1 FROM collab_secrets WHERE name NOT IN ('cursor','authority') LIMIT 1").fetchone():
                raise MigrationError('destination_not_empty')
            source_secrets = dict(local.execute('SELECT name, secret FROM collab_secrets'))
            try:
                if len(bytes.fromhex(source_secrets['cursor'])) != 32 or 'authority' in source_secrets:
                    raise ValueError()
            except (KeyError, TypeError, ValueError):
                raise MigrationError('invalid_source_data') from None
            counts = {}
            for table, columns in SOURCE_COLUMNS.items():
                if table == 'collab_secrets':
                    continue
                # Preserve source row order while streaming, without re-encoding.
                reader = local.execute(f'SELECT {",".join(columns)} FROM {table} ORDER BY rowid')
                statement = sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(
                    sql.Identifier(table), sql.SQL(',').join(map(sql.Identifier, columns)),
                    sql.SQL(',').join(sql.Placeholder() for _ in columns))
                count = 0
                with db.cursor() as writer:
                    while rows := reader.fetchmany(500):
                        writer.executemany(statement, rows)
                        count += len(rows)
                counts[table] = count
            for name, secret in source_secrets.items():
                db.execute('INSERT INTO collab_secrets VALUES (%s,%s) ON CONFLICT (name) '
                           'DO UPDATE SET secret=excluded.secret', (name, secret))
            db.execute('INSERT INTO collab_accounts SELECT uid FROM collab_memberships '
                       'UNION SELECT uid FROM deleted_accounts ON CONFLICT DO NOTHING')
            _validate_import(db)
            return {'sessions': counts['collab_sessions'], 'events': counts['collab_events'],
                    'requests': counts['collab_requests'], 'authority': identity['secret']}
    except (psycopg.IntegrityError, psycopg.DataError):
        raise MigrationError('invalid_source_data') from None
    finally:
        if local.in_transaction:
            local.rollback()
        local.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--destination-dsn-env', required=True)
    parser.add_argument('--schema', default='public')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('schema', help='explicitly install the collaboration schema')
    commands.add_parser('identity', help='print the destination authority ID for confirmation')
    importer = commands.add_parser('import-sqlite', help='offline, atomic import into an empty authority')
    importer.add_argument('--source-sqlite', required=True)
    importer.add_argument('--confirm-source', required=True)
    importer.add_argument('--confirm-destination', required=True)
    importer.add_argument('--offline', action='store_true', help='confirm all source/destination services are stopped')
    args = parser.parse_args(argv)
    try:
        dsn = os.environ.get(args.destination_dsn_env)
        if not dsn:
            raise MigrationError('destination_dsn_required')
        if args.command == 'schema':
            initialize_schema(dsn=dsn, schema=args.schema)
            result = {'status': 'schema_ready'}
        elif args.command == 'identity':
            result = {'authority': authority_identity(dsn=dsn, schema=args.schema)}
        else:
            result = import_sqlite(source=args.source_sqlite, dsn=dsn, schema=args.schema,
                                   confirm_source=args.confirm_source,
                                   confirm_destination=args.confirm_destination, offline=args.offline)
    except MigrationError as error:
        print(json.dumps({'error': str(error)}))
        return 1
    except Exception:
        # Never echo DSNs, credentials, payloads, SQL diagnostics, or source paths.
        print(json.dumps({'error': 'migration_failed'}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
