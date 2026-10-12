"""Budgeted active capability probes, run ONLY by the background worker.

Never on a user request path. One probe run at a time (global lock), tiny
synthetic inputs, a hard per-probe and daily spend cap, and a pass/fail result
that distinguishes "unsupported" (the model refused the operation) from
"transient" (timeout, 429, 5xx - says nothing about the capability, so the
capability is left as it was).
"""
import base64
import io
import statistics
import time
from dataclasses import dataclass
from threading import Lock

import httpx
from PIL import Image

from .capabilities import (DEFAULT_SIZE, cap, clone, finalize, merge_facts, ratio_of)
from . import costing
from .extraction import default_probe_sizes

UNSUPPORTED, TRANSIENT, AUTH, BUDGET, INCONCLUSIVE = 'unsupported', 'transient', 'auth', 'budget', 'inconclusive'
URL_RESPONSE = 'url_response'   # provider ignored response_format=b64_json and returned URLs
WARNINGS = {
    URL_RESPONSE: 'returns_urls: provider ignores response_format=b64_json and returns image URLs; the gateway never '
                  'fetches URLs, so this model is unusable until it supports b64_json',
    AUTH: 'probe_auth: the provider rejected the credential; check the model api_key in LiteLLM',
    BUDGET: 'probe_budget: provider or LiteLLM budget exhausted; top up, then POST /images/admin/reprobe',
    'daily_budget': 'probe_daily_budget: OVID_PROBE_DAILY_USD reached; probes resume when the 24h window frees up',
    'per_probe_cap': 'probe_per_probe_cap: a probe cost more than OVID_PROBE_MAX_USD; raise it or lower the model price',
    'estimate_exceeds_cap': 'probe_skipped: estimated probe cost exceeds OVID_PROBE_MAX_USD; raise it to probe this model',
}
_INCONCLUSIVE_WORDS = ('too small', 'at least', 'minimum', 'dimension', 'resolution too', 'must be larger')
_BUDGET_WORDS = ('insufficient_quota', 'insufficient quota', 'insufficient credit', 'insufficient funds',
                 'billing', 'exceeded your current quota', 'out of credits', 'payment required')
_POLICY_WORDS = ('content policy', 'content_policy', 'safety system', 'moderation', 'safety filter')
_UNSUPPORTED_WORDS = ('not support', 'unsupported', 'not available for', 'invalid size', 'unknown parameter',
                      'unrecognized', 'not a valid', 'does not allow', 'only supports')


@dataclass
class ProbeOutcome:
    ok: bool
    error_class: str | None = None
    latency_ms: int | None = None
    cost_usd: float | None = None
    images: tuple = ()          # decoded output image bytes
    cost_source: str | None = None


class ProbeBusy(Exception):
    pass


def sniff_format(raw):
    if raw.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'png'
    if raw.startswith(b'\xff\xd8\xff'):
        return 'jpeg'
    if raw[:4] == b'RIFF' and raw[8:12] == b'WEBP':
        return 'webp'
    return None


def decode_rows(rows):
    """Reply rows -> (images, error_class). URL replies and non-image payloads never become cards facts."""
    images = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            return (), TRANSIENT
        if not row.get('b64_json'):
            return (), (URL_RESPONSE if row.get('url') else TRANSIENT)
        try:
            raw = base64.b64decode(row['b64_json'], validate=True)
        except Exception:  # noqa: BLE001
            return (), INCONCLUSIVE
        if sniff_format(raw) is None:
            return (), INCONCLUSIVE
        images.append(raw)
    return tuple(images), None


def synthetic_png(size=64, alpha=False):
    out = io.BytesIO()
    if alpha:
        im = Image.new('RGBA', (size, size), (255, 0, 0, 255))
        for x in range(size // 2):
            for y in range(size):
                im.putpixel((x, y), (0, 0, 0, 0))
    else:
        im = Image.new('RGB', (size, size), (200, 60, 60))
    im.save(out, 'PNG')
    return out.getvalue()


def classify_error(status, text=''):
    lowered = (text or '').lower()
    if status in (401, 403):
        return AUTH
    if status == 402 or 'budget' in lowered or 'max_budget' in lowered or any(w in lowered for w in _BUDGET_WORDS):
        return BUDGET
    if any(w in lowered for w in _POLICY_WORDS) and status in (400, 422):
        return INCONCLUSIVE   # the probe prompt was refused, says nothing about capability
    if any(w in lowered for w in _INCONCLUSIVE_WORDS) and status in (400, 422):
        return INCONCLUSIVE
    if status in (400, 404, 405, 415, 422, 501):
        return UNSUPPORTED
    if any(w in lowered for w in _UNSUPPORTED_WORDS):
        return UNSUPPORTED
    return TRANSIENT   # 408/409/425/429/5xx/anything else: no verdict


_DIRECT_UNSUPPORTED_CODES = ('not_an_image_model', 'unsupported_modality')


def classify_direct_error(status, response):
    """Direct JSON edit probe verdict. Only the provider's documented structured
    "this model cannot read images" codes prove a capability absent; any other
    format/validation 400 (e.g. a malformed probe) is inconclusive."""
    try:
        error = response.json().get('error')
        code = error.get('code') if isinstance(error, dict) else None
    except Exception:  # noqa: BLE001
        code = None
    if status == 400 and code in _DIRECT_UNSUPPORTED_CODES:
        return UNSUPPORTED
    verdict = classify_error(status, '' if status == 400 else response.text[:2000])
    return INCONCLUSIVE if verdict == UNSUPPORTED else verdict


class LiteLLMProbeTransport:
    """Real transport: LiteLLM /v1/images/* with the dedicated probe key."""

    def __init__(self, base_url, probe_key, *, master_key=None, timeout=90, spend_wait=4.0, client_factory=None,
                 direct=None, params_for=None):
        self.base_url, self.key, self.master_key = base_url, probe_key, master_key
        # Direct JSON edit path (same transport the gateway uses for user edits).
        self.direct, self.params_for = direct, params_for
        self.timeout, self.spend_wait = timeout, spend_wait
        self.client_factory = client_factory or (lambda **kw: httpx.Client(**kw))

    def _prices(self, client, model):
        def fetch():
            r = client.get('/model/info', headers={'Authorization': f'Bearer {self.master_key or self.key}'})
            if r.status_code != 200:
                raise RuntimeError('model/info unavailable')
            return costing.parse_model_info(r.json())
        book = self.__dict__.setdefault('_pricebook', costing.PriceBook(fetch, ttl=300.0))
        book._fetch = fetch   # the pooled client is per-call; keep the cache, rebind the fetcher
        return book.get(model)

    def _spend(self, client):
        try:
            r = client.get('/key/info', params={'key': self.key},
                           headers={'Authorization': f'Bearer {self.master_key or self.key}'})
            if r.status_code == 200:
                return float(r.json().get('info', {}).get('spend') or 0.0)
        except Exception:  # noqa: BLE001
            pass
        return None

    @property
    def edit_cost(self):
        return float(self.direct.edit_cost) if self.direct is not None and self.direct.edit_cost else None

    def _direct_edit(self, model, params):
        started = time.monotonic()
        lookup = (self.params_for(model) if self.params_for else None) or {}
        if self.direct is None or not self.direct.enabled_for(lookup):
            return ProbeOutcome(False, INCONCLUSIVE, 0, 0.0)
        data_url = 'data:image/png;base64,' + base64.b64encode(params['images'][0]).decode()
        try:
            r = self.direct.post(lookup, params['prompt'], params['size'], data_url)
        except httpx.HTTPError:
            return ProbeOutcome(False, TRANSIENT, int((time.monotonic() - started) * 1000), 0.0)
        latency = int((time.monotonic() - started) * 1000)
        if r.status_code != 200:
            return ProbeOutcome(False, classify_direct_error(r.status_code, r), latency, 0.0)
        try:
            body = r.json()
            images, bad = decode_rows(body.get('data') or [])
        except Exception:  # noqa: BLE001
            return ProbeOutcome(False, TRANSIENT, latency, float(self.direct.edit_cost or 0))
        if bad:
            return ProbeOutcome(False, bad, latency, float(self.direct.edit_cost or 0))
        cost = float(self.direct.settlement_cost(body, self.direct.edit_cost))
        if not images:
            return ProbeOutcome(False, TRANSIENT, latency, cost)
        return ProbeOutcome(True, None, latency, cost, images)

    def call(self, model, kind, params):
        if kind == 'edit' and params.get('direct'):
            return self._direct_edit(model, params)
        headers = {'Authorization': f'Bearer {self.key}'}
        with self.client_factory(base_url=self.base_url, timeout=self.timeout, follow_redirects=False) as client:
            before = self._spend(client)
            started = time.monotonic()
            try:
                if kind == 'generate':
                    body = {'model': model, 'prompt': params['prompt'], 'size': params['size'],
                            'n': params.get('n', 1), 'response_format': 'b64_json'}
                    if params.get('background'):
                        body['background'] = params['background']
                    r = client.post('/v1/images/generations', headers=headers, json=body)
                else:
                    data = {'model': model, 'prompt': params['prompt'], 'size': params['size'], 'n': '1'}
                    images = params['images']
                    name = 'image[]' if len(images) > 1 else 'image'
                    files = [(name, (f'in{i}.png', raw, 'image/png')) for i, raw in enumerate(images)]
                    if params.get('mask'):
                        files.append(('mask', ('mask.png', params['mask'], 'image/png')))
                    r = client.post('/v1/images/edits', headers=headers, data=data, files=files)
            except httpx.HTTPError:
                return ProbeOutcome(False, TRANSIENT, int((time.monotonic() - started) * 1000))
            latency = int((time.monotonic() - started) * 1000)
            if r.status_code != 200:
                return ProbeOutcome(False, classify_error(r.status_code, r.text[:2000]), latency)
            try:
                usage = r.json().get('usage')
            except Exception:  # noqa: BLE001
                usage = None
            cost, source = costing.determine_cost(
                headers=r.headers, usage=usage, prices=lambda: self._prices(client, model),
                spend_before=before, spend_read=lambda: self._spend(client),
                spend_wait=self.spend_wait, spend_poll=0.5)
            cost = float(cost) if cost is not None else None
            try:
                images, bad = decode_rows(r.json().get('data') or [])
            except Exception:  # noqa: BLE001
                return ProbeOutcome(False, TRANSIENT, latency, cost, cost_source=source)
            if bad or not images:
                return ProbeOutcome(False, bad or TRANSIENT, latency, cost, cost_source=source)
            return ProbeOutcome(True, None, latency, cost, images, cost_source=source)


def _has_alpha(raw):
    try:
        with Image.open(io.BytesIO(raw)) as im:
            if 'A' not in im.getbands():
                return False
            return im.getchannel('A').getextrema()[0] < 255
    except Exception:  # noqa: BLE001
        return False


class ProbeRunner:
    _lock = Lock()   # concurrency 1 across every runner in the process

    def __init__(self, transport, store, *, per_probe_cap=0.50, daily_cap=5.00, max_sizes=4,
                 estimated_cost=0.05, clock=time.time):
        self.transport, self.store, self.clock = transport, store, clock
        self.per_probe_cap, self.daily_cap = float(per_probe_cap), float(daily_cap)
        self.max_sizes, self.estimated_cost = int(max_sizes), float(estimated_cost)

    def run(self, card, facts=None):
        """Probe `card['model']`; returns (new_card, summary). Never raises on
        provider failure. Raises ProbeBusy when another run is in progress."""
        if not self._lock.acquire(blocking=False):
            raise ProbeBusy()
        try:
            return self._run(card, facts or {})
        finally:
            self._lock.release()

    # -- internals -------------------------------------------------------
    def _run(self, card, facts):
        model = card['model']
        card = clone(card)
        ctx = {'spent': 0.0, 'stop': None, 'results': [], 'latencies': [], 'costs': [], 'warnings': [],
               'header_seen': False, 'formats': []}
        known_cost = facts.get('measured_cost_usd') or card.get('measured_cost_usd')
        est = known_cost or self.estimated_cost
        if known_cost and known_cost > self.per_probe_cap:
            # LiteLLM already says a single call costs more than the per-probe cap: do not even try.
            card['probe_warnings'] = [WARNINGS['estimate_exceeds_cap']]
            card['probed_at'] = int(self.clock())
            card['probe_stop'] = 'estimate_exceeds_cap'
            finalize(card)
            return card, {'spent': 0.0, 'stop': 'estimate_exceeds_cap', 'incomplete': True, 'transient': False}
        day_start = self.clock() - 24 * 3600

        def attempt(name, kind, **params):
            if ctx['stop']:
                return None
            est_here = est
            if params.get('direct'):
                flat = getattr(self.transport, 'edit_cost', None)
                if flat:
                    if flat > self.per_probe_cap:
                        return None            # strict cap: never spend above the per-probe limit
                    est_here = flat
            if self.store.spent_since(day_start) + est_here > self.daily_cap:
                ctx['stop'] = 'daily_budget'
                return None
            out = self.transport.call(model, kind, params)
            cost = out.cost_usd if out.cost_usd is not None else (est_here if out.ok else 0.0)
            ctx['spent'] += cost
            self.store.log_probe(model, name, out.ok, out.error_class, out.latency_ms, cost)
            ctx['results'].append({'probe': name, 'ok': out.ok, 'error_class': out.error_class,
                                   'latency_ms': out.latency_ms, 'cost_usd': round(cost, 6),
                                   'at': int(self.clock())})
            if out.cost_usd is not None and out.cost_usd > self.per_probe_cap:
                ctx['stop'] = 'per_probe_cap'
            if out.error_class in (AUTH, BUDGET):
                ctx['stop'] = out.error_class
            if out.error_class == URL_RESPONSE:
                ctx['warnings'].append(WARNINGS[URL_RESPONSE])
            if getattr(out, 'cost_source', None) == costing.HEADER:
                ctx['header_seen'] = True
            return out

        def verdict(out):
            """True / False / None(no verdict)."""
            if out is None or out.error_class in (TRANSIENT, INCONCLUSIVE, AUTH, BUDGET):
                return None
            return out.ok

        png = synthetic_png()
        ops = {}
        # 1+2: generate at default size, then the other candidate sizes (bounded).
        candidates = default_probe_sizes(facts, self.max_sizes)
        passed_sizes, gen_verdicts = [], []
        for size in candidates:
            out = attempt(f'generate:{size}', 'generate', prompt='a small red circle on white', size=size)
            gen_verdicts.append(verdict(out))
            if out is not None and out.ok:
                ctx['formats'].extend(f for f in (sniff_format(i) for i in out.images) if f)
                passed_sizes.append(size)
                ctx['latencies'].append(out.latency_ms)
                if out.cost_usd:
                    ctx['costs'].append(out.cost_usd)
            if ctx['stop']:
                break
        generate_ok = True if passed_sizes else (False if gen_verdicts and all(v is False for v in gen_verdicts) else None)
        if generate_ok is not None:
            ops['generate'] = cap(generate_ok, 'probed', 0.9)
        sizes_fact = None
        if passed_sizes and not any(v is None for v in gen_verdicts):
            sizes_fact = {'native': passed_sizes, 'source': 'probed', 'confidence': 0.9,
                          'aspect_ratios': sorted({ratio_of(s) for s in passed_sizes if ratio_of(s)})}
        elif passed_sizes:   # some sizes inconclusive: keep the proven ones plus what static said
            known = list((card.get('sizes') or {}).get('native') or [])
            sizes_fact = {'native': passed_sizes + [s for s in known if s not in passed_sizes],
                          'source': 'probed', 'confidence': 0.6,
                          'aspect_ratios': sorted({ratio_of(s) for s in passed_sizes + known if ratio_of(s)})}
        size = passed_sizes[0] if passed_sizes else DEFAULT_SIZE

        if generate_ok is not False:
            # 3: edit
            transport = card.get('edit_transport')
            direct = transport == 'direct'
            edit_v = None
            if transport != 'none':   # 'none': edits are unavailable by configuration, nothing to probe
                out = attempt('edit', 'edit', prompt='make the square blue', size=size, images=[png], direct=direct)
                edit_v = verdict(out)
            if edit_v is not None:
                ops['edit'] = cap(edit_v, 'probed', 0.9)
            if edit_v is False:
                for dependent in ('inpaint', 'outpaint', 'multi_image', 'reference_style', 'remove_background'):
                    ops[dependent] = cap(False, 'probed', 0.6)
            elif edit_v and not direct:
                # (direct JSON edits have no mask/extra-image contract: nothing to probe)
                out = attempt('inpaint', 'edit', prompt='fill the transparent area with green', size=size,
                              images=[png], mask=synthetic_png(alpha=True))
                inpaint_v = verdict(out)
                if inpaint_v is not None:
                    ops['inpaint'] = cap(inpaint_v, 'probed', 0.85)
                    ops['outpaint'] = cap(inpaint_v, 'inferred', 0.5)
                out = attempt('multi_image', 'edit', prompt='combine both images', size=size,
                              images=[png, synthetic_png(alpha=True)])
                multi_v = verdict(out)
                if multi_v is not None:
                    ops['multi_image'] = cap(multi_v, 'probed', 0.85, max_inputs=2 if multi_v else 0)
                    ops['reference_style'] = cap(multi_v, 'inferred', 0.5)
            # 4: transparent output
            out = attempt('transparent', 'generate', prompt='a red circle, transparent background', size=size,
                          background='transparent')
            if out is not None and out.ok:
                has_alpha = _has_alpha(out.images[0])
                ops['transparent_output'] = cap(has_alpha, 'probed', 0.8)
                if has_alpha and edit_v and not direct:
                    ops['remove_background'] = cap(True, 'inferred', 0.5)
            elif verdict(out) is False:
                ops['transparent_output'] = cap(False, 'probed', 0.7)
            # 5: variations (n=2)
            out = attempt('variations', 'generate', prompt='a red circle', size=size, n=2)
            if out is not None and out.ok:
                many = len(out.images) >= 2
                ops['variations'] = cap(many, 'probed', 0.8, max_n=2 if many else 1)
            elif verdict(out) is False:
                ops['variations'] = cap(False, 'probed', 0.7)
            # 6: text-in-image smoke test (no OCR: a pass only proves it runs)
            attempt('text', 'generate', prompt='A poster with the exact word "OVID" in large letters', size=size)

        new = {'operations': ops}
        formats = []
        for r_ in ctx['formats']:
            if r_ not in formats:
                formats.append(r_)
        if formats:
            new['output_formats'] = formats
        if sizes_fact:
            new['sizes'] = sizes_fact
        if ctx['latencies']:
            new['latency_ms_p50'] = int(statistics.median(ctx['latencies']))
        if ctx['costs']:
            new['measured_cost_usd'] = statistics.median(ctx['costs'])
        if ops.get('variations', {}).get('supported'):
            new['max_n'] = 2
        merge_facts(card, new)
        # Probed values override even a higher-confidence static guess.
        for op, rec in ops.items():
            card['operations'][op] = {**card['operations'].get(op, {}), **rec}
        text_pass = next((r for r in ctx['results'] if r['probe'] == 'text'), None)
        if text_pass and text_pass['ok'] and (card.get('text_rendering') or {}).get('source') != 'inferred':
            card['text_rendering'] = {'level': 'ok', 'source': 'probed', 'confidence': 0.3}
        core = [r for r in ctx['results'] if r['probe'].startswith('generate:') or r['probe'] == 'edit']
        incomplete = ctx['stop'] is not None or any(r['error_class'] in (TRANSIENT, INCONCLUSIVE) for r in core) \
            or generate_ok is None
        card['probes'] = ctx['results']
        card['probed_at'] = int(self.clock())
        card['state'] = 'inferred' if incomplete or generate_ok is False else 'probed'
        card['probe_stop'] = ctx['stop']
        if ctx['header_seen']:
            card['cost_header_seen'] = True
        if ctx['stop'] in WARNINGS:
            ctx['warnings'].append(WARNINGS[ctx['stop']])
        card['probe_warnings'] = list(dict.fromkeys(ctx['warnings']))
        finalize(card)
        summary = {'spent': ctx['spent'], 'stop': ctx['stop'], 'incomplete': incomplete,
                   'transient': any(r['error_class'] == TRANSIENT for r in ctx['results'])}
        return card, summary
