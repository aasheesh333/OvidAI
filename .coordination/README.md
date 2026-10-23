# Shared coordination state

Two OpenCode sessions edit this repo. This directory is how they talk.

- `claims.json` — which paths each session is actively editing right now.
- `inbox/<session>.md` — messages for a session to read before it starts work.

Rules: append, never rewrite another session's claim. A claim older than 4
hours is stale and may be taken.
