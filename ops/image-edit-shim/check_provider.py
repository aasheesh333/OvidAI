#!/usr/bin/env python3
"""Read-only readiness report for one LiteLLM image model.

  check_provider.py <model_name> [--providers-file PATH]

Never writes anything and never reads or prints a provider key. Exit 0 = ready for user traffic,
1 = something to do (see "next steps"). Env/.env as in onboard_provider.py.
"""
import argparse
import os
import sys
import time

import httpx

import onboard_provider as ob
from server.images import costing


def run(args, env, litellm_transport=None, gateway_transport=None, out=print):
    for k in ('LITELLM_BASE', 'LITELLM_MASTER_KEY'):
        if not env.get(k):
            raise ob.OnboardError(f'{k} is required (env or .env)')
    api = ob.sw.LiteLLM(env['LITELLM_BASE'], env['LITELLM_MASTER_KEY'], litellm_transport)
    rows = [m for m in api.model_info() if m.get('model_name') == args.model]
    todo = []
    out(f'provider readiness: {args.model}')
    if not rows:
        out('  LiteLLM: model not found')
        out('next steps:\n  1. add the model (base URL + key + price) in LiteLLM')
        return 1
    row = rows[0]
    info, params = row.get('model_info') or {}, row.get('litellm_params') or {}
    is_image = info.get('mode') in ob.sw.IMAGE_MODES or info.get('output_modality') == 'image'
    out(f"  LiteLLM: found, mode={info.get('mode')} {'(image model)' if is_image else '(NOT an image model: set mode image_generation)'}")
    if not is_image:
        todo.append('set model_info.mode to image_generation in LiteLLM so the gateway discovers it')

    # edit path
    shim_base = args.shim_base
    host, via_shim = ob.host_of_base(params.get('api_base'), shim_base)
    providers_path = args.providers_file or env.get('SHIM_PROVIDERS_FILE')
    allowed = {h.strip() for h in os.environ.get('SHIM_ALLOWED_HOSTS', 'api.inferhub.dev').split(',') if h.strip()}
    json_edit = {h.strip() for h in os.environ.get('SHIM_JSON_EDIT_HOSTS', 'api.inferhub.dev').split(',') if h.strip()}
    entry = None
    if providers_path and os.path.exists(providers_path):
        entry = ob.read_providers(providers_path)['hosts'].get(host)
    if entry is not None:
        allowed_ok, json_ok = entry.get('allowed', True), entry.get('allowed', True) and entry.get('json_edit', False)
    else:
        allowed_ok, json_ok = host in allowed, host in json_edit
    out(f'  api_base host: {host or "?"}   shim allowlisted: {"yes" if allowed_ok else "no"}'
        f"{'' if providers_path else ' (no providers file given: env defaults only)'}")
    if via_shim:
        out(f"  edit path: shim ({'JSON edit profile' if json_ok else 'transparent proxy'})")
        if not allowed_ok:
            todo.append(f'api_base points at the shim but {host} is not allowlisted: onboard_provider.py --host {host} --json-edit --apply')
    elif json_ok:
        out('  edit path: standard multipart straight to the provider, but the host is configured as JSON-edit')
        todo.append(f'edits will fail with "body must be JSON": onboard_provider.py --host {host} --json-edit --apply')
    else:
        out('  edit path: standard multipart (no shim)')

    # price
    missing = costing.missing_price_fields(info)
    priced, source, _ = costing.price_status(info)
    out(f"  price (LiteLLM model_info): {'ok via ' + source if priced else 'MISSING'}"
        f"{'' if priced else '; absent fields: ' + ', '.join(missing)}")
    if not priced:
        todo.append("set the model's price in LiteLLM (input/output cost per token, or output cost per image), "
                    'then POST /images/admin/refresh-prices (or wait ~5 min)')

    # card
    card = None
    try:
        body = ob.Gateway(env['OVID_GATEWAY_BASE'], env['LITELLM_MASTER_KEY'], gateway_transport).cards() \
            if env.get('OVID_GATEWAY_BASE') else None
    except (ob.OnboardError, httpx.HTTPError) as e:
        body = None
        out(f'  gateway admin: unreachable ({type(e).__name__})')
    if body is None:
        if not env.get('OVID_GATEWAY_BASE'):
            out('  gateway admin: OVID_GATEWAY_BASE not set; card checks skipped')
    else:
        card = ob.card_for(body, args.model)
        out(f"  discovered by gateway: {'yes' if card else 'no'}")
        if card is None:
            todo.append('wait up to ~1 min for discovery (it lists /model/info), then re-run this check')
        else:
            ob.describe_card(card, out)
            if card.get('priced') is False and priced:
                todo.append('gateway still sees it unpriced: POST /images/admin/refresh-prices')
            errors = [p for p in card.get('probes') or [] if not p.get('ok')]
            for p in errors[-5:]:
                out(f"  probe failed: {p.get('probe')} -> {p.get('error_class')}")
            budget = body.get('probe_budget') or {}
            out(f"  probe budget left (24h): ${budget.get('probe_daily_left_usd')} of ${budget.get('probe_daily_cap_usd')}"
                f"   per-call cap ${budget.get('probe_per_call_cap_usd')}")
            if card.get('state') != 'probed':
                if any(p.get('error_class') == 'auth' for p in errors):
                    todo.append('provider rejected the key: fix the api_key in LiteLLM')
                elif budget.get('probe_daily_left_usd') == 0:
                    todo.append('probe budget exhausted: raise OVID_PROBE_DAILY_USD or wait for the 24h window')
                elif any(w.startswith('returns_urls') for w in card.get('warnings') or []):
                    todo.append('provider returns URLs only: not usable (needs b64_json support)')
                else:
                    todo.append(f'card is {card.get("state")}: run onboard_provider.py --host {host} --apply to force a re-probe')
            if 'generate' not in {op for op, r in (card.get('operations') or {}).items() if r.get('supported')}:
                todo.append('generate not supported/proven: see probe failures above')
    ready = not todo
    out('READY for user traffic' if ready else 'NOT READY')
    if todo:
        out('next steps:')
        for i, t in enumerate(todo, 1):
            out(f'  {i}. {t}')
    return 0 if ready else 1


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('model')
    p.add_argument('--providers-file')
    p.add_argument('--shim-base', default=ob.sw.DEFAULT_SHIM)
    p.add_argument('--env-file', default='.env')
    return p.parse_args(argv)


def main(argv=None):
    args = parse(argv)
    try:
        return run(args, ob.load_env(args.env_file, os.environ))
    except (ob.OnboardError, ob.sw.SwitchError, httpx.HTTPError) as e:
        print(f'error: {e if isinstance(e, (ob.OnboardError, ob.sw.SwitchError)) else type(e).__name__}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
