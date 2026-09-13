# Reliability Bug Bundle — Design

**Date:** 2026-09-13
**Status:** Approved for implementation (product direction: fix the concrete
failures reported on-device).

## 1. Goal

Close the concrete, reproducible reliability failures reported while using Ovid
on-device, without changing product surface: the sandbox `apt`/`ovid-pkg` noise,
inbuilt plugin/MCP install routing, marketplace parsing, provider/model identity
collisions, and the `apt` HTTPS root cause already fixed in the working tree.

## 2. Outcomes

1. `apt update` in the sandbox terminal does not print a misleading
   `curl: (22) … 404` for the `.xz` index probe; the index still loads.
2. The `Acquire::https::CRLFile` root cause is committed (no mirror/retry loop
   burning on "does not have a Release file").
3. Clicking install on an **inbuilt** plugin/MCP installs/enables it directly;
   the "Add marketplace" sheet appears only for rows that genuinely need a
   source.
4. `catalog_add_marketplace` accepts the Claude-Code marketplace object form
   (`source: {source, url|repo, ref}`) and reports the real parse error when a
   file is found but malformed (never a false "not found").
5. Two providers exposing the same model id never silently conflict; the
   session's `providerId` is authoritative and ambiguity is not resolved by
   arbitrary first-match.
6. `gh` (GitHub CLI) install failure is reproduced and fixed or honestly
   documented with the exact cause.

## 3. Non-Goals

- No redesign of the plugin runtime, marketplace UI, or provider picker.
- No new mirror pool or TLS strategy beyond removing the bad CRLFile directive.
- No on-device claims; device rows stay `NOT EXECUTED` without hardware.

## 4. Current Failure Model (evidence)

### 4.1 ovid-pkg `.xz` probe noise
`sandbox_pkg.dart:125-135` `_fetch_index` tries `"$_url.xz"` first. The Termux
mirror serves `Packages.gz` (HTTP 200) but **not** `Packages.xz` (HTTP 404,
verified 2026-09-13). curl `-f` exits non-zero and prints
`curl: (22) The requested URL returned error: 404` to stderr before the `.gz`
fallback succeeds — so the log looks broken even though it works.

### 4.2 apt CRLFile
`sandbox_service.dart:975-976` wrote `Acquire::https::CRLFile "$p/etc/tls/cert.pem"`.
apt parses CRLFile as a certificate-revocation list; pointing it at the CA bundle
fails before the TLS handshake (`Base64 decoding error`) and apt reports
`does not have a Release file` on every mirror. Reproduced on host apt 2.8.3;
removing the line fetches `InRelease` normally. Fix already in the working tree;
this project commits it.

### 4.3 Inbuilt plugin/MCP install routing
`plugins_screen.dart:1350-1357`: the detail Install button branches only on
`plugin.source != null → githubPluginSourceFromSourceString`; otherwise it opens
`showPluginAddSheet`. Inbuilt seeds (`state.dart:6174-6361`) have
`source == null, marketplace == null, runtimeId == null`, so every inbuilt row
falls into the add-marketplace sheet.

### 4.4 Marketplace parse
`state.dart:5139-5265` `_mergeMarketplaceCatalog` casts `p['source'] as String?`
(`:5159`, `:5181`). The Claude-Code marketplace uses an **object**
`{"source":"url","url":"…"}` (or `{"source":"github","repo":"…","ref":"…"}`),
so the cast throws inside the fetch `try`, is swallowed by
`catch (_) { continue; }` (`:4642-4643`), and the method returns the generic
`No marketplace.json found …` (`:4648-4651`) even though the file was fetched.

### 4.5 Provider/model identity
`state.dart:3887-3894` `_inferProviderId(model)` returns the **first** provider
whose `models` contains the bare id. Used at `:2775`, `:3030`, `:3917-3924`,
`:4000-4006`. If two providers expose the same id and `lastSelectedProviderId`
is absent, the wrong provider is silently chosen.

### 4.6 `gh` install
Not yet reproduced. `gh` exists in the mirror index; the failure needs the
on-device stderr. Investigation task.

## 5. Design

### 5.1 ovid-pkg index probe order
Reorder `_fetch_index` to try **`.gz` first**, then `.xz`, then plain, and
redirect expected probe failures (`2>/dev/null`) so a working fallback is not
reported as an error. Keep the `_index_ok` freshness gate.

### 5.2 CRLFile
Already removed in `sandbox_service.dart`. Add the regression pin (done in
`studio_git_reliability_test.dart`) and commit.

### 5.3 Inbuilt install routing
In `plugins_screen.dart` Install button:
- parseable `source` → existing source install;
- **inbuilt row** (author `ovidai`/`you`/`sandbox`/`termux`/`modelcontextprotocol`
  or a known inbuilt roster id, and `source == null`) → install/enable directly
  via the existing `installPlugin`/enable path, with an honest result message;
- only genuinely source-less **marketplace-unknown** rows open the add sheet.

The exact "enable" semantics for an inbuilt row are pinned by the implementation
task after reading `AppState.installPlugin` (`state.dart:1580-1659`) and the
seed.

### 5.4 Marketplace schema
`_mergeMarketplaceCatalog` accepts `source` as either a `String` or a `Map`:
- `{source:"url", url}` → the URL (strip `.git`);
- `{source:"github", repo, ref?}` → `repo` (+ ref as a raw subpath when present);
- `{source:"local", path}` → relative dir.
Parse failures surface the real exception text (still no crash); a file that was
found but malformed must not be reported as "not found".

### 5.5 Provider/model identity
- Keep `(providerId, model)` authoritative; the picker already keys on it.
- `_inferProviderId` returns null when **more than one** provider contains the
  id, instead of first-match; callers keep the stored `providerId` when present
  and otherwise surface a chooser/ambiguity rather than guessing.
- Do not silently reassign a session's provider once set.

### 5.6 gh install
Investigate with a real on-device (or sandbox-equivalent) run; fix the root
cause or document the exact blocker.

## 6. Testing

- `ovid_pkg_test.dart`: index fetch tries `.gz` before `.xz`; a `.xz` 404 does
  not print an error when `.gz` succeeds (host `/bin/sh` stub).
- `studio_git_reliability_test.dart`: CRLFile pin (present).
- Plugins: inbuilt row install routes to direct install, not the add sheet.
- Marketplace: object-form `source` merges; malformed file surfaces the parse
  error, not "not found".
- Provider: duplicate model id does not resolve to first-match.
- Full `flutter test` + `flutter analyze` green.

## 7. Decisions

- `.gz` is the primary Termux index compression; `.xz` is best-effort.
- Inbuilt rows install directly; the marketplace sheet is for unknown sources.
- The marketplace parser is permissive on `source` shape, strict on reporting.
- Provider identity is `(providerId, model)`; inference never guesses on
  ambiguity.
