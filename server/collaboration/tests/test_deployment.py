"""Deployment contract for the collaboration PostgreSQL schema.

Static checks run everywhere and keep the two deployment routes (the Python
migration entry point and the account SQL migrations) equivalent. The live test
creates a fresh schema, applies the account bootstrap, runs the real migration
entry point twice, and exercises the 50-member, turn-lock and creator-paid
storage contract. Set COLLAB_TEST_POSTGRES_DSN to a disposable PostgreSQL 16
database to run it; without a DSN the live test is skipped.
"""
from __future__ import annotations

import os
import re
import uuid
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest

from server.collaboration.migrate import initialize_schema
from server.collaboration.repository import (
    MAX_ACTIVE_MEMBERS, MAX_INVITE_USES, CollabError)
from server.collaboration.tests.test_repository import Clock

COLLAB = Path(__file__).resolve().parents[1]
ACCOUNT = COLLAB.parent / 'account'
EXTENSIONS = COLLAB / 'schema_extensions.sql'
MIGRATION_004 = ACCOUNT / 'migrations' / '004_live_collaboration.sql'
MIGRATION_005 = ACCOUNT / 'migrations' / '005_collaboration_contract.sql'


def without_comments(sql_text: str) -> str:
    return re.sub(r'--[^\n]*', '', sql_text)


def normalized(sql_text: str) -> str:
    text = re.sub(r'\s+', ' ', without_comments(sql_text)).strip().lower()
    return text.removeprefix('begin; ').removesuffix(' commit;')


# ----------------------------------------------------------------------
# Static deployment artifacts (no PostgreSQL required)
# ----------------------------------------------------------------------

def test_account_migration_matches_collaboration_extensions():
    # Two deployment routes exist: `migrate ... schema` reads
    # schema_extensions.sql, while existing account databases apply 005. They
    # must stay byte-equivalent apart from comments and the SQL transaction.
    assert normalized(MIGRATION_005.read_text(encoding='utf-8')) == \
        normalized(EXTENSIONS.read_text(encoding='utf-8'))


def test_extensions_are_idempotent_and_include_tables_indexes_and_fks():
    text = without_comments(EXTENSIONS.read_text(encoding='utf-8'))
    lowered = text.lower()
    for table in ('collab_turns', 'collab_storage_files', 'collab_storage_usage'):
        assert re.search(rf'create table if not exists {table}\b', lowered), table
    for index in ('collab_turns_uid', 'collab_storage_files_owner',
                  'collab_storage_files_session'):
        assert re.search(rf'create index if not exists {index}\b', lowered), index
    assert lowered.count('foreign key (session_id) references collab_sessions') == 2
    assert 'on delete cascade' in lowered
    assert 'drop constraint if exists collab_invites_max_uses_check' in lowered
    assert 'check (max_uses between 1 and 50)' in lowered


def test_account_bootstrap_allows_the_full_member_cap():
    text = normalized(MIGRATION_004.read_text(encoding='utf-8'))
    assert 'max_uses integer not null check (max_uses between 1 and 50)' in text
    assert 'between 1 and 9' not in text


# ----------------------------------------------------------------------
# Fresh PostgreSQL schema -> migration -> contract
# ----------------------------------------------------------------------

@pytest.fixture
def deployed_schema():
    dsn = os.environ.get('COLLAB_TEST_POSTGRES_DSN')
    if not dsn:
        pytest.skip('COLLAB_TEST_POSTGRES_DSN is required for real PostgreSQL tests')
    schema = 'collab_deploy_' + uuid.uuid4().hex
    with psycopg.connect(dsn) as db:
        db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        db.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(schema)))
        db.execute((ACCOUNT / 'schema.sql').read_text(encoding='utf-8'))
    try:
        # The deployment command documented in README.md / DEPLOYMENT.md.
        initialize_schema(dsn=dsn, schema=schema)
        yield dsn, schema
    finally:
        with psycopg.connect(dsn, autocommit=True) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(schema)))


def test_fresh_schema_migration_is_idempotent_and_constrains_rows(deployed_schema):
    dsn, schema = deployed_schema
    initialize_schema(dsn=dsn, schema=schema)  # re-run: must be a no-op

    with psycopg.connect(dsn, autocommit=True, row_factory=dict_row) as db:
        db.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(schema)))
        tables = {row['table_name'] for row in db.execute(
            'SELECT table_name FROM information_schema.tables WHERE table_schema=%s',
            (schema,))}
        assert {'collab_turns', 'collab_storage_files', 'collab_storage_usage'} <= tables
        indexes = {row['indexname'] for row in db.execute(
            'SELECT indexname FROM pg_indexes WHERE schemaname=%s', (schema,))}
        assert {'collab_turns_uid', 'collab_storage_files_owner',
                'collab_storage_files_session'} <= indexes
        foreign_keys = {row['conname'] for row in db.execute(
            "SELECT conname FROM pg_constraint WHERE contype='f' AND conrelid IN "
            "('collab_turns'::regclass, 'collab_storage_files'::regclass)")}
        assert foreign_keys == {'collab_turns_session_fk',
                                'collab_storage_files_session_fk'}

        # The 50-member cap is enforced by the database, not only by the client.
        for max_uses in (1, 50):
            db.execute(
                'INSERT INTO collab_invites (invite_id, session_id, code_hash, '
                'issued_generation, max_uses, created_at, expires_at) '
                'VALUES (%s,%s,%s,1,%s,0,0)',
                (uuid.uuid4().hex, 'session', uuid.uuid4().hex, max_uses))
        with pytest.raises(psycopg.errors.CheckViolation):
            db.execute(
                'INSERT INTO collab_invites (invite_id, session_id, code_hash, '
                'issued_generation, max_uses, created_at, expires_at) '
                'VALUES (%s,%s,%s,1,51,0,0)',
                (uuid.uuid4().hex, 'session', uuid.uuid4().hex))

        # Turn and storage rows cannot outlive an unknown session.
        with pytest.raises(psycopg.errors.ForeignKeyViolation):
            db.execute("INSERT INTO collab_turns VALUES ('missing','uid','p',1,0,0)")
        with pytest.raises(psycopg.errors.ForeignKeyViolation):
            db.execute("INSERT INTO collab_storage_files "
                       "VALUES ('file','missing','uid','owner',1,0)")


def test_fresh_schema_runs_the_collaboration_contract(deployed_schema):
    from server.collaboration.postgres import PostgresCollabRepository

    dsn, schema = deployed_schema
    clock = Clock()
    repo = PostgresCollabRepository(dsn=dsn, schema=schema, clock=clock)

    token = repo.create_session('owner', 'create')['sessionToken']
    invite = repo.create_invite('owner', token, max_uses=MAX_INVITE_USES)['inviteCode']
    for i in range(MAX_ACTIVE_MEMBERS - 1):
        repo.join(f'member{i}', token, invite)
    assert len(repo.get_state('owner', token)['members']) == MAX_ACTIVE_MEMBERS
    with pytest.raises(CollabError) as full:
        repo.join('overflow', token, invite)
    assert full.value.code == 'session_full'

    assert repo.acquire_turn('owner', token)['mine'] is True
    with pytest.raises(CollabError) as taken:
        repo.acquire_turn('member0', token)
    assert taken.value.code == 'turn_taken'
    assert repo.release_turn('owner', token) == {'released': True}
    assert repo.acquire_turn('member0', token)['mine'] is True

    usage = repo.record_upload('member0', token, file_id='file-1', size_bytes=1024)
    assert usage == {'ownerUid': 'owner', 'bytesUsed': 1024,
                     'fileCount': 1, 'isCreator': False}
    assert repo.storage_usage('owner', token) == {
        'ownerUid': 'owner', 'bytesUsed': 1024, 'fileCount': 1, 'isCreator': True}
