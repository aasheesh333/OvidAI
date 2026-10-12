"""Data-driven provider registry for the edit shim (hot-reloadable JSON file).

File format (SHIM_PROVIDERS_FILE), re-read whenever its mtime/size changes:

  {"version": 1, "hosts": {"api.newprovider.com": {
      "allowed": true, "json_edit": true,
      "profile": {"image_field": "image", "image_format": "data_url", "image_array": false,
                  "max_images": 1, "mask_field": null, "extra_fields_passthrough": ["quality"],
                  "model_field": "model", "prompt_field": "prompt",
                  "response_format_default": "b64_json", "drop_fields": []}}}}

Env defaults (SHIM_ALLOWED_HOSTS / SHIM_JSON_EDIT_HOSTS) are always the base; file entries
override per host. An invalid file never takes the shim down: the last good config stays.
No secrets live here; the allowlist stays explicit (unknown hosts are 403).
"""
import json
import logging
import os
import threading

log = logging.getLogger('img-edit-shim')

IMAGE_FORMATS = ('data_url', 'base64', 'url_not_supported')
DEFAULT_PROFILE = {
    'image_field': 'image', 'image_format': 'data_url', 'image_array': False, 'max_images': 1,
    'mask_field': None, 'extra_fields_passthrough': ['quality'], 'model_field': 'model',
    'prompt_field': 'prompt', 'response_format_default': 'b64_json', 'drop_fields': [],
}
_FIELD_OK = lambda v: isinstance(v, str) and 0 < len(v) <= 64 and all(c.isalnum() or c in '_-.[]' for c in v)


class ProfileError(ValueError):
    pass


def validate_profile(raw):
    """-> normalised full profile (defaults filled). Raises ProfileError."""
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ProfileError('profile must be an object')
    unknown = set(raw) - set(DEFAULT_PROFILE)
    if unknown:
        raise ProfileError('unknown profile fields: ' + ', '.join(sorted(unknown)))
    p = {**DEFAULT_PROFILE, **raw}
    p['extra_fields_passthrough'] = list(p['extra_fields_passthrough'])
    p['drop_fields'] = list(p['drop_fields'])
    for key in ('image_field', 'model_field', 'prompt_field'):
        if not _FIELD_OK(p[key]):
            raise ProfileError(f'{key} must be a simple field name')
    if p['mask_field'] is not None and not _FIELD_OK(p['mask_field']):
        raise ProfileError('mask_field must be null or a simple field name')
    if p['image_format'] not in IMAGE_FORMATS:
        raise ProfileError('image_format must be one of ' + ', '.join(IMAGE_FORMATS))
    if not isinstance(p['image_array'], bool):
        raise ProfileError('image_array must be boolean')
    mi = p['max_images']
    if isinstance(mi, bool) or not isinstance(mi, int) or not 1 <= mi <= 16:
        raise ProfileError('max_images must be an integer 1..16')
    if not p['image_array']:
        p['max_images'] = 1
    rf = p['response_format_default']
    if rf is not None and rf not in ('b64_json', 'url'):
        raise ProfileError('response_format_default must be b64_json, url or null')
    for key in ('extra_fields_passthrough', 'drop_fields'):
        if not all(_FIELD_OK(v) for v in p[key]):
            raise ProfileError(f'{key} must be a list of simple field names')
    return p


class Registry:
    """host -> {allowed, json_edit, profile|None}. Hot-reloads the providers file."""

    def __init__(self, allowed_hosts, json_edit_hosts, path=None, valid_host=None):
        self.base_allowed, self.base_json = frozenset(allowed_hosts), frozenset(json_edit_hosts)
        self.path, self._valid_host = path, valid_host or (lambda h: True)
        self._sig, self._hosts, self._lock = None, {}, threading.Lock()
        self.last_error = None

    def _load(self):
        if not self.path:
            return
        try:
            st = os.stat(self.path)
            sig = (st.st_mtime_ns, st.st_size)
        except OSError:
            sig = None
        if sig == self._sig:
            return
        with self._lock:
            if sig == self._sig:
                return
            if sig is None:   # file absent: env defaults only
                self._sig, self._hosts, self.last_error = sig, {}, None
                return
            try:
                with open(self.path, encoding='utf-8') as f:
                    doc = json.load(f)
                hosts = self._parse(doc)
            except (OSError, ValueError) as e:   # keep last good config
                self.last_error = str(e)[:200]
                self._sig = sig
                log.warning('providers file rejected (keeping previous config): %s', self.last_error)
                return
            self._sig, self._hosts, self.last_error = sig, hosts, None
            log.info('providers file loaded: %d host(s)', len(hosts))

    def _parse(self, doc):
        if not isinstance(doc, dict) or not isinstance(doc.get('hosts'), dict):
            raise ProfileError('top level must be {"hosts": {...}}')
        out = {}
        for host, entry in doc['hosts'].items():
            if not isinstance(host, str) or host != host.lower() or not self._valid_host(host):
                raise ProfileError(f'invalid host {host!r}')
            if not isinstance(entry, dict) or set(entry) - {'allowed', 'json_edit', 'profile'}:
                raise ProfileError(f'invalid entry for {host}')
            allowed, json_edit = entry.get('allowed', True), entry.get('json_edit', False)
            if not isinstance(allowed, bool) or not isinstance(json_edit, bool):
                raise ProfileError(f'allowed/json_edit must be boolean for {host}')
            profile = validate_profile(entry['profile']) if entry.get('profile') is not None else None
            out[host] = {'allowed': allowed, 'json_edit': json_edit, 'profile': profile}
        return out

    def lookup(self, host):
        """-> (allowed, json_edit, profile|None). profile None + json_edit => legacy/default adapter."""
        self._load()
        entry = self._hosts.get(host)
        if entry is not None:
            return entry['allowed'], entry['allowed'] and entry['json_edit'], entry['profile']
        return host in self.base_allowed, host in self.base_json and host in self.base_allowed, None
