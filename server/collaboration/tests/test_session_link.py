"""Session-link collaboration: author names, link invites, cap, revoke, long poll."""
import threading
import time
from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.collaboration import events as ev
from server.collaboration.api import router
from server.collaboration.repository import (CollabError, CollabRepository, MAX_ACTIVE_MEMBERS,
                                             MAX_INVITE_USES)
from server.collaboration.tests.test_repository import Clock

CLAIMS = {
    'owner': {'uid': 'owner', 'name': 'Olivia Owner', 'email': 'olivia@example.com'},
    'guest': {'uid': 'guest', 'email': 'gary.guest@example.com'},
    'nameless': {'uid': 'nameless'},
}


@contextmanager
def admission(claims):
    yield claims['uid']


@pytest.fixture
def service(tmp_path):
    clock = Clock()
    path = tmp_path / 'collab.sqlite'
    repo = CollabRepository(path, clock=clock)

    def connect():
        app = FastAPI()
        app.include_router(router(CollabRepository(path, clock=clock),
                                  lambda uid, check: CLAIMS.get(uid, {'uid': uid}), admission),
                           prefix='/chat')
        return TestClient(app)
    return repo, clock, connect


def headers(uid='owner'):
    return {'Authorization': f'Bearer {uid}', 'X-Firebase-AppCheck': 'check'}


def body(key, **data):
    return {'schemaVersion': 1, 'idempotencyKey': key, **data}


def msg(event_id, text, **extra):
    return {'schemaVersion': 1, 'eventId': event_id, 'kind': 'message',
            'payload': {'text': text, **extra}}


def link(http, uid='owner'):
    token = http.post('/chat', headers=headers(uid),
                      json=body('create', requestId='create')).json()['sessionToken']
    invite = http.post(f'/chat/{token}/members', headers=headers(uid),
                       json=body('link', maxUses=MAX_INVITE_USES, ttlSeconds=7 * 86400)).json()
    return token, invite


def join(http, token, code, uid):
    return http.post(f'/chat/{token}/members', headers=headers(uid),
                     json=body(f'join-{uid}', invitationCode=code))


def test_display_name_uses_verified_claims_and_never_full_email():
    assert ev.display_name(CLAIMS['owner']) == 'Olivia Owner'
    assert ev.display_name(CLAIMS['guest']) == 'gary.guest'
    assert ev.display_name(CLAIMS['nameless']) == 'Ovid user'
    assert ev.display_name({'name': '  A\x00‮B  ', 'email': 'x@y'}) == 'AB'
    assert len(ev.display_name({'name': 'n' * 300})) == 64
    # A name the client label screen would reject falls back instead of poisoning replay.
    assert ev.display_name({'name': '/root/secret', 'email': 'jo@example.com'}) == 'jo'
    assert ev.display_name('uid-only') == 'Ovid user'


def test_message_payload_roles_models_and_server_only_name_field():
    ok = ev.validate_client_event(msg('e1', 'hi', role='assistant', model='GPT 5', replyTo='e0'))
    assert ok['payload'] == {'text': 'hi', 'role': 'assistant', 'model': 'GPT 5', 'replyTo': 'e0'}
    assert ev.validate_client_event(msg('e2', 'legacy'))['payload'] == {'text': 'legacy'}
    with pytest.raises(ev.EventRejected):
        ev.validate_client_event(msg('e3', 'x', role='system'))
    with pytest.raises(ev.EventRejected) as caught:
        ev.validate_client_event({**msg('e4', 'x'), 'senderDisplayName': 'Mallory'})
    assert caught.value.reason == 'serverField'
    with pytest.raises(ev.EventRejected):
        ev.validate_client_event(msg('e5', 'x', model='sk-abcdefghijklmnop'))


def test_author_names_are_stamped_and_listed(service):
    repo, _, connect = service
    http = connect()
    token, invite = link(http)
    assert join(http, token, invite['inviteCode'], 'guest').status_code == 200
    sent = http.post(f'/chat/{token}/events', headers=headers('owner'),
                     json=body('m1', events=[msg('m1', 'hello', role='user')]))
    assert sent.json()['events'][0]['senderDisplayName'] == 'Olivia Owner'
    replay = http.get(f'/chat/{token}/events', headers=headers('guest')).json()['events']
    joined = [e for e in replay if e['kind'] == 'membership'][0]
    assert joined['senderDisplayName'] == 'gary.guest'
    state = http.get(f'/chat/{token}', headers=headers('guest')).json()
    names = {m['role']: m.get('displayName') for m in state['members']}
    assert names == {'owner': 'Olivia Owner', 'participant': 'gary.guest'}
    assert state['member']['displayName'] == 'gary.guest'
    assert 'displayName' not in state['initialMembers'][0]


def test_link_admits_ten_including_owner_then_reports_full(service):
    repo, _, connect = service
    http = connect()
    token, invite = link(http)
    for i in range(MAX_ACTIVE_MEMBERS - 1):
        assert join(http, token, invite['inviteCode'], f'user{i}').status_code == 200
    full = join(http, token, invite['inviteCode'], 'eleventh')
    assert full.status_code == 409
    assert full.json()['code'] == 'session_full'
    # A seat frees up when someone leaves; the same link still works.
    assert http.delete(f'/chat/{token}/members/me', headers=headers('user0')).status_code == 200
    assert join(http, token, invite['inviteCode'], 'eleventh').status_code == 200


def test_owner_revokes_link_and_removes_members(service):
    repo, _, connect = service
    http = connect()
    token, invite = link(http)
    member = join(http, token, invite['inviteCode'], 'guest').json()['member']
    assert http.delete(f"/chat/{token}/invites/{invite['inviteId']}",
                       headers=headers('guest')).json()['code'] == 'not_owner'
    revoked = http.delete(f"/chat/{token}/invites/{invite['inviteId']}", headers=headers('owner'))
    assert revoked.status_code == 200 and revoked.json()['revoked'] is True
    late = join(http, token, invite['inviteCode'], 'late')
    assert late.json()['code'] == 'invite_invalid'
    assert http.delete(f'/chat/{token}/invites/i{"0" * 32}',
                       headers=headers('owner')).json()['code'] == 'invite_not_found'
    # Existing members keep access until removed; removal blocks re-entry via older links.
    assert http.get(f'/chat/{token}', headers=headers('guest')).status_code == 200
    fresh = http.post(f'/chat/{token}/members', headers=headers('owner'),
                      json=body('link2', maxUses=MAX_INVITE_USES, ttlSeconds=3600)).json()
    removed = http.delete(f"/chat/{token}/members/{member['participantId']}", headers=headers('owner'))
    assert removed.json()['member']['status'] == 'revoked'
    again = http.post(f'/chat/{token}/members', headers=headers('guest'),
                      json=body('join-again', invitationCode=fresh['inviteCode']))
    assert again.json()['code'] == 'membership_revoked'
    assert http.get(f'/chat/{token}', headers=headers('guest')).json()['code'] == 'not_member'


def test_long_poll_returns_new_events_promptly(service):
    repo, _, connect = service
    http = connect()
    token, _ = link(http)
    route = f'/chat/{token}/events'
    cursor = http.get(route, headers=headers()).json()['nextCursor']

    def later():
        time.sleep(0.4)
        repo.append_batch('owner', token, [msg('late', 'arrived')], idempotency_key='late')
    threading.Thread(target=later).start()
    started = time.monotonic()
    page = http.get(route, headers=headers(), params={'cursor': cursor, 'wait': 10}).json()
    assert [e['eventId'] for e in page['events']] == ['late']
    assert time.monotonic() - started < 5
    # Immediate return when events already exist; bounded wait otherwise.
    assert http.get(route, headers=headers(), params={'wait': 10}).json()['events']
    started = time.monotonic()
    empty = http.get(route, headers=headers(), params={'cursor': page['nextCursor'], 'wait': 1}).json()
    assert empty['events'] == [] and 0.9 < time.monotonic() - started < 5
    assert http.get(route, headers=headers(), params={'wait': 26}).json()['code'] == 'invalid_request'


def test_head_probe_rejects_bad_tokens(service):
    repo, _, _ = service
    token = repo.create_session('owner', 'create')['sessionToken']
    assert repo.head_sequence(token) == (0, 'active')
    assert repo.head_sequence('x') is None
    assert repo.head_sequence('A' * 43) is None
    with pytest.raises(CollabError):
        repo.create_invite('owner', token, max_uses=MAX_INVITE_USES + 1)
