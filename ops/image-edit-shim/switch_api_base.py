#!/usr/bin/env python3
"""Point LiteLLM image models at the img-edit-shim (or back), changing ONLY api_base.

Usage (dry-run is the default; nothing is written without --apply/--revert):
  switch_api_base.py                        # show planned changes for all image models
  switch_api_base.py --apply --model-name gpt-image-2   # switch ONE model first
  switch_api_base.py --apply                # switch the rest
  switch_api_base.py --revert [--apply]     # restore recorded originals (dry-run unless --apply)

Environment / .env: LITELLM_BASE, LITELLM_MASTER_KEY (only used as the admin Bearer for LiteLLM).

Key safety: the call used is PATCH /model/{model_id}/update with body
{"litellm_params": {"api_base": "<url>"}}. LiteLLM's PATCH endpoint is the partial
update: only the supplied fields are changed and the stored (encrypted) api_key is
kept. POST /model/update is NOT used: it replaces the deployment's litellm_params
from the request, so omitting api_key could drop it, and /model/info only returns
a redacted key so the real one cannot be re-sent. This script never reads, sends,
stores or prints a provider api_key; after each update it re-reads /model/info and
checks that every litellm_params field except api_base (including the redacted
api_key mask) is unchanged, restoring api_base and aborting otherwise.
"""
import argparse
import json
import os
import stat
import sys
from urllib.parse import urlsplit, urlunsplit

import httpx

IMAGE_MODES = ('image_generation', 'image_edit')
DEFAULT_SHIM = 'http://img-edit-shim:8099'
DEFAULT_BACKUP = 'image-edit-shim-backup.json'


class SwitchError(Exception):
    pass


def load_env(path, environ):
    env = {}
    if path and os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                if k.strip() in ('LITELLM_BASE', 'LITELLM_MASTER_KEY'):
                    env[k.strip()] = v.strip().strip('"\'')
    env.update({k: v for k, v in environ.items() if k in ('LITELLM_BASE', 'LITELLM_MASTER_KEY')})
    return env


class LiteLLM:
    def __init__(self, base, key, transport=None):
        self.http = httpx.Client(base_url=base.rstrip('/'), headers={'Authorization': f'Bearer {key}'},
                                 transport=transport, timeout=30, follow_redirects=False)

    def _check(self, r, what):
        if r.status_code >= 300:  # body deliberately not echoed
            raise SwitchError(f'{what} failed: HTTP {r.status_code}')
        return r

    def model_info(self):
        return self._check(self.http.get('/model/info'), 'GET /model/info').json().get('data', [])

    def patch_api_base(self, model_id, api_base):
        body = {'litellm_params': {'api_base': api_base}}
        self._check(self.http.patch(f'/model/{model_id}/update', json=body), f'PATCH /model/{model_id}/update')


def model_id_of(m):
    return (m.get('model_info') or {}).get('id')


def is_image_model(m, names):
    if names and m.get('model_name') in names:
        return True
    return (m.get('model_info') or {}).get('mode') in IMAGE_MODES


def shim_url(original, shim_base, allowed):
    parts = urlsplit(original or '')
    host = (parts.hostname or '').lower()
    if parts.scheme != 'https' or parts.port or parts.username or host not in allowed:
        return None
    return f"{shim_base.rstrip('/')}/{host}{parts.path.rstrip('/')}"


def params_without_api_base(m):
    return {k: v for k, v in (m.get('litellm_params') or {}).items() if k != 'api_base'}


def current(models, model_id):
    return next((m for m in models if model_id_of(m) == model_id), None)


def set_and_verify(api, model_id, new_base, old_base):
    before = current(api.model_info(), model_id)
    if before is None:
        raise SwitchError(f'model {model_id} not found')
    api.patch_api_base(model_id, new_base)
    after = current(api.model_info(), model_id)
    problem = None
    if after is None:
        problem = 'model no longer listed'
    elif (after.get('litellm_params') or {}).get('api_base') != new_base:
        problem = 'api_base not updated'
    elif params_without_api_base(after) != params_without_api_base(before):
        problem = 'fields other than api_base changed'
    if problem:
        if after is not None and old_base:
            try:
                api.patch_api_base(model_id, old_base)
            except SwitchError:
                pass
        raise SwitchError(f'{model_id}: {problem}; restore attempted, aborting')


def load_backup(path):
    if os.path.exists(path):
        return json.load(open(path, encoding='utf-8'))
    return {}


def save_backup(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, sort_keys=True)


def run(args, env, transport=None, out=print):
    if not env.get('LITELLM_BASE') or not env.get('LITELLM_MASTER_KEY'):
        raise SwitchError('LITELLM_BASE and LITELLM_MASTER_KEY are required (env or .env)')
    api = LiteLLM(env['LITELLM_BASE'], env['LITELLM_MASTER_KEY'], transport)
    models = api.model_info()
    dry = not args.apply
    out(('DRY RUN (use --apply to write)' if dry else 'APPLY') + (' [revert]' if args.revert else ''))
    backup = load_backup(args.backup)
    allowed = {h.strip().lower() for h in args.allowed_hosts.split(',') if h.strip()}
    chosen = [m for m in models if model_id_of(m) and is_image_model(m, set(args.model_name))
              and (not args.model_name or m.get('model_name') in args.model_name)
              and (not args.model_id or model_id_of(m) in args.model_id)]
    changed = 0
    if args.revert:
        for m in chosen:
            mid = model_id_of(m)
            original = backup.get(mid)
            base = (m.get('litellm_params') or {}).get('api_base')
            if not original or base == original:
                out(f"skip {m.get('model_name')} ({mid}): nothing to revert")
                continue
            out(f"revert {m.get('model_name')} ({mid}): {base} -> {original}")
            if not dry:
                set_and_verify(api, mid, original, base)
                backup.pop(mid)
                save_backup(args.backup, backup)
            changed += 1
    else:
        for m in chosen:
            mid, base = model_id_of(m), (m.get('litellm_params') or {}).get('api_base')
            target = shim_url(base, args.shim_base, allowed)
            if target is None:
                out(f"skip {m.get('model_name')} ({mid}): api_base {base!r} not an allowed https host")
                continue
            if target == base:
                out(f"skip {m.get('model_name')} ({mid}): already switched")
                continue
            out(f"switch {m.get('model_name')} ({mid}): {base} -> {target}")
            if not dry:
                backup.setdefault(mid, base)
                save_backup(args.backup, backup)  # record the original BEFORE changing it
                set_and_verify(api, mid, target, base)
            changed += 1
    out(f'{changed} model(s) {"would change" if dry else "changed"}')
    return changed


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--apply', action='store_true', help='write changes (default is dry-run)')
    p.add_argument('--dry-run', action='store_true', help='explicit dry-run (the default)')
    p.add_argument('--revert', action='store_true', help='restore api_base values recorded in the backup file')
    p.add_argument('--model-name', action='append', default=[], help='only this model_name (repeatable)')
    p.add_argument('--model-id', action='append', default=[], help='only this model id (repeatable)')
    p.add_argument('--shim-base', default=DEFAULT_SHIM)
    p.add_argument('--allowed-hosts', default='api.inferhub.dev', help='upstream hosts that may be switched')
    p.add_argument('--backup', default=DEFAULT_BACKUP)
    p.add_argument('--env-file', default='.env')
    args = p.parse_args(argv)
    if args.apply and args.dry_run:
        p.error('--apply and --dry-run are mutually exclusive')
    return args


def main(argv=None):
    args = parse(argv)
    try:
        run(args, load_env(args.env_file, os.environ))
    except (SwitchError, httpx.HTTPError) as e:
        print(f'error: {e if isinstance(e, SwitchError) else type(e).__name__}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
