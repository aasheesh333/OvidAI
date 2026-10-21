"""PostgreSQL IP-hop store. Live tests skip without a disposable DSN.

Set ``IP_HOP_TEST_POSTGRES_DSN`` (or the shared ``SYNC_TEST_DATABASE_URL``) to
run the adapter against a real server.  Each test creates and drops its own
schema, so a shared development database is safe.
"""

import os
from pathlib import Path
from uuid import uuid4

import pytest

from server.security.ip_hop import (
    GeoInfo,
    IpHopBlocked,
    IpHopGuard,
    PostgresIpHopStore,
    StaticGeoResolver,
    _schema_statements,
)

LONDON = GeoInfo('GB', 'AS1', 'London', 51.5074, -0.1278)
NEW_YORK = GeoInfo('US', 'AS2', 'New York', 40.7128, -74.0060)
SCHEMA_FILE = Path(__file__).resolve().parents[1] / 'schema_postgres.sql'
DSN = (os.environ.get('IP_HOP_TEST_POSTGRES_DSN') or
       os.environ.get('SYNC_TEST_DATABASE_URL'))


def test_schema_file_is_postgres_flavored_and_idempotent():
    text = SCHEMA_FILE.read_text(encoding='utf-8')
    assert 'BIGSERIAL PRIMARY KEY' in text
    assert 'active BOOLEAN NOT NULL DEFAULT TRUE' in text
    assert 'DOUBLE PRECISION' in text
    assert 'AUTOINCREMENT' not in text
    assert ' REAL' not in text
    statements = _schema_statements(text)
    assert len(statements) >= 8
    assert all(statement.startswith(('CREATE TABLE', 'CREATE INDEX'))
               for statement in statements)
    # Comments must not survive splitting; re-applying the DDL is idempotent.
    assert all('--' not in statement for statement in statements)


@pytest.fixture
def store():
    if not DSN:
        pytest.skip('IP_HOP_TEST_POSTGRES_DSN requires an isolated test database')
    import psycopg
    from psycopg import sql
    from psycopg.conninfo import make_conninfo

    schema = 'ip_hop_' + uuid4().hex
    with psycopg.connect(DSN, autocommit=True) as db:
        db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
    scoped = make_conninfo(DSN, options=f'-c search_path={schema}')
    instance = PostgresIpHopStore(scoped)
    try:
        yield instance
    finally:
        instance.close()
        with psycopg.connect(DSN, autocommit=True) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(
                sql.Identifier(schema)))


def test_schema_is_applied_to_a_fresh_schema(store):
    import psycopg
    from psycopg import sql

    with psycopg.connect(store.dsn) as db:
        tables = {row[0] for row in db.execute('''
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = current_schema()
        ''').fetchall()}
    assert {'ip_hop_observations', 'ip_hop_blocks', 'ip_hop_overrides',
            'ip_hop_audit', 'ip_hop_alerts'} <= tables


def test_guard_lifecycle_block_audit_alert_and_admin_unblock(store):
    emails = []
    guard = IpHopGuard(
        store,
        resolver=StaticGeoResolver({'1.2.3.4': LONDON, '5.6.7.8': NEW_YORK}),
        email_hook=emails.append)

    guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
    with pytest.raises(IpHopBlocked):
        guard.observe('alice', 'session-bbbb', '5.6.7.8', now=1100)

    blocked = store.blocked('alice', 'session-bbbb', 1100)
    assert blocked is not None
    assert blocked['reason'] == 'impossible_travel'
    assert blocked['active'] is True
    assert [item.session_id for item in store.recent('alice', 0)] == [
        'session-aaaa', 'session-bbbb']
    assert store.active_blocks('alice', 1100)[0]['session_id'] == 'session-bbbb'

    audit = store.audit_rows('alice')[0]
    assert audit['action'] == 'block'
    assert audit['older_session_id'] == 'session-aaaa'
    assert audit['country'] == 'US'
    assert audit['older_country'] == 'GB'

    alerts = store.alert_rows('alice')
    assert len(alerts) == 1
    assert alerts[0]['status'] == 'sent'
    assert len(emails) == 1

    # The older session keeps working while the newer one is blocked.
    assert guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1200).recorded

    assert guard.admin_unblock('alice', 'session-bbbb', actor='admin-1',
                               reason='verified travel', now=1300) == 1
    assert store.blocked('alice', 'session-bbbb', 1300) is None
    assert store.override_active('alice', 'session-bbbb', 1301) is True
    assert guard.observe('alice', 'session-bbbb', '5.6.7.8',
                         now=1301).reason == 'admin_override'
    assert store.audit_rows('alice')[0]['action'] == 'unblock'


def test_expired_block_is_cleared_on_lookup(store):
    store.block('alice', 'session-bbbb', 'impossible_travel', 'event-1',
                blocked_at=900, blocked_until=1000)
    assert store.blocked('alice', 'session-bbbb', 999) is not None
    assert store.blocked('alice', 'session-bbbb', 1001) is None
    assert store.active_blocks('alice', 1001) == []


def test_unblock_all_sessions_and_alert_claim_is_exactly_once(store):
    store.block('alice', 'session-aaaa', 'country_burst', 'event-a', 900, 2000)
    store.block('alice', 'session-bbbb', 'country_burst', 'event-b', 901, 2000)
    assert sorted(store.unblock('alice', None, 1000)) == [
        'session-aaaa', 'session-bbbb']
    assert store.active_blocks('alice', 1000) == []

    assert store.claim_alert('alice:1', 'alice', 1000) is True
    assert store.claim_alert('alice:1', 'alice', 1001) is False
    store.mark_alert('alice:1', 'sent')
    assert store.alert_rows('alice')[0]['status'] == 'sent'


def test_prune_bounds_age_count_audit_and_alerts(store):
    guard = IpHopGuard(
        store,
        resolver=StaticGeoResolver({f'10.0.0.{index}': LONDON
                                    for index in range(1, 6)}),
        retention_seconds=100,
        max_observations_per_account=2,
        prune_interval_seconds=10_000,
        audit_retention_seconds=100,
        block_seconds=50,
        override_seconds=50,
    )
    for index in range(1, 6):
        guard.observe('alice', f'session-{index:04d}',
                      f'10.0.0.{index}', now=1000 + index)

    result = guard.prune(now=1005)
    assert result['observations'] == 3
    assert [item.seen_at for item in store.recent('alice', 0)] == [1004.0, 1005.0]

    store.block('bob', 'session-xxxx', 'impossible_travel', 'event-b',
                blocked_at=1000, blocked_until=1050)
    store.set_override('bob', 'session-xxxx', until=1050, actor='admin-1',
                       reason='verified travel', created_at=1000)
    store.audit(event_id='event-b', uid='bob', action='block',
                reason='impossible_travel', created_at=1000)
    store.claim_alert('bob:1', 'bob', 1000)

    result = guard.prune(now=2000)
    assert result['observations'] == 2
    assert result['blocks'] == 1
    assert result['overrides'] == 1
    assert result['audit'] == 1
    assert result['alerts'] == 1
    assert store.recent('alice', 0) == []
    assert store.audit_rows('bob') == []
    assert store.alert_rows('bob') == []
