#!/usr/bin/env python3
"""One-command onboarding of an image provider whose edits need the JSON shim.

  onboard_provider.py --host api.newprovider.com                       # dry-run: plan only
  onboard_provider.py --host api.newprovider.com --json-edit --image-format data_url --apply
  onboard_provider.py --host api.x.com --json-edit --image-field images --image-array \\
      --max-images 4 --image-format base64 --models my-model --apply

What it does (nothing is written without --apply):
  1. validates the host (public DNS name, no IP/port/userinfo);
  2. with --json-edit: writes the host + profile into the shim providers file (hot-reloaded);
  3. with --json-edit: points the host's LiteLLM image models at the shim (PATCH api_base ONLY, key
     preserved and verified by re-reading /model/info; reuses switch_api_base.py);
  4. forces a re-probe via POST /images/admin/reprobe, waits, prints the resulting card;
  5. prints the rollback commands.
Providers that accept standard multipart need no shim: skip --json-edit (only the re-probe runs).

Env / .env: LITELLM_BASE, LITELLM_MASTER_KEY (admin bearer for LiteLLM and the gateway admin API,
never printed or sent anywhere else), OVID_GATEWAY_BASE (gateway base URL for /images/admin/*),
SHIM_PROVIDERS_FILE (providers file path; --providers-file overrides).
"""
import argparse
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

import httpx

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
for p in (str(HERE), str(REPO), str(REPO / 'server' / 'images' / 'editshim')):
    if p not in sys.path:
        sys.path.insert(0, p)

import switch_api_base as sw  # noqa: E402
from profiles import DEFAULT_PROFILE, ProfileError, validate_profile  # noqa: E402

HOST_RE = re.compile(r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
ENV_KEYS = ('LITELLM_BASE', 'LITELLM_MASTER_KEY', 'OVID_GATEWAY_BASE', 'SHIM_PROVIDERS_FILE')


class OnboardError(Exception):
    pass


def valid_host(host):
    return (isinstance(host, str) and bool(HOST_RE.match(host)) and not re.fullmatch(r'[0-9.]+', host)
            and not host.endswith(('.local', '.internal', '.localhost')))


def load_env(path, environ):
    env = {}
    if path and os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                if k.strip() in ENV_KEYS:
                    env[k.strip()] = v.strip().strip('"\'')
    env.update({k: v for k, v in environ.items() if k in ENV_KEYS})
    return env


class Gateway:
    """Admin API of the Ovid image gateway (card read, reprobe)."""

    def __init__(self, base, key, transport=None):
        self.http = httpx.Client(base_url=base.rstrip('/'), headers={'Authorization': f'Bearer {key}'},
                                 transport=transport, timeout=30, follow_redirects=False)

    def cards(self):
        r = self.http.get('/images/admin/cards')
        if r.status_code != 200:
            raise OnboardError(f'GET /images/admin/cards failed: HTTP {r.status_code}')
        return r.json()

    def reprobe(self, model):
        r = self.http.post('/images/admin/reprobe', json={'model': model})
        return r.status_code

    def refresh_prices(self):
        return self.http.post('/images/admin/refresh-prices').status_code


def host_of_base(api_base, shim_base=None):
    """Upstream host of a LiteLLM api_base, looking through a shim URL (<shim>/<host>/v1)."""
    parts = urlsplit(api_base or '')
    if shim_base and (api_base or '').startswith(shim_base.rstrip('/') + '/'):
        rest = (api_base or '')[len(shim_base.rstrip('/')) + 1:]
        return rest.split('/', 1)[0].lower(), True
    return (parts.hostname or '').lower(), False


def read_providers(path):
    if path and os.path.exists(path):
        try:
            doc = json.load(open(path, encoding='utf-8'))
        except ValueError as e:
            raise OnboardError(f'providers file {path} is not valid JSON: {e}')
        if not isinstance(doc, dict) or not isinstance(doc.get('hosts'), dict):
            raise OnboardError(f'providers file {path} must look like {{"hosts": {{...}}}}')
        return doc
    return {'version': 1, 'hosts': {}}


def write_providers(path, doc):
    """Atomic replace (mount the DIRECTORY into the shim, not the single file)."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        shutil.copy2(p, str(p) + '.bak')
    tmp = p.with_name(p.name + '.tmp')
    tmp.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    os.replace(tmp, p)


def profile_from_args(args):
    raw = {}
    if args.image_format:
        raw['image_format'] = args.image_format
    if args.image_field:
        raw['image_field'] = args.image_field
    if args.image_array:
        raw['image_array'] = True
    if args.max_images:
        raw['max_images'] = args.max_images
    if args.mask_field:
        raw['mask_field'] = args.mask_field
    if args.passthrough is not None:
        raw['extra_fields_passthrough'] = [x for x in args.passthrough.split(',') if x]
    if args.model_field:
        raw['model_field'] = args.model_field
    if args.prompt_field:
        raw['prompt_field'] = args.prompt_field
    if args.response_format_default:
        raw['response_format_default'] = None if args.response_format_default == 'none' else args.response_format_default
    if args.drop_fields:
        raw['drop_fields'] = [x for x in args.drop_fields.split(',') if x]
    try:
        return validate_profile(raw)
    except ProfileError as e:
        raise OnboardError(f'invalid profile: {e}')


def host_models(models, host, names, shim_base):
    out = []
    for m in models:
        if not sw.model_id_of(m) or not sw.is_image_model(m, set(names)):
            continue
        if names and m.get('model_name') not in names:
            continue
        h, _ = host_of_base((m.get('litellm_params') or {}).get('api_base'), shim_base)
        if h == host:
            out.append(m)
    return out


def card_for(cards, model):
    return next((c for c in cards.get('cards', []) if c.get('model') == model), None)


def describe_card(card, out):
    if card is None:
        out('  card: not discovered yet by the gateway')
        return
    ops = sorted(op for op, r in (card.get('operations') or {}).items() if r.get('supported') is True)
    sizes = (card.get('sizes') or {}).get('native') or []
    out(f"  card state: {card.get('state')}   ops: {', '.join(ops) or '-'}   sizes: {', '.join(sizes) or '-'}")
    cost = card.get('measured_cost_usd')
    out(f"  cost: {('$%.4f' % cost) if cost else 'unknown'}   priced: {card.get('priced')}"
        f"   cost source: {card.get('cost_source')}")
    for w in card.get('warnings') or []:
        out(f'  WARNING: {w}')


def run(args, env, litellm_transport=None, gateway_transport=None, out=print, sleep=time.sleep):
    host = args.host.lower()
    if not valid_host(host):
        raise OnboardError(f'invalid host {args.host!r}: need a public DNS name (no scheme, port, path or IP)')
    for k in ('LITELLM_BASE', 'LITELLM_MASTER_KEY'):
        if not env.get(k):
            raise OnboardError(f'{k} is required (env or .env)')
    gw_base = env.get('OVID_GATEWAY_BASE')
    dry = not args.apply
    providers_path = args.providers_file or env.get('SHIM_PROVIDERS_FILE') or 'shim-providers.json'
    profile = profile_from_args(args) if args.json_edit else None
    out(('DRY RUN (use --apply to write)' if dry else 'APPLY') + f' onboarding {host}')
    api = sw.LiteLLM(env['LITELLM_BASE'], env['LITELLM_MASTER_KEY'], litellm_transport)
    models = host_models(api.model_info(), host, set(args.models), args.shim_base)
    if not models:
        raise OnboardError(f'no LiteLLM image model uses {host} (add the model + base URL + key in LiteLLM first'
                           + (f'; --models {",".join(args.models)} filter active' if args.models else '') + ')')
    for m in models:
        out(f"  model {m.get('model_name')} ({sw.model_id_of(m)}) api_base={(m.get('litellm_params') or {}).get('api_base')}")

    # 1. providers file
    doc = read_providers(providers_path)
    rollback = []
    if args.json_edit:
        entry = {'allowed': True, 'json_edit': True, 'profile': profile}
        same = doc['hosts'].get(host) == entry
        out(f"{'skip' if same else 'write'} providers file {providers_path}: {host} -> "
            f"{json.dumps(entry, sort_keys=True)}")
        if not dry and not same:
            doc['hosts'][host] = entry
            write_providers(providers_path, doc)
        rollback.append(f'restore {providers_path}.bak (or remove the "{host}" entry; the shim reloads it by itself)')
    else:
        out('standard multipart provider: no shim entry or api_base change needed (use --json-edit if edits need JSON)')

    # 2. api_base switch (PATCH api_base only; key verified untouched)
    changed = []
    if args.json_edit:
        backup = sw.load_backup(args.backup)
        for m in models:
            mid, base = sw.model_id_of(m), (m.get('litellm_params') or {}).get('api_base')
            if host_of_base(base, args.shim_base)[1]:
                out(f"skip {m.get('model_name')}: already pointing at the shim")
                continue
            target = sw.shim_url(base, args.shim_base, {host})
            if target is None:
                out(f"skip {m.get('model_name')}: api_base {base!r} is not an https URL on {host}")
                continue
            out(f"switch {m.get('model_name')} ({mid}): {base} -> {target}")
            if not dry:
                backup.setdefault(mid, base)
                sw.save_backup(args.backup, backup)
                sw.set_and_verify(api, mid, target, base)
                changed.append(m.get('model_name'))
        rollback.append(f"switch_api_base.py --revert --apply --backup {args.backup} "
                        + ' '.join(f'--model-name {m.get("model_name")}' for m in models))
    if dry:
        out('dry run complete: re-run with --apply to write, re-probe and print the card')
        return 0
    if not gw_base:
        raise OnboardError('OVID_GATEWAY_BASE is required to re-probe and read cards')

    # 3. reprobe + wait + card
    gw = Gateway(gw_base, env['LITELLM_MASTER_KEY'], gateway_transport)
    gw.refresh_prices()
    started = {c['model']: c.get('probed_at') for c in gw.cards().get('cards', [])}
    for m in models:
        name = m.get('model_name')
        for attempt in range(args.discovery_wait):
            status = gw.reprobe(name)
            if status != 404:
                break
            sleep(10)   # gateway discovers new models on its own cadence
        out(f'reprobe {name}: HTTP {status}' + (' (queued)' if status == 202 else ''))
    deadline, pending = time.monotonic() + args.wait, {m.get('model_name') for m in models}
    final = {}
    while pending:
        body = gw.cards()
        for name in list(pending):
            card = card_for(body, name)
            if card and card.get('probed_at') and card.get('probed_at') != started.get(name):
                final[name] = card
                pending.discard(name)
        if not pending or time.monotonic() >= deadline:
            break
        sleep(5)
    body = gw.cards()
    for m in models:
        name = m.get('model_name')
        out(f'card {name}:')
        describe_card(card_for(body, name) or final.get(name), out)
        if name in pending:
            out(f'  still probing after {args.wait}s (probes are staggered); check later with check_provider.py {name}')
    budget = body.get('probe_budget') or {}
    if budget:
        out(f"probe budget: spent_24h=${budget.get('probe_spend_24h_usd')} cap=${budget.get('probe_daily_cap_usd')}")
    out('rollback:')
    for line in rollback:
        out('  ' + line)
    return 0


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--host', required=True, help='provider API host, e.g. api.newprovider.com')
    p.add_argument('--apply', action='store_true', help='write changes (default is dry-run)')
    p.add_argument('--json-edit', action='store_true', help="the provider's edit endpoint needs JSON, not multipart")
    p.add_argument('--models', nargs='*', default=[], help='only these LiteLLM model_name values')
    p.add_argument('--image-format', choices=('data_url', 'base64', 'url_not_supported'))
    p.add_argument('--image-field')
    p.add_argument('--image-array', action='store_true')
    p.add_argument('--max-images', type=int)
    p.add_argument('--mask-field')
    p.add_argument('--passthrough', help='comma list of extra form fields to copy (default: quality)')
    p.add_argument('--model-field')
    p.add_argument('--prompt-field')
    p.add_argument('--response-format-default', choices=('b64_json', 'url', 'none'))
    p.add_argument('--drop-fields', help='comma list of body fields to remove')
    p.add_argument('--providers-file')
    p.add_argument('--shim-base', default=sw.DEFAULT_SHIM)
    p.add_argument('--backup', default=sw.DEFAULT_BACKUP)
    p.add_argument('--env-file', default='.env')
    p.add_argument('--wait', type=int, default=300, help='seconds to wait for the probe (default 300)')
    p.add_argument('--discovery-wait', type=int, default=6, help='reprobe retries while the gateway discovers the model')
    return p.parse_args(argv)


def main(argv=None):
    args = parse(argv)
    try:
        return run(args, load_env(args.env_file, os.environ))
    except (OnboardError, sw.SwitchError, httpx.HTTPError) as e:
        print(f'error: {e if isinstance(e, (OnboardError, sw.SwitchError)) else type(e).__name__}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
