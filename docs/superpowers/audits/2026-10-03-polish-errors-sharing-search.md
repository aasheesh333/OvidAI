# P2 errors / P4 sharing and Studio search audit

Workspace: `/tmp/opencode/wt-polish`, branch `wip/polish`. No commits or pushes.

## Changes and reproduced evidence

- **Browser tip:** navigation to Google accounts created a SnackBar in the
  regression test. Removed the proactive tip and its dead notice/copy helpers.
  The purported external-browser toolbar option was missing: the existing
  `open_in_browser` icon called `_nav` (in-app navigation). Added an explicit
  `Open in browser` toolbar action using the existing external launcher.
  No User-Agent or cookie behavior changed.
- **Error presentation:** the run-failure branch appended timeout advice to
  every error. Replaced it with `ModelFailure` (kind, factual headline,
  recovery action, deduplicated detail). HTTP 403 no longer asserts that the
  API key expired; 404 does not assume it is the model rather than endpoint.
  Timeout hooks record facts only, leaving recovery advice in one place.
- **Stale cause:** `lastError ??=` in empty-stream handling could retain a
  previous attempt's timeout. Each attempt now resets the error, and empty
  completion records its own result. Local HTTP tests exercise both API formats.
- **Hidden cause:** an OpenAI-compatible SSE `error` object with no `choices`
  was discarded as an empty chunk. A real local HTTP fixture reproduced
  `quota exhausted` becoming `empty response`; the provider message now survives.
  Malformed JSON-only streams now report the observed malformed-payload count
  instead of claiming an unexplained empty response. Mixed streams still keep
  usable output; no broad parser/retry rewrite.
- **Sharing:** Settings → Share Ovid sends the existing app website. Chat’s
  Share menu offers a UTF-8 transcript file and a local-file picker; generated
  image Share uses the same service. Native code stages snapshots under cache,
  including files outside FileProvider roots, then sends `ACTION_SEND` through
  a chooser with MIME type, `EXTRA_STREAM`, ClipData and read-only URI grants.
  Copies/writes run off the main thread. Old snapshots are cleaned on the next
  share after one day, rather than deleted before the recipient reads them.
  No public chat-link backend was implemented; there are no synthetic links.
- **Studio find:** searching `alpha`, navigating to its second result, then
  changing the query to `beta` incorrectly selected the second beta. A new
  query now starts at result one. Query caret/composing notifications do not
  reset the result. Existing next/previous/wrap/no-match tests pass. The Unicode
  offset probe already passed, so that matching algorithm was not changed.
  This tree has in-file find, not a repository filename-filter/search UI.
  No binding, working-directory, tree, or repo-selection implementation changed.

## Coordinate repetition investigation

Observed source boundaries:

1. `OvidAccessibilityService.kt` constructs each bounds payload using
   `listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)`, with node/depth
   caps. It does not produce a variable-length repeated coordinate array.
2. `DeviceControlService._formatNode` emits one `bounds=(...)` rectangle per
   row; multiple overlapping nodes can legitimately have identical bounds.
   The behavior test uses two nodes with equal rectangles and sees two rows.
3. `_callLlmOnce` appends each `delta.content` once; Anthropic uses `text_delta`.
   A local HTTP stream containing `(10,20) ` twice yields that exact pair twice
   in both returned content and the visible message, with no tool-input bounds
   copied into the answer. Existing failed-attempt/discard tests also pass.

The existing Dart comment suggesting Android can return hundreds of bounds
values is not supported by this native serializer. No real failing stream,
device capture, or incident transcript was supplied or available in this run.
**Actual incident attribution remains unresolved:** these fixtures establish
boundary behavior, not that the reported incident was model degeneration.
No speculative repetition suppression, coordinate stripping, or stream stopping
was introduced. A future reproduction needs the provider deltas and the
corresponding device-read tool row from the same turn to establish provenance.

## Verification

- `/root/flutter/bin/flutter test --no-pub --concurrency=2` across 17 selected
  error/retry, sharing, browser, Studio, chat-layout/disclosure and device-icon
  test files: **136 passed**.
- Resource-backed Android tests (`NativeShareTest`, Robolectric API 28):
  **4 passed, 0 failures**. Covers real FileProvider URI resolution/readback,
  out-of-root image staging, MIME, UTF-8 transcript, chooser ClipData/read grants,
  text-only payload and missing/directory rejection.
- Native command:
  `gradle :app:testDebugUnitTest --tests com.dhanuk.ovidai.NativeShareTest --max-workers=2`.
  Initial build required missing `google-services.json`; a clearly fake local
  debug-only fixture enabled unit-test resource generation and was removed
  afterward. It is not part of the deliverable. A normal Android build still
  requires the project's real Firebase configuration. The build also exposed
  an AGP 9 host-test asset dependency; the test task now declares that dependency.
- Android result: `build/app/test-results/testDebugUnitTest/TEST-com.dhanuk.ovidai.NativeShareTest.xml`.
- Targeted Dart analysis and `git diff --check` run before handoff.

## Remaining limitations / bugs

- Reported production coordinate repetition is not reproduced or diagnosed.
- An HTTP 200 response in an unrecognized, non-SSE format still has no usable
  output; the empty-response action asks the user to check endpoint/API format.
  This audit does not add support for arbitrary provider response protocols.
- Existing local-file **Open** uses `launchUrl(Uri.file(path))`, separate from
  Share. It may fail for private files on Android. This audit fixes sharing,
  not file opening.
- Real recipient-app/device share-sheet interaction was not exercised; native
  payload/grant/readback behavior was exercised under Robolectric.
- Repository-wide filename search/filter is absent, rather than a reproduced
  broken filter in this version. Studio binding/cwd work remains with P1-A.
