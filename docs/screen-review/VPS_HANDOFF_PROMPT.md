Paste everything below into the Claude Code session running on the VPS (in /opt/ovid-gateway).

---

You are on the Ovid production gateway VPS (`/opt/ovid-gateway`: docker compose with Caddy, mint (FastAPI verifier, port 8090), LiteLLM (port 4000), Postgres, Redis). Bug: the Ovid app cannot load "Auto" and manual models. `GET https://api.ovidsi.com/v1/models` returns `503 {"error":{"code":"catalog_unavailable"}}` for every request.

Known from the code (repo aasheesh333/OvidAI, branch `fix/model-catalog-recovery`):
- Caddy routes `/v1/models` to mint. Mint mounts `server/images/verifier.py`, and its `models` handler forwards the user's bearer key to LiteLLM `GET /v1/models`. The old handler turned EVERY failure into 503 without logging, including LiteLLM 401 (bad key).
- Most likely cause: LiteLLM rejects the user's stored virtual key (expired, deleted, blocked or over budget). `/mint` keeps returning the same Redis `user:{uid}:key`, so the app is stuck.

Rules: work read-only first. Never print secret values (keys, master key, env values). Show env var NAMES only. Ask me before restarting containers or changing files, and back up any file before editing it.

Step 1 — Diagnose and report:
1. `docker compose ps`; `docker compose logs --since 6h mint | tail -200`; `docker compose logs --since 6h litellm | grep -iE "models|401|403|budget|expired|error" | tail -100`.
2. Check that LiteLLM is healthy and that the model list exists: call `http://127.0.0.1:4000/v1/models` with the master key (from the env, never echo it). Confirm `auto` and the manual models are present. Also check the LiteLLM config or DB for the `auto` alias.
3. Pick a real user key from Redis (`user:*:key`; show only the first 6 chars). Call LiteLLM `/v1/models` with it and print only the status code. Call `/key/info?key=<keyid from user:<uid>:keyid>` with the master key and print only: expires, blocked, spend, max_budget, models.
4. Call the same user key through mint (`http://127.0.0.1:8090/v1/models`) and through `https://api.ovidsi.com/v1/models` (status codes only).
5. Find the live mint source (e.g. `/opt/ovid-gateway/verifier/mint.py`) and show me how `/mint` decides whether to reuse or re-issue a key.
Report the root cause in plain words before changing anything.

Step 2 — Fix (after I approve):
a. Deploy the patched `server/images/verifier.py` from branch `fix/model-catalog-recovery` into the mint image, the same way it was deployed before (see `server/images/deploy/README.md` and `docs/image-capacity-incident-2026-10-08.md`). After deploy: no token → 401; rejected key → 401 `key_invalid`; valid key → 200 with `auto` + manual models.
b. In live `mint.py` `/mint`: before returning a cached Redis key, validate it via LiteLLM `/key/info`. If it is missing, blocked or expired, or LiteLLM returns 404/401, generate a fresh key (same models, metadata and duration as today), update Redis `user:{uid}:key` and `user:{uid}:keyid`, and delete the old key. Do NOT re-mint just because the budget is exhausted; the app shows a limit message for 402.
c. If the `auto` alias or manual models are missing from LiteLLM, show me the config and propose the fix.
d. Do not change App Check behaviour.

Step 3 — Verify end to end and give me a short summary of what changed, plus rollback commands.

Security: I shared the root password in a chat. After this is done, help me rotate it and switch SSH to key-only (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`) without locking me out: test the key login in a second terminal first.
