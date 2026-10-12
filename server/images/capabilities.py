"""Versioned image-model capability cards (pure data, no I/O).

A card describes what ONE LiteLLM image model can do. It is filled
automatically (static extraction + background probes, see extraction.py and
probes.py); nobody edits it by hand. The *private* card carries internal
model names, measured cost and probe results for the owner. The *public* card
is the only projection that crosses the API boundary: stable opaque slug, ops,
sizes, tiers - never a provider name, base URL or price.
"""
import copy
import hashlib
import json
import re

SCHEMA = 1
PUBLIC_SCHEMA = 2
ALIAS = 'ovid-image'

# Every operation a card can advertise. `generate`/`edit` are the two the
# gateway endpoints exist for; the rest are refinements of an edit/generate call.
OPERATIONS = ('generate', 'edit', 'inpaint', 'outpaint', 'reference_style', 'multi_image',
              'remove_background', 'transparent_output', 'upscale', 'variations')
SOURCES = ('declared', 'inferred', 'probed')
DEFAULT_SIZE = '1024x1024'
COST_TIERS = ('low', 'med', 'high')
TEXT_LEVELS = ('none', 'ok', 'good')
SIZE_RE = re.compile(r'^([1-9][0-9]{2,3})x([1-9][0-9]{2,3})$')


def fingerprint(model, params=None):
    """Hash of the model name + the litellm_params that decide what it is."""
    params = params or {}
    material = {'model': model,
                'litellm_model': params.get('model') or '',
                'api_base': (params.get('api_base') or '').rstrip('/'),
                'provider': params.get('custom_llm_provider') or ''}
    if params.get('edit_transport'):   # direct-json | none: toggling must re-extract + re-probe
        material['edit_transport'] = params['edit_transport']
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def slug_for(model):
    """Stable, opaque public slug. Derived from the model name, so it survives
    restarts and card rewrites, and reveals nothing about the provider."""
    return f'{ALIAS}:img-' + hashlib.sha256(('ovid-slug|' + model).encode()).hexdigest()[:6]


def cap(supported=None, source='inferred', confidence=0.5, **extra):
    """One capability record. supported: True / False / None (unknown)."""
    return {'supported': supported, 'source': source, 'confidence': round(confidence, 2), **extra}


def ratio_of(size):
    match = SIZE_RE.match(size)
    if not match:
        return None
    w, h = int(match[1]), int(match[2])
    from math import gcd
    g = gcd(w, h)
    return f'{w // g}:{h // g}'


def default_card(model, fp=None):
    """Conservative card used until extraction/probing has produced a real one:
    generate-only at 1024x1024. Never assumes edit support."""
    ops = {op: cap(False, 'inferred', 0.3) for op in OPERATIONS}
    ops['generate'] = cap(True, 'inferred', 0.6)
    return {
        'schema': SCHEMA, 'model': model, 'slug': slug_for(model), 'fingerprint': fp or fingerprint(model),
        'state': 'default', 'operations': ops,
        'sizes': {'native': [DEFAULT_SIZE], 'aspect_ratios': ['1:1'], 'source': 'inferred', 'confidence': 0.4},
        'max_n': 1,
        'input': {'max_images': 0, 'max_bytes': 16 * 1024 * 1024, 'max_pixels': 4096 * 4096,
                  'formats': ['png', 'jpeg', 'webp']},
        'output_formats': ['png'],
        'text_rendering': {'level': 'none', 'source': 'inferred', 'confidence': 0.2},
        'latency_ms_p50': None, 'cost_tier': 'med', 'measured_cost_usd': None, 'quality': 'med',
        'tags': [], 'probed_at': None, 'static': {}, 'probes': [],
    }


def supports(card, op):
    record = card['operations'].get(op)
    return bool(record and record.get('supported') is True)


def max_inputs(card):
    record = card['operations'].get('multi_image') or {}
    if record.get('supported') is True:
        return int(record.get('max_inputs') or 2)
    return 1 if supports(card, 'edit') else 0


def derive_tags(card, cost_tier=None):
    tags = []
    latency = card.get('latency_ms_p50')
    if latency is not None and latency <= 8000:
        tags.append('fast')
    if card.get('quality') == 'high':
        tags.append('quality')
    if (cost_tier or card.get('cost_tier')) == 'low':
        tags.append('cheap')
    if (card.get('text_rendering') or {}).get('level') == 'good':
        tags.append('text')
    if supports(card, 'edit'):
        tags.append('editor')
    if supports(card, 'transparent_output'):
        tags.append('transparent')
    return tags


def assign_cost_tiers(cards):
    """Relative tiers from measured/static cost. Exact money never leaves."""
    costs = sorted(c['measured_cost_usd'] for c in cards if c.get('measured_cost_usd'))
    if not costs:
        return
    median = costs[len(costs) // 2]
    for card in cards:
        cost = card.get('measured_cost_usd')
        if not cost:
            continue
        card['cost_tier'] = 'low' if cost <= median * 0.6 else 'high' if cost >= median * 1.8 else 'med'
    if len(costs) == 1:
        for card in cards:
            if card.get('measured_cost_usd'):
                card['cost_tier'] = 'med'


def finalize(card):
    card['tags'] = derive_tags(card)
    return card


def merge_facts(card, facts, *, rank=None):
    """Overlay `facts` (partial card) onto `card`. A fact never downgrades a
    higher-trust source: probed > declared > inferred."""
    order = {'inferred': 0, 'declared': 1, 'probed': 2}
    for op, record in (facts.get('operations') or {}).items():
        old = card['operations'].get(op)
        if old and order.get(old['source'], 0) > order.get(record['source'], 0) and old.get('supported') is not None:
            continue
        card['operations'][op] = {**(old or {}), **record}
    for key in ('sizes', 'text_rendering'):
        new = facts.get(key)
        old = card.get(key) or {}
        if new and order.get(old.get('source'), -1) <= order.get(new.get('source'), 0):
            card[key] = {**old, **new}
    for key in ('max_n', 'output_formats', 'latency_ms_p50', 'measured_cost_usd', 'quality'):
        if facts.get(key) is not None:
            card[key] = facts[key]
    if facts.get('input'):
        card['input'] = {**card['input'], **facts['input']}
    return card


def public_card(card):
    """The ONLY projection that leaves the gateway. Allow-list, not deny-list."""
    ops = {}
    for op in OPERATIONS:
        record = card['operations'].get(op) or {}
        if record.get('supported') is True:
            entry = {'confidence': 'verified' if record.get('source') == 'probed' else 'estimated'}
            if op == 'multi_image':
                entry['max_inputs'] = int(record.get('max_inputs') or 2)
            if op == 'variations':
                entry['max_n'] = int(card.get('max_n') or 1)
            ops[op] = entry
    sizes = list((card.get('sizes') or {}).get('native') or [DEFAULT_SIZE])
    latency = card.get('latency_ms_p50')
    return {
        'slug': card['slug'],
        'tags': list(card.get('tags') or []),
        'operations': ops,
        'sizes': sizes,
        'aspect_ratios': list((card.get('sizes') or {}).get('aspect_ratios') or []),
        'max_n': int(card.get('max_n') or 1),
        'input': {'max_images': max_inputs(card),
                  'formats': list((card.get('input') or {}).get('formats') or [])},
        'output_formats': list(card.get('output_formats') or ['png']),
        'text_rendering': (card.get('text_rendering') or {}).get('level', 'none'),
        'quality': card.get('quality', 'med'),
        'speed': 'unknown' if latency is None else 'fast' if latency <= 8000 else 'medium' if latency <= 25000 else 'slow',
        'latency_p50_s': None if latency is None else round(latency / 1000),
        'cost_tier': card.get('cost_tier', 'med'),
        'verified': card.get('state') == 'probed',
    }


def catalog_hash(public_cards):
    blob = json.dumps(sorted(public_cards, key=lambda c: c['slug']), sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(blob.encode()).hexdigest()[:32]


def legacy_card(model, sizes, edit):
    """Card for a backend constructed with explicit (sizes, edit) - old tests,
    old configs. 'declared' because the operator stated it."""
    card = default_card(model)
    card['state'] = 'declared'
    card['operations']['edit'] = cap(bool(edit), 'declared', 0.9)
    card['sizes'] = {'native': list(sizes), 'aspect_ratios': sorted({ratio_of(s) for s in sizes if ratio_of(s)}),
                     'source': 'declared', 'confidence': 0.9}
    card['input']['max_images'] = 1 if edit else 0
    return finalize(card)


def clone(card):
    return copy.deepcopy(card)
