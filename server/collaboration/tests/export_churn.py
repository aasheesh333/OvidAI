"""Repository-only fixture consumed by the Dart cold-replay test.

The Flutter CI job intentionally does not install the server's FastAPI stack;
the fixture therefore exercises the durable repository contract directly.
HTTP transport is covered by the Python collaboration integration suite.
"""
import json
import tempfile
from server.collaboration.repository import CollabRepository

def export():
    with tempfile.TemporaryDirectory() as directory:
        repo = CollabRepository(directory + '/db')
        token = repo.create_session('owner', 'create')['sessionToken']
        # Departed local participant also rejoins: old removal is historical.
        for i in range(12):
            code = repo.create_invite('owner', token)['inviteCode']
            repo.join(f'u{i}', token, code)
            repo.append(f'u{i}', token, {'schemaVersion': 1, 'eventId': f'e{i}',
                        'kind': 'message', 'payload': {'text': f'history-{i}'}})
            repo.leave(f'u{i}', token)
        code = repo.create_invite('owner', token, max_uses=9)['inviteCode']
        for i in range(9):
            repo.join(f'u{i}', token, code)
        state = {'schemaVersion': 1, **repo.get_state('u0', token)}
        raw_page = repo.replay('u0', token, state['cursor'])
        page = {'schemaVersion': 1, 'events': raw_page['events'],
                'nextCursor': raw_page['cursor'], 'hasMore': raw_page['hasMore']}
        return {'state': state, 'page': page}

if __name__ == '__main__':
    print(json.dumps(export()))
