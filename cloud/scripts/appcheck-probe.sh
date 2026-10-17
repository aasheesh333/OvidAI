#!/usr/bin/env bash
# P10 Task 9 — App Check / auth-surface probe.
#
# Run against a gateway started with OVID_AUTH_MODE=firebase
# (`cloud/scripts/staging.sh up --auth firebase` exposes it at
# http://127.0.0.1:18082). Every request below MUST be rejected with
# HTTP 401 and the generic `{"error":{"code":"unauthenticated"}}` envelope —
# never 200 (a bypass) and never 5xx (a crash/oracle).
#
# Cases:
#   a. no headers at all                    → 401 (no verifier call)
#   b. garbage Bearer                       → 401 (App Check missing first)
#   c. valid-looking JWT, no App Check hdr  → 401 (App Check is mandatory)
#
# Usage:
#   cloud/scripts/appcheck-probe.sh [BASE_URL]
#   BASE_URL=http://127.0.0.1:18082 cloud/scripts/appcheck-probe.sh
#
# Exit code: 0 = every case PASS; 1 = at least one FAIL; 2 = usage/transport.

set -uo pipefail

BASE_URL="${1:-${BASE_URL:-http://127.0.0.1:18082}}"
BASE_URL="${BASE_URL%/}"
ENDPOINT="${ENDPOINT:-${BASE_URL}/cloud/v1/sessions}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# A structurally plausible (but unsigned/bogus) JWT: three base64url segments.
b64url() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'
}
JWT_HEADER="$(b64url '{"alg":"RS256","typ":"JWT","kid":"probe-key"}')"
JWT_PAYLOAD="$(b64url '{"aud":"probe","iss":"https://securetoken.google.com/probe","sub":"probe-user","iat":1700000000,"exp":4102444800}')"
JWT="${JWT_HEADER}.${JWT_PAYLOAD}.cHJvYmUtc2lnbmF0dXJl"

FAILURES=0

# probe <name> <curl args...>
probe() {
  local name="$1"
  shift
  local body="${TMP_DIR}/${name}.body"
  local status
  status="$(curl -sS --max-time 10 -o "${body}" -w '%{http_code}' "$@" 2>"${TMP_DIR}/${name}.err")"
  local curl_rc=$?
  if [ "${curl_rc}" -ne 0 ]; then
    printf 'FAIL  %-40s transport error (curl rc=%s): %s\n' \
      "${name}" "${curl_rc}" "$(tr '\n' ' ' <"${TMP_DIR}/${name}.err")"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local reason=""
  if [ "${status}" != "401" ]; then
    reason="expected HTTP 401, got ${status}"
  elif ! grep -Eq '"code"[[:space:]]*:[[:space:]]*"unauthenticated"' "${body}"; then
    reason="expected JSON error.code=unauthenticated, got: $(head -c 200 "${body}" | tr '\n' ' ')"
  fi

  if [ -z "${reason}" ]; then
    printf 'PASS  %-40s HTTP %s unauthenticated\n' "${name}" "${status}"
  else
    printf 'FAIL  %-40s %s\n' "${name}" "${reason}"
    FAILURES=$((FAILURES + 1))
  fi
}

JSON=(-H 'Content-Type: application/json' --data '{}')

echo "appcheck-probe: ${ENDPOINT}"
probe "no-headers" \
  -X POST "${ENDPOINT}" "${JSON[@]}"
probe "garbage-bearer" \
  -X POST "${ENDPOINT}" "${JSON[@]}" -H 'Authorization: Bearer not-a-real-token'
probe "valid-looking-jwt-no-appcheck" \
  -X POST "${ENDPOINT}" "${JSON[@]}" -H "Authorization: Bearer ${JWT}"

if [ "${FAILURES}" -ne 0 ]; then
  echo "appcheck-probe: FAIL (${FAILURES} case(s) failed)"
  exit 1
fi
echo "appcheck-probe: PASS (3/3 cases rejected with 401 unauthenticated)"
exit 0
