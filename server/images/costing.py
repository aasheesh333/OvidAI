"""Provider-agnostic upstream cost determination for image calls (pure, no I/O of its own).

Priority (first positive, finite, bounded value wins):
  1. ``x-litellm-response-cost`` response header (synchronous, LiteLLM-priced).
  2. Tokens from the reply ``usage`` x the model's LiteLLM ``model_info`` prices:
       input_tokens*input_cost_per_token + output_tokens*output_cost_per_token
     (``prompt_tokens``/``completion_tokens`` accepted as aliases). If tokens are
     absent: n*(input_cost_per_image + output_cost_per_image).
  3. Key-spend delta (after - before), re-read with a bounded delay because
     LiteLLM batches spend writes.
  4. None -> caller keeps the reservation for reconciliation. Never fabricate.
Every source is capped at ``bound``; NaN/inf/negative/zero/huge/bool are rejected.
"""
import math
import threading
import time
from decimal import Decimal, InvalidOperation

from .service import ImageError, money

SANITY_MAX = Decimal('1000')          # absolute ceiling when no bound is given
MAX_TOKENS = 10_000_000               # per direction; anything larger is garbage
HEADER, TOKENS, SPEND_DELTA = 'header', 'tokens', 'spend_delta'
COST_HEADER = 'x-litellm-response-cost'


def _dec(value):
    """Untrusted scalar -> finite non-negative Decimal, else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str, Decimal)):
        return None
    try:
        if isinstance(value, float) and not math.isfinite(value):
            return None
        out = Decimal(str(value).strip())
        if not out.is_finite() or out < 0:
            return None
        return money(out)
    except (InvalidOperation, ValueError, ImageError):
        return None


def positive_cost(value, bound=None):
    """Positive finite money capped at ``bound`` (or rejected above SANITY_MAX), else None."""
    out = _dec(value)
    if out is None or out <= 0:
        return None
    if bound is None:
        return out if out <= SANITY_MAX else None
    return min(out, Decimal(str(bound)))


def header_cost(headers, bound=None):
    try:
        raw = headers.get(COST_HEADER) if headers is not None else None
    except Exception:  # noqa: BLE001
        return None
    return positive_cost(raw, bound)


def normalize_prices(info):
    """model_info dict -> {name: Decimal} of the usable, positive price fields."""
    out = {}
    if isinstance(info, dict):
        for name in ('input_cost_per_token', 'output_cost_per_token',
                     'input_cost_per_image', 'output_cost_per_image'):
            value = _dec(info.get(name))
            if value is not None and value > 0 and value <= Decimal('1'):
                out[name] = value
    return out


def _tokens(usage, *names):
    for name in names:
        raw = usage.get(name)
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            continue
        if isinstance(raw, float) and not math.isfinite(raw):
            continue
        if 0 <= raw <= MAX_TOKENS:
            return int(raw)
    return None


def token_cost(usage, prices, n=1, bound=None):
    """Token formula; per-image formula only when the reply has no token counts."""
    if not prices:
        return None
    usage = usage if isinstance(usage, dict) else {}
    tin = _tokens(usage, 'input_tokens', 'prompt_tokens')
    tout = _tokens(usage, 'output_tokens', 'completion_tokens')
    zero = Decimal(0)
    if tin or tout:
        total = ((tin or 0) * prices.get('input_cost_per_token', zero)
                 + (tout or 0) * prices.get('output_cost_per_token', zero))
    else:
        count = n if isinstance(n, int) and not isinstance(n, bool) and 0 < n <= 64 else 1
        total = count * (prices.get('input_cost_per_image', zero) + prices.get('output_cost_per_image', zero))
    return positive_cost(total, bound)


def spend_delta_cost(before, after, bound=None):
    if before is None or after is None:
        return None
    try:
        if not (math.isfinite(before) and math.isfinite(after)) or after <= before:
            return None
        return positive_cost(str(Decimal(str(after)) - Decimal(str(before))), bound)
    except (InvalidOperation, ValueError, TypeError):
        return None


def determine_cost(*, headers=None, usage=None, prices=None, n=1, spend_before=None,
                   spend_read=None, spend_wait=0.0, spend_poll=0.5, sleep=time.sleep, bound=None):
    """Return (Decimal cost, source) or (None, None). ``prices`` may be a dict or a callable."""
    cost = header_cost(headers, bound)
    if cost is not None:
        return cost, HEADER
    if callable(prices):
        try:
            prices = prices()
        except Exception:  # noqa: BLE001
            prices = None
    cost = token_cost(usage, prices, n, bound)
    if cost is not None:
        return cost, TOKENS
    if spend_before is not None and spend_read is not None:
        waited = 0.0
        while True:
            cost = spend_delta_cost(spend_before, spend_read(), bound)
            if cost is not None:
                return cost, SPEND_DELTA
            if waited >= spend_wait:
                return None, None
            step = min(max(spend_poll, 0.01), spend_wait - waited)
            sleep(step)
            waited += step
    return None, None


class PriceBook:
    """In-memory TTL cache of per-model prices. ``fetch()`` -> {model_name: model_info dict}.

    Cold/miss: synchronous refresh (rate limited by ``miss_interval``). Stale hit:
    served immediately while a background thread refreshes. Fetch errors keep the
    previous data.
    """

    def __init__(self, fetch, ttl=300.0, miss_interval=30.0, clock=time.monotonic, background=True):
        self._fetch, self.ttl, self.miss_interval = fetch, ttl, miss_interval
        self._clock, self._background = clock, background
        self._data, self._at, self._tried = {}, None, None
        self._lock, self._refreshing = threading.Lock(), False

    def _refresh(self):
        self._tried = self._clock()
        try:
            fresh = self._fetch()
        except Exception:  # noqa: BLE001
            return
        if isinstance(fresh, dict):
            with self._lock:
                self._data = {k: normalize_prices(v) for k, v in fresh.items()}
                self._at = self._clock()

    def _refresh_bg(self):
        try:
            self._refresh()
        finally:
            self._refreshing = False

    def get(self, model):
        now = self._clock()
        stale = self._at is None or now - self._at >= self.ttl
        have = self._data.get(model)
        if have and not stale:
            return have
        if have and stale:
            if self._background and not self._refreshing:
                self._refreshing = True
                threading.Thread(target=self._refresh_bg, daemon=True).start()
            elif not self._background:
                self._refresh()
            return self._data.get(model) or have
        if self._tried is None or now - self._tried >= self.miss_interval:
            self._refresh()
        return self._data.get(model)


def parse_model_info(payload):
    """GET /model/info JSON -> {model_name: model_info} (first deployment with a price wins)."""
    out = {}
    rows = payload.get('data') if isinstance(payload, dict) else None
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict) or not isinstance(row.get('model_name'), str):
            continue
        info = row.get('model_info')
        if row['model_name'] not in out or (normalize_prices(info) and not normalize_prices(out[row['model_name']])):
            out[row['model_name']] = info
    return out
