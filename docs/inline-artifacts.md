# Inline artifacts and image generation

## Image generation

The built-in `generate_image` endpoint has been retired. It is absent from the
agent roster, Image Studio starts uninstalled, and stale calls return an explicit
unavailable result without network requests. Existing plugin-state hydration
clears stale installed flags because Image Studio no longer has executable backing.
Existing generated-image rows and `read_image` keep their original behavior.

No Ovid Cloud image-generation contract was established from the client gateway
integration (mint, model listing, chat, usage). No replacement endpoint is inferred
from OpenAI-compatible chat support. Built-in image generation has no configuration
or provider implementation yet. Independently configured, existing image MCP
integrations retain their own credentials and tool namespaces.

## Tool contract

```json
{
  "name": "render_html",
  "arguments": {
    "title": "Counter",
    "html": "<button id=counter>0</button>",
    "css": "button { padding: 1rem; color: rebeccapurple; }",
    "javascript": "document.getElementById('counter').onclick = function () { this.textContent = Number(this.textContent) + 1; };",
    "height": 320
  }
}
```

Only `html` is required. Unknown fields and non-string source fields are rejected.
The combined title/HTML/CSS/JavaScript UTF-8 payload is at most 64 KiB. Titles are
1–120 characters, height is clamped to 160–640 logical pixels, and each session is
limited to 16 artifacts and 512 KiB total source. The Android wrapper also enforces
a 512 KiB encoded-document bound before loading it.

The tool persists a versioned `htmlArtifact` on a dedicated chat message, with a
random identity and the **running** session's owner ID. A different session cannot
render that record. Invalid persisted records show a fallback. Artifacts follow
normal session persistence, deletion and transcript paging. Tool results/history
contain a summary, not executable source. A failed persistence attempt is reported
as unsaved. Plan mode retains its default-deny gate.

Markdown and plugin `render_html(markdown)` text do not activate this contract.

## Preview and isolation

The Android platform view is separate from browser tabs and Ovid's browser/native
automation registry. It displays real HTML, CSS and JavaScript in an opaque-origin
`srcdoc` frame with `sandbox="allow-scripts"`. Inline local interactions and data
images/fonts are supported. The frame cannot access its parent, cookies or storage.
CSP blocks external scripts/styles/images, fetch/XHR/WebSocket, workers, frames,
objects, forms and base URLs. Android independently denies resource fetches and
navigation, disables file/content/universal-file access, denies permissions,
popups, downloads, file selection, geolocation and native dialogs, and installs no
JavaScript bridge.

When Android WebView supports multiple profiles, each preview gets a fresh isolated
profile with cookies disabled, deleted on disposal. Older engines use an opaque
document with no network or origin/storage access; they do not get a separate
cookie-store instance. Browser/auth cookies are never cleared or modified.

WebRTC/WebTransport constructors are disabled with a non-replaceable document-start
script in every frame, because CSP alone is insufficient to prevent WebRTC sockets.
Engines lacking AndroidX `DOCUMENT_START_SCRIPT` support **do not execute** the
artifact and show a native fallback instead. No runtime dependency was added;
the existing AndroidX WebKit 1.12.0 is reused. AndroidX runner/JUnit dependencies
were added only to the instrumentation-test configuration.

The host offers collapse, expanded height and selectable source. Height is bounded
by the screen; inner content scrolls. Source/collapse/session changes remove the
native view. App pause immediately disposes the native document through a
Flutter-host-only channel (no JavaScript access), even when Flutter stops painting.
Resume creates a fresh view. Native disposal stops loading/JS and destroys the
WebView; renderer crashes show a fallback.

## Actual limitations

- Interactive preview is Android-only and requires a sufficiently recent WebView.
  Other platforms show a source fallback.
- Source persists; transient JavaScript/DOM state resets when the view is disposed.
- Payload/height/count bounds do not impose a CPU or heap quota on arbitrary JS.
  A busy document can make its renderer unresponsive. There is no script watchdog.
- A killed process can leave an empty, isolated artifact profile directory behind;
  normal disposal deletes it. No browser-profile cleanup behavior is changed.
- Host widget tests use platform-channel fakes. The Chromium test executes the
  production wrapper and verifies actual interaction and denial of I/O, but is not
  an Android WebView device test. Instrumentation tests cover native settings,
  denied routes/permissions, profile selection and disposal and need a device.

## Verification commands

```sh
/root/flutter/bin/flutter test --no-pub --concurrency=2 \
  test/render_tools_test.dart test/html_artifact_test.dart \
  test/html_artifact_widget_test.dart test/html_artifact_browser_test.dart \
  test/html_artifact_chat_test.dart
/root/flutter/bin/flutter analyze --no-pub
# From android/ with the normal local Firebase build configuration:
gradle :app:testDebugUnitTest --tests '*HtmlArtifactPolicyTest' \
  :app:compileDebugAndroidTestKotlin --max-workers=2
gradle :app:connectedDebugAndroidTest --max-workers=2
```

The Chromium host test uses `CHROME_EXECUTABLE` or `/usr/bin/google-chrome` and
explicitly skips if neither exists. It uses a temporary profile and a local HTTP
sink to detect attempted requests. Its `--no-sandbox` flag is only for headless
Chrome in the root-run test environment, not part of the application's WebView.

### Results in this worktree (2026-10-03)

- `/root/flutter/bin/flutter test --no-pub --concurrency=2 --reporter=expanded`:
  **3,008 passed, 4 skipped, 0 failed** (9m48s).
- Focused artifact/tool/persistence/plugin regression run: **91 passed**.
- `/root/flutter/bin/flutter analyze --no-pub`: **No issues found**.
- `:app:testDebugUnitTest --tests '*HtmlArtifactPolicyTest'
  :app:compileDebugAndroidTestKotlin --max-workers=2`: **2 policy tests passed;
  instrumentation compilation passed**.
- Full Android JVM suite: **45 passed, 1 failed**. The unrelated existing
  `SecurityCheckTest` calls unmocked `android.os.Debug.isDebuggerConnected`.
- Device execution was not performed: `adb devices` reported no connected device.
- Android compilation initially required the missing local `google-services.json`.
  A synthetic, noncredential test-only file was used for compilation/JVM tests
  and removed afterward. These results do not verify Firebase or image services.

The Gradle executable used was
`/root/.gradle/wrapper/dists/gradle-9.1.0-all/7wzd0jkjit61aq2p43wpjgij9/gradle-9.1.0/bin/gradle`;
this checkout does not include a `gradlew` launcher.
