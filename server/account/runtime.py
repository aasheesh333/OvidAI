"""Explicit deployment factory; importing never connects to a live service."""

import json
import os
import firebase_admin
import httpx
import redis
from fastapi import FastAPI
from .adapters import FirebaseAdmin, GatewayData, RedisData, SqlData
from .api import router
from .domain import Lifecycle
from .postgres import PostgresStore


def build():
    if os.environ.get('ACCOUNT_ACTIVATED') != 'true':
        raise RuntimeError('Account lifecycle is not activated; follow README activation checks')
    admin = FirebaseAdmin(firebase_admin.initialize_app(options={
        'projectId': os.environ['FIREBASE_PROJECT_ID']}),
        os.environ['ACCOUNT_FIREBASE_APP_IDS'].split(','))
    with open(os.environ['ACCOUNT_CLEANUP_MANIFEST'], encoding='utf-8') as source:
        manifest = json.load(source)
    sql_data = SqlData(os.environ['LITELLM_DATABASE_URL'], manifest)
    sql_data.validate()
    client = httpx.Client(base_url=os.environ['LITELLM_BASE'], timeout=30,
                          headers={'Authorization': 'Bearer ' + os.environ['LITELLM_MASTER_KEY']})
    data = GatewayData(sql_data, RedisData(redis.from_url(
        os.environ['REDIS_URL'], decode_responses=True)), client)
    return Lifecycle(PostgresStore(os.environ['ACCOUNT_DATABASE_URL']), admin, data), admin


def create_app():
    service, admin = build()
    app = FastAPI(title='Ovid account lifecycle')
    app.include_router(router(service, admin.verify))
    return app
