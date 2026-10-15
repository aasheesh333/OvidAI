#!/usr/bin/env bash
# Start disposable Postgres + Redis for local development / integration tests.
# Idempotent: creates the containers if missing, starts them if stopped,
# otherwise leaves them alone. ONLY ever touches the containers named below —
# never any other container on this (production) host.
#
# Usage: bash cloud/scripts/dev-services.sh
# Prints TEST_DATABASE_URL / TEST_REDIS_URL on success.
set -euo pipefail

PG_CONTAINER=ovid-dev-pg
REDIS_CONTAINER=ovid-dev-redis

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

ensure_container() {
  local name="$1"
  shift
  if ! container_exists "$name"; then
    docker run -d --name "$name" "$@" >/dev/null
  elif ! container_running "$name"; then
    docker start "$name" >/dev/null
  fi
}

ensure_container "$PG_CONTAINER" \
  -e POSTGRES_PASSWORD=ovid \
  -p 127.0.0.1:5433:5432 \
  postgres:16-alpine

ensure_container "$REDIS_CONTAINER" \
  -p 127.0.0.1:6390:6379 \
  redis:7-alpine

wait_for() {
  local desc="$1"
  shift
  local i
  for i in $(seq 1 60); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "dev-services: timed out after ${i}s waiting for $desc" >&2
  exit 1
}

wait_for "postgres ($PG_CONTAINER)" \
  docker exec "$PG_CONTAINER" pg_isready -U postgres -h 127.0.0.1
wait_for "redis ($REDIS_CONTAINER)" \
  docker exec "$REDIS_CONTAINER" redis-cli ping

echo "TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres"
echo "TEST_REDIS_URL=redis://127.0.0.1:6390"
