"""Owner-only card admin routes. Protected by the LiteLLM master key (the same
credential the mint admin routes use). Responses contain internal model names
and probe results and must never be exposed to app users."""
import hmac

from fastapi import Request
from fastapi.responses import JSONResponse


def mount_admin(app, manager, master_key, *, store=None, wake=None, refresh_prices=None):
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
        spent = store.spent_since(time.time() - 86400)
        runner = getattr(manager, 'runner', None)
        daily = getattr(runner, 'daily_cap', None)
        budget = {'probes_enabled': runner is not None, 'probe_spend_24h_usd': round(spent, 6),
                  'probe_daily_cap_usd': daily,
                  'probe_daily_left_usd': None if daily is None else round(max(0.0, daily - spent), 6),
                  'probe_per_call_cap_usd': getattr(runner, 'per_probe_cap', None)}
        return JSONResponse({'schema': 1, 'cards': out, 'probe_spend_24h_usd': spent, 'probe_budget': budget},
                            headers={'Cache-Control': 'no-store'})

    async def refresh(request: Request):
        """Re-read LiteLLM prices/discovery now (otherwise they refresh on their TTL)."""
        if not authorized(request):
            return JSONResponse({'error': {'code': 'forbidden'}}, status_code=403)
        if refresh_prices is not None:
            from starlette.concurrency import run_in_threadpool
            await run_in_threadpool(refresh_prices)
        return JSONResponse({'refreshed': refresh_prices is not None,
                             'priced': {c['model']: c.get('priced') for c in manager.cards()}},
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
    app.add_api_route('/images/admin/refresh-prices', refresh, methods=['POST'])
    app.add_api_route('/images/admin/reprobe', reprobe, methods=['POST'])
