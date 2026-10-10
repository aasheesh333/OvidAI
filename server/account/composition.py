"""Stable gateway + local image/share cleanup checkpoints, before Auth."""


class CleanupData:
    def __init__(self, gateway, stores, *, private_sync=None,
                 live_collaboration=None):
        self.gateway, self.stores = gateway, stores
        self.private_sync = private_sync
        self.live_collaboration = live_collaboration

    def prepare(self, uid):
        context = {
            **self.gateway.prepare(uid),
            'store_identities': dict(self.stores.identities),
            'authority_identities': self.authority_identities(),
            'cleanup_steps': [name for name, _ in self.deletion_steps()],
        }
        return context

    @staticmethod
    def _authority_identity(value):
        identity = getattr(value, 'authority_identity', None)
        if identity is None:
            identity = getattr(value, 'identity', None)
        if callable(identity):
            identity = identity()
        if identity is not None:
            return str(identity)
        path = getattr(value, 'path', None)
        if path is not None:
            return f'{type(value).__module__}.{type(value).__qualname__}:{path}'
        return f'{type(value).__module__}.{type(value).__qualname__}'

    def authority_identities(self):
        identities = dict(self.stores.identities)
        for name, repository in (
            ('private_sync', self.private_sync),
            ('live_collaboration', self.live_collaboration),
        ):
            if repository is not None:
                identities[name] = self._authority_identity(repository)
        return identities

    def validate_context(self, context):
        expected = context.get('store_identities')
        if expected is not None and expected != self.stores.identities:
            raise ValueError('Cleanup authority changed during deletion')
        expected_authorities = context.get('authority_identities')
        if (expected_authorities is not None and
                expected_authorities != self.authority_identities()):
            raise ValueError('Cleanup authority changed during deletion')
        expected_steps = context.get('cleanup_steps')
        current_steps = [name for name, _ in self.deletion_steps()]
        if expected_steps is not None:
            if (not isinstance(expected_steps, list) or
                    len(set(expected_steps)) != len(expected_steps) or
                    expected_steps != current_steps):
                raise ValueError('Cleanup stage disappeared during deletion')
        else:
            # Upgrade an in-progress record written before named composition
            # checkpoints existed. The current composition is authoritative
            # only for this one-time legacy upgrade.
            context['cleanup_steps'] = current_steps
        # Legacy in-progress records bind to the explicitly provisioned stores
        # on upgrade, before any additional effect; never infer completion.
        context['store_identities'] = dict(self.stores.identities)
        context['authority_identities'] = self.authority_identities()

    def revoke_keys(self, uid, context):
        self.gateway.revoke_keys(uid, context)

    def deletion_steps(self):
        steps = getattr(self.gateway, 'deletion_steps', None)
        gateway_steps = steps() if steps else (('gateway', self.gateway.delete_data),)
        return (*gateway_steps, *self.required_deletion_steps())

    def required_deletion_steps(self):
        # These stages are mandatory even when an older binary saved aggregate
        # `data`. Its checkpoint only certified the old gateway cleanup scope.
        steps = []
        if self.private_sync is not None:
            steps.append(('private_sync',
                          lambda uid, context: self.private_sync.delete_account(uid)))
        if self.live_collaboration is not None:
            steps.append(('live_collaboration',
                          lambda uid, context: self.live_collaboration.delete_account(uid)))
        steps.extend((('images', lambda uid, context: self.stores.images.delete_account(uid)),
                      ('shares', lambda uid, context: self.stores.shares.delete_account(uid))))
        return tuple(steps)
