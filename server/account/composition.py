"""Stable gateway + local image/share cleanup checkpoints, before Auth."""


class CleanupData:
    def __init__(self, gateway, stores):
        self.gateway, self.stores = gateway, stores

    def prepare(self, uid):
        return {**self.gateway.prepare(uid), 'store_identities': dict(self.stores.identities)}

    def validate_context(self, context):
        expected = context.get('store_identities')
        if expected is not None and expected != self.stores.identities:
            raise ValueError('Cleanup authority changed during deletion')
        # Legacy in-progress records bind to the explicitly provisioned stores
        # on upgrade, before any additional effect; never infer completion.
        context['store_identities'] = dict(self.stores.identities)

    def revoke_keys(self, uid, context):
        self.gateway.revoke_keys(uid, context)

    def deletion_steps(self):
        steps = getattr(self.gateway, 'deletion_steps', None)
        gateway_steps = steps() if steps else (('gateway', self.gateway.delete_data),)
        return (*gateway_steps, *self.required_deletion_steps())

    def required_deletion_steps(self):
        # These stages are mandatory even when an older binary saved aggregate
        # `data`. Its checkpoint only certified the old gateway cleanup scope.
        return (('images', lambda uid, context: self.stores.images.delete_account(uid)),
                ('shares', lambda uid, context: self.stores.shares.delete_account(uid)))
