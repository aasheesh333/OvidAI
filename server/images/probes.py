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
from .extraction import default_probe_sizes

UNSUPPORTED, TRANSIENT, AUTH, BUDGET, INCONCLUSIVE = 'unsupported', 'transient', 'auth', 'budget', 'inconclusive'
_INCONCLUSIVE_WORDS = ('too small', 'at least', 'minimum', 'dimension', 'resolution too', 'must be larger')
_UNSUPPORTED_WORDS = ('not support', 'unsupported', 'not available for', 'invalid size', 'unknown parameter',
                      'unrecognized', 'not a valid', 'does not allow', 'only supports')


@dataclass
class ProbeOutcome:
    ok: bool
    error_class: str | None = None
    latency_ms: int | None = None
    cost_usd: float | None = None
    images: tuple = ()          # decoded output image bytes


class ProbeBusy(Exception):
    pass


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
    if status == 402 or 'budget' in lowered or 'max_budget' in lowered:
        return BUDGET
    if any(w in lowered for w in _INCONCLUSIVE_WORDS) and status in (400, 422):
        return INCONCLUSIVE
    if status in (400, 404, 405, 415, 422, 501):
        return UNSUPPORTED
    if any(w in lowered for w in _UNSUPPORTED_WORDS):
        return UNSUPPORTED
    return TRANSIENT   # 408/409/425/429/5xx/anything else: no verdict


class LiteLLMProbeTransport:
    """Real transport: LiteLLM /v1/images/* with the dedicated probe key."""

    def __init__(self, base_url, probe_key, *, master_key=None, timeout=90, spend_wait=4.0, client_factory=None):
        self.base_url, self.key, self.master_key = base_url, probe_key, master_key
        self.timeout, self.spend_wait = timeout, spend_wait
        self.client_factory = client_factory or (lambda **kw: httpx.Client(**kw))

    def _spend(self, client):
        try:
            r = client.get('/key/info', params={'key': self.key},
                           headers={'Authorization': f'Bearer {self.master_key or self.key}'})
            if r.status_code == 200:
                return float(r.json().get('info', {}).get('spend') or 0.0)
        except Exception:  # noqa: BLE001
            pass
        return None

    def call(self, model, kind, params):
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
            cost = None
            header = r.headers.get('x-litellm-response-cost')
            try:
                cost = float(header) if header else None
            except ValueError:
                cost = None
            if cost is None and before is not None:
                deadline = time.monotonic() + self.spend_wait
                while True:
                    after = self._spend(client)
                    if after is not None and after > before:
                        cost = after - before
                        break
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(0.5)
            try:
                rows = r.json().get('data') or []
                images = tuple(base64.b64decode(row['b64_json']) for row in rows)
            except Exception:  # noqa: BLE001
                return ProbeOutcome(False, TRANSIENT, latency, cost)
            if not images:
                return ProbeOutcome(False, TRANSIENT, latency, cost)
            return ProbeOutcome(True, None, latency, cost, images)


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
        ctx = {'spent': 0.0, 'stop': None, 'results': [], 'latencies': [], 'costs': []}
        est = facts.get('measured_cost_usd') or card.get('measured_cost_usd') or self.estimated_cost
        day_start = self.clock() - 24 * 3600

        def attempt(name, kind, **params):
            if ctx['stop']:
                return None
            if self.store.spent_since(day_start) + est > self.daily_cap:
                ctx['stop'] = 'daily_budget'
                return None
            out = self.transport.call(model, kind, params)
            cost = out.cost_usd if out.cost_usd is not None else (est if out.ok else 0.0)
            ctx['spent'] += cost
            self.store.log_probe(model, name, out.ok, out.error_class, out.latency_ms, cost)
            ctx['results'].append({'probe': name, 'ok': out.ok, 'error_class': out.error_class,
                                   'latency_ms': out.latency_ms, 'cost_usd': round(cost, 6),
                                   'at': int(self.clock())})
            if out.cost_usd is not None and out.cost_usd > self.per_probe_cap:
                ctx['stop'] = 'per_probe_cap'
            if out.error_class in (AUTH, BUDGET):
                ctx['stop'] = out.error_class
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
            out = attempt('edit', 'edit', prompt='make the square blue', size=size, images=[png])
            edit_v = verdict(out)
            if edit_v is not None:
                ops['edit'] = cap(edit_v, 'probed', 0.9)
            if edit_v is False:
                for dependent in ('inpaint', 'outpaint', 'multi_image', 'reference_style', 'remove_background'):
                    ops[dependent] = cap(False, 'probed', 0.6)
            elif edit_v:
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
                if has_alpha and edit_v:
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
        finalize(card)
        summary = {'spent': ctx['spent'], 'stop': ctx['stop'], 'incomplete': incomplete,
                   'transient': any(r['error_class'] == TRANSIENT for r in ctx['results'])}
        return card, summary
