import sys
import types
import unittest
from contextlib import contextmanager
from importlib import import_module, reload
from unittest.mock import Mock

class RuntimeTest(unittest.TestCase):
    def test_mounts_api_router_with_authentication_and_admission(self):
        captured = {}
        api = types.ModuleType('server.collaboration.api')

        def router(repository, verify, admission):
            captured.update(repository=repository, verify=verify, admission=admission)
            return 'routes'

        api.router = router
        original = sys.modules.get('server.collaboration.api')
        sys.modules['server.collaboration.api'] = api
        self.addCleanup(self._restore_api, original)

        mount_collaboration = self._load_runtime().mount_collaboration

        app = Mock()
        repository, lifecycle, admin = object(), Mock(), Mock()
        mount_collaboration(app, repository, lifecycle, admin, prefix='/chat')

        self.assertIs(captured['repository'], repository)
        self.assertIs(captured['verify']('token', 'attestation'),
                      admin.verify.return_value)
        admin.verify.assert_called_once_with('token', 'attestation', allow_disabled=False)
        app.include_router.assert_called_once_with('routes', prefix='/chat')

        lifecycle.access.return_value = self._admission('alice')
        with captured['admission']({'uid': 'claim'}) as uid:
            self.assertEqual(uid, 'alice')
        lifecycle.access.assert_called_once_with({'uid': 'claim'})

    def test_translates_account_access_errors_to_http_errors(self):
        api = types.ModuleType('server.collaboration.api')
        api.router = lambda *_args, **_kwargs: 'routes'
        original = sys.modules.get('server.collaboration.api')
        sys.modules['server.collaboration.api'] = api
        self.addCleanup(self._restore_api, original)

        from server.account.domain import AccountError
        mount_collaboration = self._load_runtime().mount_collaboration

        lifecycle = Mock()
        lifecycle.access.side_effect = AccountError('account_deleted', 403)
        admission = self._mount_and_get_admission(lifecycle)

        with self.assertRaisesRegex(Exception, 'account_deleted') as caught:
            with admission({'uid': 'claim'}):
                pass
        self.assertEqual(caught.exception.code, 'account_deleted')
        self.assertEqual(caught.exception.status, 403)

    def test_normalizes_prefix_without_trailing_slash(self):
        api = types.ModuleType('server.collaboration.api')
        api.router = lambda *_args, **_kwargs: 'routes'
        original = sys.modules.get('server.collaboration.api')
        sys.modules['server.collaboration.api'] = api
        self.addCleanup(self._restore_api, original)

        mount_collaboration = self._load_runtime().mount_collaboration

        app = Mock()
        mount_collaboration(app, object(), Mock(), Mock(), prefix='/chat/')

        app.include_router.assert_called_once_with('routes', prefix='/chat')

    def test_router_is_given_the_mount_prefix_only_once(self):
        captured = {}
        api = types.ModuleType('server.collaboration.api')
        api.router = lambda *args, **kwargs: captured.update(kwargs) or 'routes'
        original = sys.modules.get('server.collaboration.api')
        sys.modules['server.collaboration.api'] = api
        self.addCleanup(self._restore_api, original)

        mount_collaboration = self._load_runtime().mount_collaboration
        app = Mock()
        mount_collaboration(app, object(), Mock(), Mock(), prefix='/v1/chat')

        self.assertIsNone(captured.get('prefix'))
        app.include_router.assert_called_once_with('routes', prefix='/v1/chat')

    @staticmethod
    @contextmanager
    def _admission(uid):
        yield uid

    def _mount_and_get_admission(self, lifecycle):
        captured = {}
        api = sys.modules['server.collaboration.api']
        api.router = lambda _repository, _verify, admission: captured.setdefault(
            'admission', admission) or 'routes'
        self._load_runtime().mount_collaboration(Mock(), object(), lifecycle, Mock())
        return captured['admission']

    @staticmethod
    def _load_runtime():
        module = import_module('server.collaboration.runtime')
        return reload(module)

    @staticmethod
    def _restore_api(original):
        if original is None:
            sys.modules.pop('server.collaboration.api', None)
        else:
            sys.modules['server.collaboration.api'] = original


if __name__ == '__main__':
    unittest.main()
