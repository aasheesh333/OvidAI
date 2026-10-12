"""Capability-based image backend selection. Pure functions, no I/O.

pick_backends(task, cards, unavailable) hard-filters by what the task REQUIRES
(operation, size/ratio, mask, input count, transparency) and then scores what is
left by preference (quality | speed | cost | balanced) and text-rendering need.
Models in capacity cooldown are skipped, never ranked.
"""
import re
from dataclasses import dataclass, field

from .capabilities import ALIAS, DEFAULT_SIZE, SIZE_RE, max_inputs, supports

PREFERENCES = ('balanced', 'quality', 'speed', 'cost')
TASK_OPERATIONS = ('generate', 'edit', 'inpaint', 'outpaint', 'reference_style', 'multi_image',
                   'remove_background', 'upscale', 'variations')
_COST = {'low': 0.0, 'med': 0.5, 'high': 1.0}
_QUALITY = {'low': 0.0, 'med': 0.5, 'high': 1.0}
_TEXT = {'none': 0.0, 'ok': 0.5, 'good': 1.0}


@dataclass(frozen=True)
class Task:
    operation: str = 'generate'
    size: str | None = None
    aspect_ratio: str | None = None
    n_inputs: int = 0          # input images, including the primary image
    mask: bool = False
    transparent: bool = False
    text_rendering: bool = False
    preference: str = 'balanced'

    def needs(self):
        """Capability keys the card must have as supported."""
        keys = []
        op = self.operation
        keys.append('generate' if op == 'generate' else 'edit')
        if op in ('inpaint', 'outpaint', 'reference_style', 'multi_image', 'remove_background', 'upscale', 'variations'):
            keys.append(op)
        if self.mask and 'inpaint' not in keys:
            keys.append('inpaint')
        if self.n_inputs > 1 and 'multi_image' not in keys:
            keys.append('multi_image')
        if self.transparent and 'transparent_output' not in keys:
            keys.append('transparent_output')
        return keys


def missing(card, task):
    """Why `card` cannot serve `task` (empty list = it can)."""
    reasons = [op for op in task.needs() if not supports(card, op)]
    if task.operation != 'generate' and task.transparent and card.get('edit_transport') == 'direct' \
            and 'transparent_output' not in reasons:
        reasons.append('transparent_output')   # the provider's edit contract has no background control
    sizes = (card.get('sizes') or {}).get('native') or [DEFAULT_SIZE]
    if task.size and task.size not in sizes:
        reasons.append(f'size:{task.size}')
    if task.aspect_ratio:
        ratios = (card.get('sizes') or {}).get('aspect_ratios') or []
        if task.aspect_ratio not in ratios:
            reasons.append(f'aspect_ratio:{task.aspect_ratio}')
    if task.n_inputs > max(max_inputs(card), 0) and task.operation != 'generate' and not reasons:
        reasons.append(f'inputs:{task.n_inputs}')
    return reasons


def score(card, task):
    cost = _COST.get(card.get('cost_tier', 'med'), 0.5)
    quality = _QUALITY.get(card.get('quality', 'med'), 0.5)
    latency = card.get('latency_ms_p50')
    speed = 0.5 if latency is None else max(0.0, 1.0 - min(latency, 60000) / 60000)
    text = _TEXT.get((card.get('text_rendering') or {}).get('level', 'none'), 0.0)
    weights = {'balanced': (1.0, 1.0, 1.0), 'quality': (3.0, 0.5, 0.3),
               'speed': (0.4, 3.0, 0.4), 'cost': (0.3, 0.4, 3.0)}[task.preference]
    total = weights[0] * quality + weights[1] * speed + weights[2] * (1.0 - cost)
    if task.text_rendering:
        total += 3.0 * text   # a need, not a taste
    # Verified cards beat guessed ones when otherwise close.
    if card.get('state') == 'probed':
        total += 0.15
    return total


def pick_backends(task, cards, unavailable=()):
    """Ordered candidate cards: capable, available, best-first. Deterministic."""
    blocked = unavailable if callable(unavailable) else (lambda model, s=set(unavailable): model in s)
    capable = [c for c in cards if not missing(c, task) and not blocked(c['model'])]
    return sorted(capable, key=lambda c: -score(c, task))  # stable: ties keep discovery order


def alternatives(task, cards):
    """Slugs able to do the task regardless of cooldown (for 422 bodies)."""
    capable = [c for c in cards if not missing(c, task)]
    return [c['slug'] for c in sorted(capable, key=lambda c: -score(c, task))]


def parse_model(value):
    """'ovid-image' -> None (auto); 'ovid-image:img-xxxxxx' -> slug; else error."""
    if value == ALIAS:
        return None
    if isinstance(value, str) and re.fullmatch(re.escape(ALIAS) + r':[A-Za-z0-9_-]{3,40}', value):
        return value
    raise ValueError('model')


def normalize_size(size):
    if size is None:
        return None
    if not isinstance(size, str) or not SIZE_RE.match(size):
        raise ValueError('size')
    return size


def task_from_request(operation, body):
    """Build a Task from a validated execute body. Raises ValueError on bad input."""
    req = body.get('requirements') or {}
    if not isinstance(req, dict):
        raise ValueError('requirements')
    allowed = {'operation', 'aspect_ratio', 'transparent_background', 'text_rendering'}
    if set(req) - allowed:
        raise ValueError('requirements')
    pref = body.get('preference', 'balanced')
    if pref not in PREFERENCES:
        raise ValueError('preference')
    op = req.get('operation') or operation
    if op not in TASK_OPERATIONS or (operation == 'generate' and op not in ('generate', 'variations')) \
            or (operation == 'edit' and op == 'generate'):
        raise ValueError('operation')
    mask = bool(body.get('mask'))
    if mask and op == 'edit':
        op = 'inpaint'
    extra = body.get('images') or []
    if not isinstance(extra, list) or len(extra) > 8:
        raise ValueError('images')
    n_inputs = (1 if body.get('image') else 0) + len(extra)
    if n_inputs > 1 and op == 'edit':
        op = 'multi_image'
    ratio = req.get('aspect_ratio')
    if ratio is not None and not (isinstance(ratio, str) and re.fullmatch(r'[1-9][0-9]?:[1-9][0-9]?', ratio)):
        raise ValueError('aspect_ratio')
    size = normalize_size(body.get('size')) if body.get('size') else None
    return Task(operation=op, size=size, aspect_ratio=ratio, n_inputs=n_inputs, mask=mask,
                transparent=bool(req.get('transparent_background')),
                text_rendering=bool(req.get('text_rendering')), preference=pref)
