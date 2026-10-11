"""Minimal Google Play Developer API client (subscriptionsv2.get only).

Authentication uses a service account with the "View financial data, orders
and cancellation survey responses" + "Manage orders and subscriptions"
permissions in Play Console. ``google-auth`` is imported lazily so tests (and
hosts that inject ``token_provider``) do not need it.
"""
import threading
import time
from urllib.parse import quote

import httpx

from .domain import BillingError

API_BASE = 'https://androidpublisher.googleapis.com'
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'


def service_account_token_provider(credentials_file):
    """Returns a thread-safe callable yielding a fresh OAuth access token."""
    from google.auth.transport.requests import Request  # lazy
    from google.oauth2 import service_account  # lazy

    credentials = service_account.Credentials.from_service_account_file(
        credentials_file, scopes=[SCOPE])
    lock = threading.Lock()

    def token():
        with lock:
            if not credentials.valid:
                credentials.refresh(Request())
            return credentials.token
    return token


class PlayDeveloperApi:
    def __init__(self, package_name, token_provider, client=None, retries=2):
        self.package_name = package_name
        self._token = token_provider
        self._client = client or httpx.Client(base_url=API_BASE, timeout=15)
        self._retries = retries

    def get_subscription(self, purchase_token):
        """GET purchases.subscriptionsv2 for ``purchase_token``.

        Raises BillingError(400, 'purchase_invalid') when Google does not know
        the token (forged/foreign package) and BillingError(503,
        'play_unavailable') for transient failures; callers must not grant or
        acknowledge on either.
        """
        path = (f'/androidpublisher/v3/applications/{quote(self.package_name, safe="")}'
                f'/purchases/subscriptionsv2/tokens/{quote(purchase_token, safe="")}')
        last = None
        for attempt in range(self._retries + 1):
            try:
                response = self._client.get(
                    path, headers={'Authorization': f'Bearer {self._token()}'})
            except httpx.HTTPError as error:
                last = error
            else:
                if response.status_code == 200:
                    try:
                        return response.json()
                    except ValueError:
                        raise BillingError(502, 'play_invalid_response') from None
                if response.status_code in (400, 404, 410):
                    raise BillingError(400, 'purchase_invalid')
                if response.status_code in (401, 403):
                    # Misconfigured service account: an operator problem.
                    raise BillingError(503, 'play_auth_failed')
                last = response.status_code
            if attempt < self._retries:
                time.sleep(0.2 * (2 ** attempt))
        raise BillingError(503, 'play_unavailable') from (
            last if isinstance(last, Exception) else None)
