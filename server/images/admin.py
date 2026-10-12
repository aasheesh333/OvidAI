"""Owner-only card admin routes. Protected by the LiteLLM master key (the same
credential the mint admin routes use). Responses contain internal model names
and probe results and must never be exposed to app users."""
import hmac

from fastapi import Request
from fastapi.responses import JSONResponse


def mount_admin(app, manager, master_key, *, store=None, wake=None):
    store = store or manager.store

    def authorized(request: Request):
        header = request.headers.get('authorization', '')
        token = header.split(' ', 1)[1] if header.lower().startswith('bearer ') else ''
        return bool(master_key) and hmac.compare_digest(token.encode(), master_key.encode())

    async def cards(request: Request):
        if not authorized(request):
            return JSONResponse({'error': {'code': 'forbidden'}}, status_code=403)
        out = []
        for card in manager.cards():
            out.append({**card, 'history': store.history(card['model']),
                        'probe_state': store.probe_state(card['model'])})
        import time
        return JSONResponse({'schema': 1, 'cards': out, 'probe_spend_24h_usd': store.spent_since(time.time() - 86400)},
                            headers={'Cache-Control': 'no-store'})

    async def reprobe(request: Request):
        if not authorized(request):
            return JSONResponse({'error': {'code': 'forbidden'}}, status_code=403)
        try:
            body = await request.json()
            model = body['model']
            if not isinstance(model, str):
                raise ValueError()
        except Exception:  # noqa: BLE001
            return JSONResponse({'error': {'code': 'invalid_request'}}, status_code=400)
        name = next((c['model'] for c in manager.cards() if model in (c['model'], c['slug'])), None)
        if name is None or not manager.reprobe(name):
            return JSONResponse({'error': {'code': 'unknown_model'}}, status_code=404)
        if wake:
            wake()
        return JSONResponse({'queued': name}, status_code=202)

    app.add_api_route('/images/admin/cards', cards, methods=['GET'])
    app.add_api_route('/images/admin/reprobe', reprobe, methods=['POST'])
