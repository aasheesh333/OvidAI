#!/usr/bin/env bash
# Start disposable Postgres + Redis for local development / integration tests.
# Idempotent: creates the containers if missing, starts them if stopped,
# otherwise leaves them alone. ONLY ever touches the containers named below —
# never any other container on this (production) host.
#
# A container that exists but publishes DIFFERENT host ports than the ones
# below (e.g. left over from an older script revision, or created by hand) is
# stale for our purposes: reusing it would silently point the test suite at
# the wrong port, so it is removed and recreated instead.
#
# Usage: bash cloud/scripts/dev-services.sh
# Prints TEST_DATABASE_URL / TEST_REDIS_URL on success.
set -euo pipefail

PG_CONTAINER=ovid-dev-pg
REDIS_CONTAINER=ovid-dev-redis

PG_HOST_PORT=5433
REDIS_HOST_PORT=6390

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

# True when the container publishes 127.0.0.1:$host_port -> $container_port.
# Uses inspect (works for stopped containers too; `docker port` does not).
container_has_published_port() {
  local name="$1" host_port="$2" container_port="$3"
  docker inspect \
    --format "{{with index .HostConfig.PortBindings \"${container_port}/tcp\"}}{{range .}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}" \
    "$name" 2>/dev/null | grep -q "127\.0\.0\.1:${host_port}\b"
}

ensure_container() {
  local name="$1" host_port="$2" container_port="$3"
  shift 3

  if ! container_exists "$name"; then
    docker run -d --name "$name" "$@" >/dev/null
    return
  fi

  if ! container_has_published_port "$name" "$host_port" "$container_port"; then
    echo "dev-services: $name publishes ports other than 127.0.0.1:${host_port}->${container_port}; recreating" >&2
    docker rm -f "$name" >/dev/null
    docker run -d --name "$name" "$@" >/dev/null
    return
  fi

  if ! container_running "$name"; then
    docker start "$name" >/dev/null
  fi
}

ensure_container "$PG_CONTAINER" "$PG_HOST_PORT" 5432 \
  -e POSTGRES_PASSWORD=ovid \
  -p "127.0.0.1:${PG_HOST_PORT}:5432" \
  postgres:16-alpine

ensure_container "$REDIS_CONTAINER" "$REDIS_HOST_PORT" 6379 \
  -p "127.0.0.1:${REDIS_HOST_PORT}:6379" \
  redis:7-alpine

wait_for() {
  local desc="$1"
  shift
  local start=$SECONDS
  local _
  for _ in $(seq 1 60); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  # Report true elapsed wall-clock seconds, not the loop counter: each failed
  # probe also costs time, so the counter understates the wait.
  echo "dev-services: timed out after $((SECONDS - start))s waiting for $desc" >&2
  exit 1
}

wait_for "postgres ($PG_CONTAINER)" \
  docker exec "$PG_CONTAINER" pg_isready -U postgres -h 127.0.0.1
wait_for "redis ($REDIS_CONTAINER)" \
  docker exec "$REDIS_CONTAINER" redis-cli ping

echo "TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:${PG_HOST_PORT}/postgres"
echo "TEST_REDIS_URL=redis://127.0.0.1:${REDIS_HOST_PORT}"
