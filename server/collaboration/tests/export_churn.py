"""Real FastAPI/repository fixture consumed by the Dart cold-replay test."""
import json
import tempfile
from contextlib import contextmanager
from fastapi import FastAPI
from fastapi.testclient import TestClient
from server.collaboration.api import router
from server.collaboration.repository import CollabRepository

@contextmanager
def admission(claims):
    yield claims

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
        app = FastAPI()
        app.include_router(router(repo, lambda *_: {'uid': 'u0'}, admission), prefix='/chat')
        http = TestClient(app)
        headers = {'Authorization': 'Bearer test', 'X-Firebase-AppCheck': 'test'}
        state = http.get(f'/chat/{token}', headers=headers)
        assert state.status_code == 200
        page = http.get(f'/chat/{token}/events', headers=headers,
                        params={'cursor': state.json()['cursor']})
        assert page.status_code == 200
        return {'state': state.json(), 'page': page.json()}

if __name__ == '__main__':
    print(json.dumps(export()))
