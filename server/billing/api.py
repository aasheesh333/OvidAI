"""HTTP surface: ``POST /billing/verify`` and ``POST /billing/rtdn``.

Mount on the live mint app (it owns Firebase ID-token / App Check verification
and the Redis tier key)::

    from server.billing.api import mount_billing
    billing = mount_billing(mint)          # reads OVID_* env, see README
    # in /usage: payload.update(billing.usage_fields(uid))

Nothing here grants a tier without a successful Google Play Developer API read.
"""
import base64
import hmac
import json
import logging
import os
import time
from datetime import datetime, timezone

from fastapi import Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from .domain import BillingError, evaluate
from .play import PlayDeveloperApi, service_account_token_provider
from .products import DEFAULT_PLAN_FEATURES, account_hash, load_products
from .store import PurchaseStore, RedisTierSink

_LOG = logging.getLogger(__name__)
DEFAULT_PACKAGE = 'com.dhanuk.ovidai'
MAX_TOKEN = 4096
# RTDN subscriptionNotification.notificationType 12 = SUBSCRIPTION_REVOKED.
REVOKED = 12


def _iso(epoch):
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace('+00:00', 'Z')


def _error(error):
    return JSONResponse({'ok': False, 'error': {'code': error.code}}, status_code=error.status,
                        headers={'Cache-Control': 'no-store'})


class BillingService:
    def __init__(self, *, api, store, products, set_tier, package_name,
                 verify_identity, verify_push, clock=time.time, require_account_id=True):
        self.api = api
        self.store = store
        self.products = products
        self.set_tier = set_tier
        self.package_name = package_name
        self.verify_identity = verify_identity
        self.verify_push = verify_push
        self.clock = clock
        self.require_account_id = require_account_id

    @property
    def configured(self):
        return self.api is not None and self.store is not None

    # ---- tier application -------------------------------------------------
    def _apply(self, uid):
        """Recompute the user's best active purchase and push it to mint."""
        if not uid:
            return 'free', None
        best = self.store.effective(uid, int(self.clock()))
        tier = best['tier'] if best else 'free'
        expires = best['expires_at'] if best else None
        self.set_tier(uid, tier, expires)
        return tier, best

    def usage_fields(self, uid):
        """Fields mint merges into its ``/usage`` JSON (see README)."""
        fields = {
            'billing_enabled': self.configured,
            'plans': [
                {'tier': tier, 'features': DEFAULT_PLAN_FEATURES.get(tier, []),
                 **({'product_id': next((p for p, t in self.products.items() if t == tier), None)}
                    if tier != 'free' else {})}
                for tier in ('free', '3x', '7x', '15x')
            ],
        }
        if self.configured and uid:
            best = self.store.effective(uid, int(self.clock()))
            if best:
                fields.update(plan_expires_at=_iso(best['expires_at']),
                              plan_auto_renews=best['auto_renewing'],
                              plan_product_id=best['product_id'])
        return fields

    # ---- POST /billing/verify --------------------------------------------
    def verify(self, uid, body):
        if not self.configured:
            raise BillingError(503, 'billing_unavailable')
        if not isinstance(body, dict):
            raise BillingError(400, 'invalid_request')
        token = body.get('purchase_token')
        product = body.get('product_id')
        package = body.get('package_name') or self.package_name
        if (not isinstance(token, str) or not token or len(token) > MAX_TOKEN
                or not isinstance(product, str)):
            raise BillingError(400, 'invalid_request')
        if package != self.package_name:
            raise BillingError(400, 'wrong_package')
        if product not in self.products:
            raise BillingError(400, 'unknown_product')
        existing = self.store.get(token)
        if existing and existing['uid'] and existing['uid'] != uid:
            raise BillingError(409, 'purchase_owned_by_another_account')
        resource = self.api.get_subscription(token)
        now = int(self.clock())
        entitlement = evaluate(resource, self.products, now)
        if entitlement.account_hash is None:
            if self.require_account_id:
                raise BillingError(403, 'account_mismatch')
        elif not hmac.compare_digest(entitlement.account_hash, account_hash(uid)):
            raise BillingError(403, 'account_mismatch')
        row = self.store.record(token, entitlement, now, uid=uid)
        tier, best = self._apply(uid)
        active = row['status'] == 'active'
        payload = {
            'ok': active,
            'status': row['status'],
            'tier': tier,
            'product_id': row['product_id'],
            'expires_at': _iso(best['expires_at']) if best else None,
            'auto_renewing': bool(best and best['auto_renewing']),
            # The client acknowledges (completePurchase) only when this is true.
            'acknowledge': active,
        }
        _LOG.info('billing.verify uid=%s product=%s status=%s tier=%s test=%s',
                  uid, row['product_id'], row['status'], tier, entitlement.test_purchase)
        return (202 if row['status'] == 'pending' else 200), payload

    # ---- POST /billing/rtdn ----------------------------------------------
    def notify(self, envelope):
        if not self.configured:
            raise BillingError(503, 'billing_unavailable')
        try:
            data = json.loads(base64.b64decode(envelope['message']['data']))
        except (KeyError, TypeError, ValueError):
            # Malformed pushes are acknowledged; redelivery cannot fix them.
            _LOG.warning('billing.rtdn malformed envelope')
            return
        if data.get('packageName') not in (None, self.package_name):
            _LOG.warning('billing.rtdn foreign package %s', data.get('packageName'))
            return
        now = int(self.clock())
        voided = data.get('voidedPurchaseNotification')
        if isinstance(voided, dict) and voided.get('purchaseToken'):
            row = self.store.mark(voided['purchaseToken'], 'revoked', now)
            if row:
                self._apply(row['uid'])
            return
        notification = data.get('subscriptionNotification')
        if not isinstance(notification, dict) or not notification.get('purchaseToken'):
            return  # testNotification / one-time products: nothing to do
        token = notification['purchaseToken']
        resource = self.api.get_subscription(token)  # 503 => Pub/Sub retries
        try:
            entitlement = evaluate(resource, self.products, now)
        except BillingError as error:
            _LOG.warning('billing.rtdn ignored token: %s', error.code)
            return
        row = self.store.record(token, entitlement, now)
        old_owner = None
        if entitlement.linked_token:
            linked = self.store.get(entitlement.linked_token)
            old_owner = linked and linked['uid']
        if notification.get('notificationType') == REVOKED:
            row = self.store.mark(token, 'revoked', now)
        _LOG.info('billing.rtdn type=%s status=%s', notification.get('notificationType'),
                  row['status'])
        # Unbound tokens (verify never reached us) are applied at /billing/verify.
        self._apply(row['uid'])
        if old_owner and old_owner != row['uid']:
            self._apply(old_owner)


def _mint_identity(mint):
    """Firebase ID token + App Check verification using mint's own primitives."""
    def verify(headers):
        authorization = headers.get('authorization', '')
        if not authorization.lower().startswith('bearer '):
            raise BillingError(401, 'sign_in_required')
        appcheck = headers.get('x-firebase-appcheck', '')
        try:
            if getattr(mint, 'APPCHECK_ENABLED', True):
                if not appcheck:
                    raise BillingError(401, 'sign_in_required')
                mint.verify_app_check(appcheck)
            claims = mint.verify_google_id_token(authorization.split(' ', 1)[1])
        except BillingError:
            raise
        except Exception:
            raise BillingError(401, 'sign_in_required') from None
        uid = claims.get('sub') if isinstance(claims, dict) else None
        if not uid:
            raise BillingError(401, 'sign_in_required')
        is_banned = getattr(mint, 'is_banned', None)
        if is_banned and is_banned(uid, 'unknown'):
            raise BillingError(403, 'account_blocked')
        return uid
    return verify


def pubsub_push_verifier(environ):
    """Authenticates Pub/Sub push requests.

    Preferred: OIDC push auth (``OVID_RTDN_AUDIENCE`` + ``OVID_RTDN_SERVICE_ACCOUNT``).
    Fallback: ``OVID_RTDN_SHARED_SECRET`` passed as ``?secret=`` in the push URL.
    With neither configured every push is refused (fail closed).
    """
    audience = environ.get('OVID_RTDN_AUDIENCE')
    account = environ.get('OVID_RTDN_SERVICE_ACCOUNT')
    secret = environ.get('OVID_RTDN_SHARED_SECRET')

    def verify(headers, query):
        if audience and account:
            authorization = headers.get('authorization', '')
            if not authorization.lower().startswith('bearer '):
                return False
            try:
                from google.auth.transport.requests import Request as GRequest  # lazy
                from google.oauth2 import id_token  # lazy
                claims = id_token.verify_oauth2_token(
                    authorization.split(' ', 1)[1], GRequest(), audience=audience)
            except Exception:
                return False
            return claims.get('email') == account and claims.get('email_verified') is True
        if secret:
            return hmac.compare_digest(query.get('secret', ''), secret)
        return False
    return verify


def build_service(mint, *, environ=None, api=None, store=None, set_tier=None,
                  verify_push=None, clock=time.time):
    environ = os.environ if environ is None else environ
    package = environ.get('OVID_PLAY_PACKAGE', DEFAULT_PACKAGE)
    if api is None and environ.get('OVID_PLAY_SERVICE_ACCOUNT_FILE'):
        api = PlayDeveloperApi(package, service_account_token_provider(
            environ['OVID_PLAY_SERVICE_ACCOUNT_FILE']))
    if store is None and api is not None:
        store = PurchaseStore(environ.get('OVID_BILLING_DB', '/data/ovid-billing.sqlite'))
    if set_tier is None:
        set_tier = getattr(mint, 'set_user_tier', None) or RedisTierSink(mint.rds)
    return BillingService(
        api=api, store=store, products=load_products(environ), set_tier=set_tier,
        package_name=package, verify_identity=_mint_identity(mint),
        verify_push=verify_push or pubsub_push_verifier(environ), clock=clock,
        require_account_id=environ.get('OVID_BILLING_REQUIRE_ACCOUNT_ID', 'true') != 'false')


def mount_billing(mint, app=None, **kwargs):
    """Registers the routes on ``app`` (default ``mint.app``); returns the service."""
    service = build_service(mint, **kwargs)
    target = app or mint.app

    async def verify(request: Request):
        try:
            uid = service.verify_identity({k.lower(): v for k, v in request.headers.items()})
            try:
                body = await request.json()
            except ValueError:
                raise BillingError(400, 'invalid_request') from None
            status, payload = await run_in_threadpool(service.verify, uid, body)
            return JSONResponse(payload, status_code=status, headers={'Cache-Control': 'no-store'})
        except BillingError as error:
            return _error(error)
        except Exception:
            _LOG.exception('billing.verify failed')
            return _error(BillingError(503, 'billing_unavailable'))

    async def rtdn(request: Request):
        if not service.verify_push({k.lower(): v for k, v in request.headers.items()},
                                   dict(request.query_params)):
            return Response(status_code=403)
        try:
            envelope = await request.json()
        except ValueError:
            return Response(status_code=204)
        try:
            await run_in_threadpool(service.notify, envelope)
        except BillingError as error:
            # Non-2xx makes Pub/Sub redeliver with backoff.
            return _error(error)
        except Exception:
            _LOG.exception('billing.rtdn failed')
            return Response(status_code=503)
        return Response(status_code=204)

    target.add_api_route('/billing/verify', verify, methods=['POST'])
    target.add_api_route('/billing/rtdn', rtdn, methods=['POST'])
    return service
