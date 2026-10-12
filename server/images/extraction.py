"""Static capability extraction: no paid call, no user request path.

Sources, weakest to strongest (all produce 'inferred'/'declared' facts):
  1. name hints for well-known image model families (low confidence)
  2. LiteLLM /model/info `model_info` + its built-in cost-map metadata
     (mode, supported_endpoints, supported_modalities, output_cost_per_image)
  3. the raw LiteLLM cost map (optional, fetched in the background)
  4. the provider's own models API when the base URL exposes it
     (OpenRouter-style architecture.*_modalities, replicate/fal/HF-style
     input schemas)
Probes (probes.py) later overwrite any of this with measured truth.
"""
import re

from .capabilities import DEFAULT_SIZE, SIZE_RE, cap, ratio_of

# (regex on lowercase model name) -> hints. Hints are guesses; confidence is low.
_FAMILIES = (
    (r'gpt-image', {'sizes': ['1024x1024', '1536x1024', '1024x1536'], 'edit': True, 'inpaint': True,
                    'multi_image': 16, 'transparent': True, 'text': 'good', 'quality': 'high',
                    'formats': ['png', 'jpeg', 'webp']}),
    (r'dall-e-3', {'sizes': ['1024x1024', '1792x1024', '1024x1792'], 'edit': False, 'text': 'ok',
                   'quality': 'high', 'max_n': 1}),
    (r'dall-e-2', {'sizes': ['256x256', '512x512', '1024x1024'], 'edit': True, 'inpaint': True,
                   'variations': True, 'text': 'none', 'quality': 'low', 'max_n': 10}),
    (r'gemini.*image|nano-banana', {'sizes': ['1024x1024', '1536x1024', '1024x1536'], 'edit': True,
                                    'multi_image': 3, 'text': 'good', 'quality': 'high'}),
    (r'imagen', {'sizes': ['1024x1024', '1536x1024', '1024x1536'], 'edit': False, 'text': 'ok',
                 'quality': 'high', 'max_n': 4}),
    (r'flux.*(fill|inpaint)', {'edit': True, 'inpaint': True, 'outpaint': True, 'quality': 'high'}),
    (r'flux.*(kontext)', {'edit': True, 'reference_style': True, 'text': 'good', 'quality': 'high'}),
    (r'flux.*schnell|turbo|lightning|lcm|sdxl-turbo', {'quality': 'low', 'text': 'none'}),
    (r'flux', {'quality': 'high', 'text': 'ok'}),
    (r'stable-diffusion|sdxl|sd3', {'edit': True, 'inpaint': True, 'text': 'none', 'quality': 'med'}),
    (r'upscal|esrgan|clarity', {'upscale': True, 'edit': True}),
    (r'rembg|remove-?bg|background-?remov|birefnet', {'remove_background': True, 'edit': True, 'transparent': True}),
)


def _hints(name):
    merged = {}
    lowered = name.lower()
    for pattern, hint in _FAMILIES:
        if re.search(pattern, lowered):
            for key, value in hint.items():
                merged.setdefault(key, value)
    return merged


def _sizes_from(value):
    out = []
    for item in value if isinstance(value, (list, tuple)) else []:
        if isinstance(item, str):
            item = item.replace('-x-', 'x').replace('X', 'x').replace('*', 'x')
            if SIZE_RE.match(item) and item not in out:
                out.append(item)
    return out


def cost_map_lookup(cost_map, litellm_model):
    """Find the raw LiteLLM cost-map entry for 'provider/model' or 'model'."""
    if not isinstance(cost_map, dict) or not litellm_model:
        return {}
    tail = litellm_model.split('/', 1)[-1]
    for key in (litellm_model, tail, litellm_model.replace('/', '/', 1)):
        entry = cost_map.get(key)
        if isinstance(entry, dict):
            return entry
    return {}


def provider_models_entry(listing, litellm_model):
    """Pick this model's row from an OpenRouter/OpenAI-style GET /models body."""
    rows = listing.get('data') if isinstance(listing, dict) else listing
    if not isinstance(rows, list):
        return {}
    tail = litellm_model.split('/', 1)[-1]
    for row in rows:
        if isinstance(row, dict) and row.get('id') in (litellm_model, tail):
            return row
    return {}


def static_extract(name, litellm_params=None, model_info=None, cost_map=None, provider_entry=None):
    """-> (facts, static_meta). `facts` merge into a card; meta is admin-only."""
    litellm_params = litellm_params or {}
    info = dict(model_info or {})
    litellm_model = litellm_params.get('model') or name
    raw = cost_map_lookup(cost_map, litellm_model)
    merged = {**raw, **{k: v for k, v in info.items() if v is not None}}
    hint = _hints(' '.join([name, litellm_model]))
    ops, meta = {}, {'sources': []}

    mode = merged.get('mode')
    if mode == 'image_generation' or merged.get('output_modality') == 'image':
        ops['generate'] = cap(True, 'declared', 0.9)
        meta['sources'].append('litellm.mode')

    endpoints = merged.get('supported_endpoints')
    if isinstance(endpoints, list) and endpoints:
        meta['sources'].append('litellm.supported_endpoints')
        edits = any('/images/edits' in str(e) for e in endpoints)
        ops['edit'] = cap(edits, 'declared', 0.85)
    input_mods = merged.get('supported_modalities')
    if isinstance(input_mods, list) and 'edit' not in ops:
        meta['sources'].append('litellm.supported_modalities')
        ops['edit'] = cap('image' in input_mods, 'inferred', 0.6)

    sizes = _sizes_from(merged.get('supported_sizes') or merged.get('sizes'))
    if sizes:
        meta['sources'].append('litellm.sizes')
    sizes_source, sizes_conf = ('declared', 0.85) if sizes else ('inferred', 0.4)

    # Provider models API (OpenRouter style).
    arch = (provider_entry or {}).get('architecture') if isinstance(provider_entry, dict) else None
    if isinstance(arch, dict):
        meta['sources'].append('provider.architecture')
        ins = arch.get('input_modalities') or []
        outs = arch.get('output_modalities') or []
        if 'image' in outs:
            ops.setdefault('generate', cap(True, 'declared', 0.8))
        if isinstance(ins, list) and ins:
            ops['edit'] = cap('image' in ins, 'declared', 0.8)
    schema = _schema_props(provider_entry)
    if schema:
        meta['sources'].append('provider.schema')
        if schema & {'mask', 'mask_image', 'mask_url'}:
            ops['inpaint'] = cap(True, 'declared', 0.8)
        if schema & {'image', 'image_url', 'input_image', 'init_image', 'image_input'}:
            ops.setdefault('edit', cap(True, 'declared', 0.7))
        if schema & {'image_urls', 'input_images', 'images', 'reference_images'}:
            ops['multi_image'] = cap(True, 'declared', 0.7, max_inputs=4)
        if schema & {'aspect_ratio'}:
            meta['native_aspect_ratio_param'] = True
        if schema & {'num_outputs', 'num_images', 'n'}:
            ops['variations'] = cap(True, 'declared', 0.6)

    # Name-family hints: only fill what nothing better said.
    def hinted(op, flag=True, conf=0.4, **extra):
        if hint.get(op) and op not in ops:
            ops[op] = cap(flag, 'inferred', conf, **extra)
    if 'edit' in hint and 'edit' not in ops:
        ops['edit'] = cap(bool(hint['edit']), 'inferred', 0.45)
    for op in ('inpaint', 'outpaint', 'reference_style', 'upscale', 'remove_background', 'variations'):
        hinted(op)
    if hint.get('multi_image') and 'multi_image' not in ops:
        ops['multi_image'] = cap(True, 'inferred', 0.4, max_inputs=int(hint['multi_image']))
    if hint.get('transparent') and 'transparent_output' not in ops:
        ops['transparent_output'] = cap(True, 'inferred', 0.4)
    if not sizes and hint.get('sizes'):
        sizes = list(hint['sizes'])
    if sizes:
        meta['sources'].append('name_hint' if sizes_source == 'inferred' else 'declared_sizes')
    facts = {'operations': ops}
    if sizes:
        facts['sizes'] = {'native': sizes, 'source': sizes_source, 'confidence': sizes_conf,
                          'aspect_ratios': sorted({ratio_of(s) for s in sizes if ratio_of(s)})}
    if hint.get('text'):
        facts['text_rendering'] = {'level': hint['text'], 'source': 'inferred', 'confidence': 0.35}
    if hint.get('quality'):
        facts['quality'] = hint['quality']
    if hint.get('max_n'):
        facts['max_n'] = int(hint['max_n'])
    if hint.get('formats'):
        facts['input'] = {'formats': hint['formats']}
    cost = merged.get('output_cost_per_image')
    if isinstance(cost, (int, float)) and cost > 0:
        facts['measured_cost_usd'] = float(cost)
        meta['cost_source'] = 'litellm.output_cost_per_image'
    if hint:
        meta['sources'].append('name_hint')
    meta['mode'] = mode
    return facts, meta


def _schema_props(entry):
    """Property names from a replicate/fal/HF-style input schema, if present."""
    if not isinstance(entry, dict):
        return set()
    for path in (('input_schema', 'properties'), ('openapi_schema', 'components', 'schemas', 'Input', 'properties'),
                 ('schema', 'input', 'properties'), ('parameters', 'properties')):
        node = entry
        for part in path:
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, dict):
            return set(node)
    return set()


def default_probe_sizes(facts, limit):
    """Candidate sizes to probe, declared/inferred first, bounded by `limit`."""
    from .service import SIZES
    seen = list((facts.get('sizes') or {}).get('native') or [])
    for size in SIZES:
        if size not in seen:
            seen.append(size)
    if DEFAULT_SIZE in seen:
        seen.remove(DEFAULT_SIZE)
    return [DEFAULT_SIZE] + seen[:max(0, limit - 1)]
