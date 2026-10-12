"""Card lifecycle: detect new/changed models, extract, probe, publish.

Request paths only call `cards()` (memory read). All network work happens in
`tick()`, driven by a background thread (`start`) or by tests directly.
"""
import logging
import threading
import time
from dataclasses import dataclass, field

from .capabilities import (assign_cost_tiers, clone, default_card, finalize, fingerprint, merge_facts)
from .extraction import provider_models_entry, static_extract
from .probes import ProbeBusy

log = logging.getLogger('ovid.images.cards')
WEEK = 7 * 24 * 3600


@dataclass
class Discovered:
    name: str
    params: dict = field(default_factory=dict)   # litellm_params (api_key never stored)
    info: dict = field(default_factory=dict)     # model_info


class CardManager:
    def __init__(self, store, runner=None, *, fetch_json=None, cost_map=None, ttl=WEEK,
                 clock=time.time, backoff_base=300, backoff_max=6 * 3600):
        self.store, self.runner = store, runner
        self.fetch_json = fetch_json          # callable(url) -> parsed json | None (background only)
        self.cost_map = cost_map              # dict or callable() -> dict
        self.ttl, self.clock = ttl, clock
        self.backoff_base, self.backoff_max = backoff_base, backoff_max
        self._known = {}
        self._forced = set()
        self._lock = threading.RLock()
        self._cache = {c['model']: c for c in store.all()}
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None
        self.version = 0

    # -- request path (fast, no I/O) ------------------------------------
    def observe(self, discovered):
        with self._lock:
            self._known = {d.name: d for d in discovered}

    def card(self, name, params=None):
        fp = fingerprint(name, params if params is not None else (self._known[name].params if name in self._known else {}))
        stored = self._cache.get(name)
        if stored and stored['fingerprint'] == fp:
            return stored
        return default_card(name, fp)    # conservative until re-extracted

    def cards(self, names=None):
        with self._lock:
            names = list(names if names is not None else self._known)
            cards = [clone(self.card(n)) for n in names]
        assign_cost_tiers(cards)
        for card in cards:
            finalize(card)
        return cards

    # -- background -------------------------------------------------------
    def reprobe(self, name):
        with self._lock:
            if name not in self._known:
                return False
            self._forced.add(name)
            return True

    def due(self):
        now = self.clock()
        with self._lock:
            known = dict(self._known)
            forced = set(self._forced)
        for name, item in known.items():
            fp = fingerprint(name, item.params)
            stored = self._cache.get(name)
            if name in forced or stored is None or stored['fingerprint'] != fp:
                return name
            if self.runner is None:
                continue
            state = self.store.probe_state(name)
            if now < state['next_attempt_at']:
                continue
            if stored['state'] != 'probed' or (stored.get('probed_at') or 0) + self.ttl <= now:
                return name
        return None

    def tick(self, discover=None):
        """One unit of background work. Returns the model refreshed, or None."""
        if discover is not None:
            try:
                self.observe(discover())
            except Exception as error:  # noqa: BLE001
                log.warning('discovery failed: %s', type(error).__name__)
        name = self.due()
        if name is None:
            return None
        try:
            self.refresh(name)
        except ProbeBusy:
            return None
        return name

    def refresh(self, name):
        with self._lock:
            item = self._known[name]
            self._forced.discard(name)
        fp = fingerprint(name, item.params)
        card = default_card(name, fp)
        card['state'] = 'inferred'
        facts, meta = static_extract(name, item.params, item.info, self._cost_map(), self._provider_entry(item))
        merge_facts(card, facts)
        card['static'] = meta
        finalize(card)
        self._save(card)               # static card is published before any probe spend
        if self.runner is None:
            return card
        probed, summary = self.runner.run(card, facts)
        probed['static'] = meta
        self._save(probed)
        state = self.store.probe_state(name)
        if summary['incomplete']:
            attempts = state['attempts'] + 1
            delay = min(self.backoff_max, self.backoff_base * 2 ** (attempts - 1))
            self.store.set_probe_state(name, attempts, self.clock() + delay, summary['stop'] or 'transient')
        else:
            self.store.set_probe_state(name, 0, self.clock() + self.ttl, None)
        return probed

    def _save(self, card):
        self.store.put(card)
        with self._lock:
            self._cache[card['model']] = card
            self.version += 1

    def _cost_map(self):
        try:
            return self.cost_map() if callable(self.cost_map) else self.cost_map
        except Exception:  # noqa: BLE001
            return None

    def _provider_entry(self, item):
        base = (item.params.get('api_base') or '').rstrip('/')
        if not base or self.fetch_json is None:
            return None
        try:
            listing = self.fetch_json(base + '/models')
        except Exception:  # noqa: BLE001
            return None
        return provider_models_entry(listing, item.params.get('model') or item.name) or None

    # -- thread -----------------------------------------------------------
    def start(self, discover, interval=60):
        if self._thread:
            return
        def loop():
            while not self._stop.is_set():
                self._wake.wait(interval)
                self._wake.clear()
                if self._stop.is_set():
                    break
                try:
                    self.tick(discover)
                except Exception as error:  # noqa: BLE001
                    log.warning('card worker error: %s', type(error).__name__)
        self._thread = threading.Thread(target=loop, name='ovid-image-cards', daemon=True)
        self._thread.start()

    def wake(self):
        self._wake.set()

    def stop(self):
        self._stop.set()
        self._wake.set()
