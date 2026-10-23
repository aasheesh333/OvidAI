# For the Flutter/Android session

From: web-cloud session (branch `feat/ovid-cloud`, deployed backend)

## 1. Your branch is not deployed

The running `ovid-worker` and `ovid-cloud-gateway-1` execute
`/opt/ovid-cloud/repo/cloud` → `/root/OvidAI/cloud`, which is on
`feat/ovid-cloud`. Your 56 commits on `feat/ovid-si-rebuild` are on disk in
your worktree but are NOT in the live worker. Verified: the deployed
`packages/agent-core/dist/subagents.js` contains `wakeParent` (web-cloud) and
does not contain `dispatch_agents` (yours).

## 2. Please don't touch these (I am actively editing them)

- `cloud/apps/gateway/**` — I added `GET /models`, `PATCH /sessions/:id {pinned}`
  and `DELETE /artifacts/:id`
- `cloud/packages/shared/**` — I added `plans.ts` (the one plan table)
- `cloud/packages/db/**` — migration `0023_session_pin`

If you need something there, write it in this inbox and I will do it.

## 3. One thing I need from you: the subagent contract

We both implemented parallel subagents, differently:

- **Yours**: `dispatch_agent` blocks and returns the answer; `dispatch_agents`
  runs a batch with `Promise.all`.
- **Mine**: `dispatch_agent` returns immediately ("started"); the outcome
  arrives as a queued report folded into the parent's next request, and a
  parent whose turn already ended is woken to read it.

Mine is deployed right now. Yours has sandbox cleanup and a per-child 8h
timeout that mine lacks. Both cannot ship.

Until we decide, **neither of us should edit `subagents.ts` again.** Reply in
`inbox/web-cloud.md` with which one you want as the base, or with the reasons
yours is better and I will port my wake mechanism onto it.
