"""Account-deletion grace facade for the P3 product contract.

The durable state machine lives in :mod:`server.account.domain`; this module is
the product-facing seam used by the account routes and the expiry worker. It
adds the receipt fields the app needs (grace length, whether the account can
still be restored, and the Google Play subscription-management link) without
changing the reviewed lifecycle semantics.

Product rules:

* A deletion request is durable and ``pending`` for exactly 24 hours
  (``GRACE_SECONDS``). Repeated requests never extend the deadline.
* Signing in during grace is observational: it tells the app that the account
  can still be restored. Cancellation itself is an explicit, recently
  authenticated action (``restore``/``cancel_deletion``), so token refreshes
  and background callbacks can never resurrect or cancel an account.
* ``sign_in_and_restore`` is the two-step UX ("sign in again and restore") in
  one call. It only restores after the explicit restore action.
* After ``delete_after`` the worker fences the account and hard-deletes keys,
  data and the identity. Cancellation wins only while the row is still
  ``pending`` (before the deadline) or inside the worker's settlement window.
* Play subscriptions are never cancelled automatically. Every receipt carries
  the Play subscription centre URL so the client can show "Manage Play
  subscription" next to the deletion confirmation.

No import in this module connects to Firebase, PostgreSQL, Redis or HTTP.
"""

import logging
import time
from datetime import timedelta

from .domain import GRACE_SECONDS as _DOMAIN_GRACE_SECONDS, Lifecycle

#: Duration of the cancellable window between request and hard deletion.
GRACE_PERIOD = timedelta(hours=24)
GRACE_SECONDS = int(GRACE_PERIOD.total_seconds())

# Keep one source of truth with the lifecycle state machine. The assertion is
# deliberately cheap and fails at import if the two constants ever drift.
assert GRACE_SECONDS == _DOMAIN_GRACE_SECONDS

#: Google Play subscription centre (cancel, downgrade, update payment).
#: Mirrors ``playSubscriptionCenterUri()`` in ``lib/core/play_billing.dart``.
PLAY_SUBSCRIPTION_MANAGEMENT_URL = 'https://play.google.com/store/account/subscriptions'

_log = logging.getLogger(__name__)


class AccountDeletion:
    """Product-facing account-deletion service over a :class:`Lifecycle`.

    ``AccountDeletion(Lifecycle(...))`` is the normal composition. Tests and
    tools can also use :meth:`compose` to build the backing lifecycle directly.
    Delegated attributes (``store``, ``admin``, ``data``, ``clock``, ``ip_hop``,
    ``observe``, ``access``, ``unblock_session``) keep this a drop-in for the
    current HTTP router and gateway/quota callers.
    """

    def __init__(self, lifecycle, *, play_url=PLAY_SUBSCRIPTION_MANAGEMENT_URL):
        self.lifecycle = lifecycle
        self.play_url = play_url

    def __getattr__(self, name):
        # Keep this a drop-in for callers that use less common Lifecycle
        # helpers (for example recovery tooling) without copying every method.
        return getattr(object.__getattribute__(self, 'lifecycle'), name)

    @classmethod
    def compose(cls, store, admin, data, *, clock=time.time, play_url=None, **kwargs):
        """Build a deletion service with a fresh ``Lifecycle`` state machine."""
        lifecycle = Lifecycle(store, admin, data, clock=clock, **kwargs)
        if play_url is None:
            return cls(lifecycle)
        return cls(lifecycle, play_url=play_url)

    # -- delegated lifecycle surface -------------------------------------

    @property
    def store(self):
        return self.lifecycle.store

    @property
    def admin(self):
        return self.lifecycle.admin

    @property
    def data(self):
        return self.lifecycle.data

    @property
    def clock(self):
        return self.lifecycle.clock

    @property
    def ip_hop(self):
        return getattr(self.lifecycle, 'ip_hop', None)

    def observe(self, claims, request=None):
        return self.lifecycle.observe(claims, request)

    def access(self, claims, *, request=None):
        return self.lifecycle.access(claims, request=request)

    def unblock_session(self, uid, session_id, *, actor, reason):
        return self.lifecycle.unblock_session(uid, session_id, actor=actor, reason=reason)

    # -- receipts --------------------------------------------------------

    def _receipt(self, payload, *, restored=False):
        """Add grace/restore/Play fields to a lifecycle receipt.

        The lifecycle receipt stays the source of truth for ``state``,
        ``delete_after`` and ``request_id``. ``can_restore`` is a hint for the
        UI; the server re-checks the deadline and recent authentication when
        the restore action actually arrives.
        """
        result = dict(payload or {})
        result.setdefault('state', 'active')
        result['grace_seconds'] = GRACE_SECONDS
        result['manage_subscription_url'] = self.play_url
        result['subscription_cancelled_automatically'] = False
        result['restore_requires_sign_in'] = True

        state = result['state']
        deadline = result.get('delete_after')
        if state == 'pending':
            can_restore = deadline is None or self.clock() <= deadline
        elif state == 'fenced':
            can_restore = True
        else:
            can_restore = False
        result['can_restore'] = can_restore
        if state == 'cancelled':
            result['restored'] = bool(restored)
        elif restored:
            result['restored'] = True
        return result

    # -- request / status / sign-in --------------------------------------

    def request_deletion(self, claims, request_id):
        """Start the 24-hour grace period; returns pending + ``delete_after``."""
        return self._receipt(self.lifecycle.request(claims, request_id))

    def request(self, claims, request_id):
        """Alias used by the existing ``POST /account/deletion`` route."""
        return self.request_deletion(claims, request_id)

    def status(self, claims):
        return self._receipt(self.lifecycle.status(claims))

    def sign_in(self, claims):
        """Acknowledge a real sign-in without mutating deletion state.

        Authentication is not consent. The receipt reports ``can_restore`` and
        the client shows the explicit "Restore account" action.
        """
        return self._receipt(self.lifecycle.login(claims))

    def login(self, claims):
        """Alias used by the existing ``POST /account/login`` route."""
        return self.sign_in(claims)

    def sign_in_and_restore(self, claims):
        """Sign in and, if grace still allows it, perform the explicit restore.

        This models the product copy "signing in during grace cancels the
        deletion and restores the account": the sign-in is acknowledged first
        and restoration is the deliberate second step.
        """
        receipt = self.sign_in(claims)
        if not receipt.get('can_restore'):
            return receipt
        return self.restore(claims)

    # -- explicit cancellation / restore ---------------------------------

    def cancel_deletion(self, claims):
        """Cancel deletion after a recent, explicit, authenticated action."""
        result = self.lifecycle.cancel(claims)
        return self._receipt(result, restored=result.get('state') == 'cancelled')

    def cancel(self, claims):
        """Alias used by the existing ``POST /account/deletion/cancel`` route."""
        return self.cancel_deletion(claims)

    def restore(self, claims):
        """Product name for the explicit restore action."""
        return self.cancel_deletion(claims)

    # -- expiry worker ---------------------------------------------------

    def finalize(self, uid, *, scheduled=False):
        """Run the worker state machine for one UID."""
        return self._receipt(self.lifecycle.finalize(uid, scheduled=scheduled))

    def expire(self, uid):
        """Worker step: fence/hard-delete a UID whose deadline has passed."""
        return self.finalize(uid, scheduled=True)


#: Descriptive alias for callers that prefer the service spelling.
DeletionService = AccountDeletion


def sweep(service):
    """One expiry-worker sweep over the durable due list.

    The due list is advisory; ``expire`` re-reads the row under the UID lock
    and re-checks the deadline/retry time. Failures are counted and logged
    without UIDs or credential contents, and remain durable for a later sweep.
    """
    failed = 0
    for uid in service.store.due(service.clock()):
        try:
            service.expire(uid)
        except Exception:
            _log.error('Account cleanup failed; durable record will be retried')
            failed += 1
    return failed


def process_expired(service):
    """Alias for :func:`sweep` used by scheduler-style callers."""
    return sweep(service)


__all__ = [
    'AccountDeletion',
    'DeletionService',
    'GRACE_PERIOD',
    'GRACE_SECONDS',
    'PLAY_SUBSCRIPTION_MANAGEMENT_URL',
    'process_expired',
    'sweep',
]
