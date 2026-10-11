# 08 — Sharing, private sync, collaboration, design system

## Scope
`lib/ui/shared_conversation_screen.dart`, `lib/ui/share_actions.dart`,
`lib/ui/conversation_share_sheet.dart`, `lib/ui/private_sync_settings_screen.dart`,
`lib/ui/private_conversation_screen.dart`, `lib/ui/private_activity_screen.dart`,
`lib/ui/collaboration_screen.dart`, `lib/ui/widgets/aether_primitives.dart`,
`lib/ui/widgets/ovid_mark.dart`, `lib/core/theme.dart` (plus the `lib/core/`
services they call, followed to confirm bugs).

## Goal
See `README.md`. For this group additionally: color tokens and WCAG contrast
(light + dark, computed), typography scale and minimum sizes, primitive tap
targets, theming approach, consistency, and localization rollout prerequisites.

## Status
complete (sections 1–10 + group summary)

---

## 1. SharedConversationScreen — `lib/ui/shared_conversation_screen.dart`

**What it is / how reached.** Read-only viewer for a public share link
(`https://ovidsi.com/s/<43-char token>`). Pushed by `openShareWithNavigator`
(`lib/main.dart:16-26`) from App Links, the initial link, or a deferred
install-referrer link. Loads `/s/<token>.json` (`ConversationShareService.publicSnapshot`,
`lib/core/conversation_share_service.dart:249`), renders every message, and offers
"Continue in Ovid Si", which signs in if needed, calls `POST /shares/<id>/fork`
and imports the messages locally (`AppState.importSharedMessages`,
`lib/core/state.dart:6364`). This is the main viral acquisition path.

**Findings**
- **P1 · UX · `shared_conversation_screen.dart:93-96`.** Messages have no role
  label. Each one is a plain `AetherCard(child: Text(content))`, so the user
  cannot tell their prompt from the assistant reply. The share sheet preview
  does label roles (`conversation_share_sheet.dart:250-253`), so viewer and
  preview disagree. **Fix:** render a "You"/"Assistant" label (or chat bubbles
  aligned like the chat screen) above each card, using the same widget as the
  sheet preview.
- **P1 · UX · `:95`.** Content is shown as raw `Text`: Markdown, code fences
  and tables appear as literal `**`, ``` and `|` characters, and nothing can be
  selected or copied. **Fix:** reuse the chat screen's Markdown renderer
  (read-only) inside a `SelectionArea`.
- **P1 · error/offline · `:19`, `:85`.** `_snapshot` is a `late final` Future,
  so a timeout or offline failure is final. The error branch shows a fixed
  "unavailable or expired" message with no Retry, and it also hides the
  service's more specific messages (`'Could not load the shared snapshot.'` for
  network errors vs. 404). **Fix:** keep the Future in a mutable field, add a
  Retry button that reassigns it in `setState`, and show
  `(state.error as ConversationShareException).message`.
- **P1 · perf · `:88-96`.** `ListView(children: [for ...])` builds every
  message eagerly. A share can hold 500 messages of up to 20,000 characters
  each (`conversation_share_service.dart:91-96`), so all of them are laid out
  on the first frame. **Fix:** `ListView.builder` with the header, error and
  button as index 0 / last items, or a `CustomScrollView` with a
  `SliverList.builder`.
- **P1 · UX · `:98-101`.** The primary CTA sits at the very end of the list, so
  on a long thread the user has to scroll through everything to find it.
  **Fix:** put it in `Scaffold.bottomNavigationBar` (inside a `SafeArea`), or
  add a pinned bottom bar like the ChatGPT/Claude shared-chat pages.
- **P2 · flow · `:39-43`.** If the user was signed in as A and switches to B
  inside `AuthScreen`, `_continue` returns silently: no message, and the button
  just re-enables. **Fix:** set `_error = 'You switched accounts. Tap Continue
  again to import into <B>.'`, or simply allow the fork as the new account,
  since the token is not account-bound.
- **P2 · flow · `:31-38` + `lib/core/conversation_share_service.dart:129,139`.**
  `ConversationShareService.production()` captures `_ownerUid` at construction
  from `currentUid`, which returns null until `FirebaseService.accountReady`
  (`firebase_service.dart:72-76`: signed-in **and** the AppState account switch
  **and** the account session are ready). If the user backs out of
  `AuthScreen` before the account session finishes initializing,
  `_checkOwner()` throws "Account changed or signed out…", and the
  `sessionAccountToken` comparison at `:46-48` can fail for the same reason.
  **Fix:** after sign-in, await account readiness (listen to `AppState` until
  `FirebaseService.I.accountReady`, with a 15 s timeout and a spinner) before
  capturing `accountToken` and building the service.
- **P2 · flow · `AuthScreen` does not pop on success** (`auth_screen.dart:92`
  renders `_signedIn(fb)` instead). From the share flow the user has to press
  Back after signing in before the fork continues. **Fix:** push `AuthScreen`
  with a `popOnSignIn: true` argument and pop as soon as `isSignedIn` flips.
- **P2 · empty state · `:88-102`.** A snapshot whose rows were all filtered by
  `_privateText` (`conversation_share_service.dart:64`) renders a header plus
  an enabled button, and Continue then fails with "no importable messages".
  **Fix:** when `snapshot.messages.isEmpty`, show an `AetherEmptyState` and
  disable Continue.
- **P2 · data · `lib/core/state.dart:6384-6389`.** The import de-duplicates by
  `(role, content)` against the whole session, so legitimately repeated turns
  ("continue", "yes", "ok") are dropped and the imported thread no longer
  matches what was shown. **Fix:** de-duplicate by position, e.g. skip only
  when the existing session already has the same prefix (idempotent re-import),
  or by a server-provided message index.
- **P2 · data · `state.dart:6373`.** Imported sessions are always titled
  "Shared conversation", so several imports look identical in the sidebar.
  **Fix:** derive the title from the first user message (the same helper used
  for new chats) or from a server-provided title.
- **P2 · deep links · `lib/main.dart:118-123`.** `_openedTokens` is never
  cleared, so tapping the same share link a second time in one process does
  nothing. **Fix:** remove the token when the viewer route pops (`await
  navigator.push(...)`, then `_openedTokens.remove`), keeping de-dup only for
  in-flight opens.
- **P2 · error copy · `:73`.** `error.toString()` is shown verbatim. That is
  fine for `ConversationShareException`, but any other exception (a
  `StateError` from `AppState`, for example) leaks a raw Dart message.
  **Fix:** `error is ConversationShareException ? error.message : 'Could not
  continue this conversation. Please retry.'`.
- **P2 · a11y · `:97`.** The error text is not a live region. **Fix:** wrap it
  in `Semantics(liveRegion: true)`, as `AetherField` already does.

**Missing features (vs. ChatGPT/Claude shared chats):** a share-page title and
creation date; a "Report"/abuse affordance; Copy per message; an "Open in
browser" fallback; showing that the link is a frozen snapshot with its expiry
date.

**Test to add:** a widget test with a fake `http.Client` that returns
503 → Retry → 200 and asserts that the content renders; a test with 500 long
messages asserting that only visible items build (count `AetherCard`s in the
tree); and a role-label golden.

---

## 2. Share actions — `lib/ui/share_actions.dart` (+ `lib/core/native_share.dart`)

**What it is / how reached.** `showNativeShare` wraps a native share call with
a retry snackbar. It is used by Settings ("Share app"), backup export and
chat-file share. `ChatShareButton` is an app-bar popup with "Share chat
transcript" and "Share local file…".

**Findings**
- **P2 · dead code · `share_actions.dart:37-113`.** `ChatShareButton` is not
  used in any production widget; it is only referenced from tests, and
  `test/chat_screen_bounded_test.dart:125,603` asserts that it is **absent**
  from the chat screen. So the transcript share path is unreachable while the
  `_LivePopupMenuItem` machinery is still maintained. **Fix:** either delete it
  (with its tests) or wire it into the chat app bar as the single "Share" entry
  (see the missing-feature note in §3), not both.
- **P2 · privacy (latent) · `lib/core/native_share.dart:33-52`.**
  `transcriptText` writes **every** message, including `thinking` messages
  (labelled "Ovid:") and full `toolDetail` (command output, file contents),
  plus local image file names. The public-link path deliberately filters all of
  these out (`conversation_share_service.dart:77-84`). If `ChatShareButton` is
  re-wired, a "Share transcript" can leak tool output and reasoning. **Fix:**
  build transcript text from `ConversationSnapshot.fromSession(session)`
  (optionally with an "Include tool output" toggle), and skip `m.thinking`.
- **P2 · error handling · `share_actions.dart:13-24`.** `catch (_)` swallows
  everything, including the `StateError('No local file available')` at `:79`
  (content-URI-only pickers), and shows "Could not open sharing. Please
  retry.", which retrying will never fix. **Fix:** call `FilePicker.pickFiles(withData:
  false, withReadStream: true)` or copy to cache first, and show a specific
  message for "file not accessible".
- **P2 · brand · `native_share.dart:19-20`.** The app-share text says
  "Ovid — AI chat, agents & tools" and points at `https://dhanuk.page.gd/ovid`,
  while the brand is `Aether.brandName = 'Ovid Si'` and share links use
  `https://ovidsi.com`. **Fix:** use `Aether.brandName`/`tagline` and the
  canonical origin (`ShareLinkResolver.canonicalOrigin`), and move the URL into
  config.
- **P2 · a11y · `share_actions.dart:87`.** Icon size 19 in a default
  `PopupMenuButton` gives a 48dp target, which is fine. `_ShareMenuRow` icons
  are decorative but not excluded. **Fix:** `ExcludeSemantics` around the
  `Icon` in `_ShareMenuRow`.

**Test to add:** a unit test that `transcriptText` excludes `thinking` and tool
messages once fixed; a widget test that `showNativeShare` shows the specific
error for a null `path`.

---

## 3. ConversationShareSheet — `lib/ui/conversation_share_sheet.dart`

**What it is / how reached.** A modal sheet (92% height) for creating,
listing, copying and revoking public read-only links, with a QR code and a
preview of exactly what is shared. The **only** entry point is a long-press on
a conversation in the sidebar (`lib/ui/sidebar.dart:799`); there is no share
button in the chat screen.

**Findings**
- **P1 · layout · `:141-152` with `aether_primitives.dart:1454-1479`.** The
  sheet body is `Column(min) → Expanded(ListView)`. `AetherSheet._scrollingBody`
  wraps the child in `ConstrainedBox(maxHeight: bodyConstraints.maxHeight)`
  inside a `SingleChildScrollView` that also contains the handle (4), gap (14),
  title (~23) and gap (16). Because the `Expanded` is tight, the child column
  takes the **full** body height, so the outer content is about 57dp plus the
  actions row (16 + 44) taller than the viewport. As a result the **"Create
  link" button (`:303`) starts about 57dp below the visible sheet** and "Close"
  is about 117dp below it. Users have to discover a nested outer scroll to
  reach the primary CTA. **Fix:** pass `pinActions: true`, move "Create link"
  into `actions` (next to Close), and drop the `Expanded` (let the `ListView`
  be `shrinkWrap: false` inside the pinned `Flexible`), or size the body as
  `maxHeight - chromeHeight`.
- **P1 · destructive action · `:105-108`, `:445-449`.** "Revoke" deletes a
  public link in one tap with no confirmation and no undo. Anyone who already
  had the link loses access permanently. **Fix:** a confirmation dialog
  ("Revoke link? People with this link will no longer be able to open it.")
  using `AetherDangerButton`.
- **P1 · correctness/UX · `:154-160`, `:237-268`, `:311`.** Only one link per
  session is allowed (`_shares.isEmpty`). Once a link exists, the "Preview · N
  messages" card still shows the **current** conversation, while the live link
  holds the **older** frozen snapshot, so the user is told the link contains
  text it does not. There is also no way to update the link except revoke and
  create. **Fix:** when `activeShare != null`, retitle the preview "Current
  chat (not yet shared)", show a diff hint ("N new messages since this link
  was created"), and add an "Update link" action that revokes and creates
  atomically, with confirmation.
- **P1 · missing feature · `:378-382`.** There is no "Share…" action that opens
  the Android share sheet with the URL; only Copy is offered. This is the
  primary action in the ChatGPT and Claude apps. **Fix:** add an
  `AetherSecondaryButton('Share', icon: Icons.ios_share)` that calls
  `showNativeShare(context, () => NativeShare.text(url))`, adding a small
  `shareText` wrapper next to `NativeShare.app`.
- **P1 · discoverability · `sidebar.dart:799`.** Public link sharing is hidden
  behind a long-press in the drawer. **Fix:** add a share icon to the chat
  app bar (for example by repurposing `ChatShareButton` as the entry point to
  `showConversationShareSheet` plus "Export transcript").
- **P1 · signed-out state · `:14`, `:55`.** The service is built with the
  owner UID captured at open. For a signed-out or not-yet-ready user, the
  first `list` throws "Account changed or signed out. Reopen sharing after
  signing in." (`conversation_share_service.dart:174-180`). That copy is wrong
  for someone who was never signed in, and there is no Sign in button.
  **Fix:** if `!FirebaseService.I.accountReady`, render a "Sign in to create
  links" card with a button that pushes `AuthScreen`, and rebuild the service
  after it returns.
- **P2 · copy · `:189-196` and `:281-288`.** "No active links for this
  session." is rendered **twice** when loaded and empty. **Fix:** drop the
  copy inside the intro card.
- **P2 · copy · `:259-265`.** One message covers two different states ("No
  shareable text, or snapshot exceeds…"). **Fix:** branch on
  `messages.isEmpty`, and otherwise name the limit that was hit (count, total
  KB, or the longest message).
- **P2 · offline/latency · `:110-126`.** Copy link makes a network `list`
  round-trip first, so Copy fails offline and blocks the whole sheet behind
  `_busy` for up to 20 s × 2 (token + request). **Fix:** copy immediately from
  the displayed receipt (it is the user's own link), and re-validate in the
  background; if the link turns out to be revoked, show "This link was revoked"
  afterwards.
- **P2 · i18n · `:336`, `:403`.** Expiry is
  `toLocal().toString().split('.').first` (`2026-10-11 14:03:22`). **Fix:**
  `DateFormat.yMMMd().add_jm()` from `intl`, plus a relative "in 29 days".
- **P2 · ordering · `:131`.** "LIVE"/active is assumed to be `_shares.first`,
  but `list()` does not sort (`conversation_share_service.dart:214`). **Fix:**
  sort by `createdAt` descending after `list()`.
- **P2 · perf · `:244-258`.** The preview lays out every message (up to
  200 KB of text) inside a single list child, so nothing is lazy. **Fix:**
  `SliverList.builder`, or collapse the preview to the first and last 3
  messages with "Show all".
- **P2 · contrast · `:339-343`.** The "LIVE" pill uses `successLight`
  (#15803D) on its own 14% tint over white, which is 4.14:1 at 11px and fails
  AA. **Fix:** see §8 (pill text tokens).
- **P2 · a11y · `:200-235`.** The error card is not a live region, so the
  result of Create/Revoke is not announced. The `LinearProgressIndicator` at
  `:146-149` has no `semanticsLabel`. **Fix:** `Semantics(liveRegion: true)`
  on the error text; `semanticsLabel: 'Working'`.

**Missing features:** link expiry choice (7/30/never); "Include my name"
toggle; view count / last opened; "Manage all shared links" across chats (in
Settings → Privacy, like ChatGPT "Shared links"); share a single message.

**Test to add:** a widget test at 360×640 and textScale 1.3 that asserts
`tester.getRect(find.text('Create link'))` lies within the sheet's visible
rect without scrolling; a test that Revoke shows a confirm dialog; a test
that the preview label changes when an active share exists.

---

## 4. PrivateSyncSettingsScreen — `lib/ui/private_sync_settings_screen.dart`

**What it is / how reached.** Settings → Private sync
(`lib/ui/settings_screen.dart:86`). This screen asks for consent to upload full
transcripts to the account's server storage, and offers enable, refresh,
disable on this device, and revoke device (with re-authentication). It links
to the restored-conversation and activity archives. The controller is
`PrivateSyncProduction` (`lib/core/private_sync/production.dart:163`).

**Findings**
- **P1 · UX/correctness · `:129-133` + `production.dart:443-446,855-857`.**
  `owner.error` is a single mutable string used for **both** errors and
  success notices: `_report('Device revoked. Local transcripts… are
  preserved.')` writes the success confirmation into `error`, and the screen
  paints it in `colorScheme.error` red. It is also never cleared after a later
  successful sync. Only a successful `enroll()` resets it (`production.dart:340`),
  so a transient "Sync conflict…" or "could not resume" stays on screen
  indefinitely. **Fix:** split it into `String? notice` and
  `SyncIssue? error` (with a timestamp), clear `error` when `deliveryStatus`
  reports a successful pass, and render notices in neutral/success styling
  (`Aether.successLight`) with a dismiss button.
- **P1 · status visibility · `:139-146`.** There is no last-synced time, no
  pending-upload count, and no indication of whether "Refresh now" did
  anything. `refresh()` is a silent no-op when not foregrounded
  (`production.dart:797-799`). `SyncDeliveryStatus` today carries only
  `foreground/retrying/isStale/revision` (`coordinator.dart:59-71`). **Fix:**
  add `lastSuccessAt` and `pendingCount` (taken from `PrivateSyncOutbox.entries()`)
  to `SyncDeliveryStatus` and render "Last synced 2 min ago · 3 pending";
  after Refresh, show a snackbar "Up to date" or "Sync queued", or "Open the
  app to sync" when not foregrounded.
- **P1 · consent UX · `:117-121`, `:158-167`.** The consent text is a single
  ~70-word paragraph in default body style, followed by a one-tap "Enable".
  For an upload that explicitly includes "any secret-like text or credentials
  pasted into a conversation" and is "not end-to-end encryption", a one-tap
  implicit consent is weak for a 10M-DAU app (GDPR Art. 7 requires consent to
  be clearly distinguishable). **Fix:** structure it as three bullet rows
  (What uploads / What stays local / Not E2E) with icons, and require a
  confirm dialog ("Upload transcripts to your account?") or a checkbox before
  the Enable button becomes active.
- **P2 · signed-out state · `:127-128`.** "Sign in and wait for your account
  to be ready." has no Sign in action. **Fix:** add an
  `AetherPrimaryButton('Sign in')` that pushes `AuthScreen`.
- **P2 · error detail · `:82-88`.** `catch (_)` maps every failure, including
  `StateError('Device enrollment is not active')` and quota failures, to "Check
  your connection and account". **Fix:** map the known `StateError`s and
  `SyncClient` exceptions to specific copy, and keep the generic message only
  as a fallback.
- **P2 · layout/consistency · `:148-178`.** Raw Material `OutlinedButton` and
  `FilledButton` widgets are stacked full-width in the `ListView` with **no
  spacing** between them (`:148`→`:152`, `:161`, `:170`), and the body uses
  default `Text` styles. This is the only settings sub-screen that does not
  use Aether primitives. **Fix:** use `AetherCard` sections and
  `AetherSecondaryButton`/`AetherDangerButton`, with `SizedBox(height: 8)`
  gaps.
- **P2 · progress placement · `:182`.** The `LinearProgressIndicator` is
  rendered below the explanatory paragraph, far from the button that was
  pressed, and is off-screen on small phones. **Fix:** put it in
  `AppBar.bottom` (`PreferredSize`, 2dp) or use the button's `loading:` flag.
- **P2 · nav · `:184-207`.** "Restored conversations" and "Private activity"
  are enabled while sync is unavailable, and open screens that only say "Sign
  in…". **Fix:** disable them, or show a count badge (e.g. "12
  conversations") when available.
- **P2 · device naming · `production.dart:320-321`.** Every device enrolls as
  `deviceName: 'Ovid'`, so a future device list (and any server-side audit)
  cannot tell devices apart. **Fix:** send `'${Build.MODEL} (Android)'` from
  the platform channel.

**Missing features:** a device list (enrolled devices, last seen, revoke other
devices); "Delete my server copy" (account-level purge, which GDPR expects
alongside revoke); a Wi-Fi-only toggle; background sync (WorkManager) instead
of foreground-only.

**Test to add:** a widget test that after `revokeDevice` succeeds, the
"Device revoked" text is **not** rendered in `colorScheme.error`; a test that
the Enable button needs a confirmation step.

---

## 5. PrivateConversationScreen — `lib/ui/private_conversation_screen.dart`

**What it is / how reached.** Private sync → "Restored conversations". With no
`conversationId` it lists conversation titles; with one it shows that
transcript's rows as read-only `SelectableText` cards.

**Findings**
- **P1 · perf · `:16-36`, `:45-88`.** On **every** `owner` notification
  (delivery status changes during sync), the build filters and sorts **all**
  archive records (`owner.records` copies the whole store,
  `store.dart:130`), then builds an eager `ListView(children: [...])` of every
  conversation, or every transcript row. For a user with thousands of synced
  messages this causes jank while sync runs. **Fix:** precompute an index (a
  `Map<conversationId, List<row>>`) in the controller, invalidate it only when
  the store changes, expose a `ValueListenable` for records separately from
  status, and use `ListView.builder`.
- **P2 · ordering · `:28-35`.** Conversations are listed in insertion order of
  their oldest row, so the oldest chat comes first and the newest is last.
  **Fix:** order by the latest `createdAt` per conversation, descending, and
  show the date and message count in the `ListTile` subtitle.
- **P2 · raw values · `:79`.** The header shows `kind.name ·
  createdAt` (for example `assistant · 2026-10-11T08:12:44.120Z`), which is a
  raw enum plus an ISO timestamp. **Fix:** map the kind to "You"/"Assistant"
  /"System"/"Tool", and format the time with `DateFormat` in local time.
- **P2 · edge · `:30-35`, `:54-69`.** Rows with a `null` conversationId count
  toward `rows.isNotEmpty` but are never listed, so the list can be blank with
  no empty-state text. **Fix:** compute the empty state from `conversations`,
  not `rows`, in list mode.
- **P2 · consistency · `:72`.** A Material `Card` is used instead of
  `AetherCard`. It picks up M3 `surfaceContainerLow` and elevation tint, and
  looks different from the rest of the app. **Fix:** use `AetherCard`.

**Missing features:** search across the archive; "Export as text/Markdown";
a "Copy all" action; "Open as new chat" (an explicit, user-initiated copy into
a fresh local session).

**Test to add:** a test with 2,000 records that pumps a status change and
asserts that frame build time stays under budget (or counts builds); an
ordering test.

---

## 6. PrivateActivityScreen — `lib/ui/private_activity_screen.dart`

**What it is / how reached.** Private sync → "Private activity". A read-only
list of synced activity and usage records, newest first.

**Findings**
- **P1 · perf · `:12-19`, `:22`, `:35-58`.** The same pattern as §5: a full
  scan and sort on every notification, plus an eager `ListView` of every
  activity and usage row. Usage rows accrue on every request, so this list
  grows without bound. **Fix:** `ListView.builder`, a pre-indexed list, and
  paging by date (or show the last 30 days with "Load older").
- **P2 · raw values · `:42`, `:45`, `:49-53`.** It shows the raw ISO
  `createdAt`, `status.name` (`interrupted`), `outcome.name`, and provenance
  names such as `providerReported`, `locallyEstimated`, `legacyUnspecified`,
  plus "Input: unknown". **Fix:** a label map ("Reported by provider",
  "Estimated on device"), localized dates, and "—" for missing tokens.
- **P2 · layout · `:28-29`, `:36-58`.** The signed-out text has no padding,
  unlike the empty state, and cards have no visual hierarchy (`Text` lines
  with default style, no status chip). **Fix:** `AetherCard(title:
  activity.title, trailing: AetherPill(status))` with the detail text in
  `AetherType.bodyMuted`.
- **P2 · UX · whole screen.** Activity and usage are mixed in one stream with
  no filter. **Fix:** an `AetherSegmentedControl` (All / Activity / Usage)
  and a per-day group header with token totals.

**Missing features:** usage totals per day and model (overlaps with
`usage_screen.dart`; link to it instead of duplicating); export CSV.

**Test to add:** a widget test asserting that no raw enum identifiers (regex
`[a-z]+[A-Z][a-z]+`) appear in rendered text for a sample of every enum value.

---

## 7. CollaborationScreen — `lib/ui/collaboration_screen.dart`

**What it is / how reached.** Settings → Collaboration
(`settings_screen.dart:94`). Create or join a shared session (with a session
token plus a one-use invitation code), list members, revoke members, view
read-only events, and send plain-text messages. The controller is
`CollaborationProduction` (`lib/core/collaboration/production.dart`).

**Findings**
- **P1 · debug output in UI · `:192-195`.** Model state is rendered as
  `entry.value.toWire().toString()`, which is a raw Dart `Map` dump such as
  `{status: running, model: …}`. **Fix:** render the fields explicitly
  (model name, status pill, updated time).
- **P1 · join UX · `:94-123`, `:145-146`.** To join, a member has to **type**
  a long opaque session token **and** an invitation code into two plain
  `TextField`s. The owner can only see these as `SelectableText`, with no Copy
  or Share button, no QR code, and no deep link. In practice this flow is
  unusable on a phone. **Fix:** let the owner create a single invite deep link
  (`https://ovidsi.com/c/<token>#<code>`) with Copy, Share and QR (reuse
  `_QrCode` from the share sheet), and have joining prefill both fields from
  the link (or from a paste-detect chip).
- **P1 · destructive actions · `:124-135`, `:158-167`.** "Close collaboration"
  (owner: ends the session for every member), "Leave", "Disconnect" and member
  "Revoke" all act on a single tap with no confirmation. **Fix:** a
  confirmation dialog for Close, Leave and Revoke that names the consequence
  ("All 4 members will lose access").
- **P1 · layout · `:175-222`.** The message composer sits at the **end** of an
  eager `ListView`, after every event, model-state and presence row. As
  messages accumulate, the user has to scroll to the bottom to type, and new
  incoming messages push the composer further down. **Fix:** use a chat
  layout. Members and presence go into a header or bottom sheet, messages go
  in a reversed `ListView.builder`, and the composer is pinned in
  `bottomNavigationBar` with `viewInsets` padding.
- **P2 · identity · `:152-153`, `:183`, `:193`, `:200`.** Members, authors and
  presence are shown by raw `participantId`, with `role.name · status.name`
  and a raw `createdAt` string. **Fix:** resolve display names (or "You"),
  use avatars and initials, show relative times, and merge presence into the
  member row as an `AetherStatusDot`.
- **P2 · validation · `:110-118`, `:214-221`.** "Join" is enabled with empty
  fields, and "Send" is enabled with empty text. Both then fail with the
  generic "Check account access and connection" message: `sendMessage`
  throws `StateError` on blank text (`production.dart:214-218`). **Fix:**
  listen to the controllers and disable the buttons until the input is valid
  (trimmed and non-empty, with a format check on the token).
- **P2 · error/feedback · `:68-71`.** Refresh calls `controller!.refresh`
  directly: no busy state and no result feedback. Every `_run` error collapses
  to one generic string (`:37-42`), even though
  `CollaborationClientException` carries status codes (401/403/404/410 →
  "invitation expired", "not a member", and so on). **Fix:** map exception
  types and status codes to specific copy; show a refresh spinner.
- **P2 · consistency · whole file.** Raw `FilledButton`/`OutlinedButton`/
  `TextButton`/`TextField`/`Card` widgets are stacked with no spacing, and no
  Aether primitives are used. **Fix:** `AetherCard` sections, `AetherField`,
  and Aether buttons with 8–12dp gaps.
- **P2 · a11y · `:88-93`.** The error text is not a live region, and the
  `LinearProgressIndicator` has no label. **Fix:** as in §3.

**Missing features:** push notifications for new messages; unread count;
@mentions; sharing an existing chat into a collaboration (the Claude
Projects / ChatGPT team-chat model); member roles beyond owner and member.

**Test to add:** a widget test asserting that no `{`/`}` map dump appears in
model-state rows; a test that Close shows a confirm dialog; a test that Send
is disabled for whitespace-only input.


---

## 8. Design tokens and app theme — `lib/core/theme.dart`

**What it is / how reached.** This is not a screen. `Aether` holds the brand
constants, the light/dark palette as static getters switched by a global
`static bool dark` (`:26`, `:52-78`), the motion and mono tokens, a cached
`ThemeData` (`:120-209`), and two legacy widgets, `Tag` (`:213`) and
`SectionHeader` (`:248`). `main.dart:35-42` sets `Aether.dark` before the
first frame, and `OvidApp` rebuilds `MaterialApp(theme: Aether.theme())` when
the value changes (`main.dart:141-145`, `:156-168`, `:182-188`). Every screen
in `lib/ui` reads `Aether.*` directly: 193 call sites use `textFaint`, 194 use
`textMuted` and 211 use `Aether.accent`.

**Computed WCAG 2.x contrast ratios** (relative luminance, sRGB). AA requires
4.5:1 for body text, 3:1 for text ≥18.66px bold or ≥24px, and 3:1 for UI
component boundaries and meaningful icons (1.4.11).

| Token (light) | on bg F4F1EA | on surface FFF | on surfaceAlt EDE9DF | on surfaceRaised E4DFD3 |
|---|---|---|---|---|
| text 1B1B1B | 15.27 | 17.22 | 14.21 | 12.95 |
| textMuted 6B675E | 5.00 | 5.63 | 4.65 | **4.24** |
| textFaint 8A867D | **3.22** | **3.63** | **2.99** | **2.73** |
| accent E5484D | **3.47** | **3.91** | **3.23** | **2.94** |
| accentC C0292E | 5.17 | 5.84 | 4.81 | **4.39** |
| successC 1FA05F | **2.98** | **3.36** | **2.77** | **2.53** |
| successLight 15803D / warnLight B45309 | **4.45** | 5.02 | **4.14** | **3.77** |
| success 22C55E (used raw in light) | ~2.0 | **2.28** | — | — |
| warn F59E0B (used raw in light) | **1.90** | **2.15** | **1.77** | **1.62** |
| hairline DCD7CB (field border) | **1.27** | **1.44** | **1.18** | — |
| hairlineStrong C4BEB0 | **1.64** | **1.85** | **1.53** | — |

| Token (dark) | on bg 141414 | on surface 1E1E1E | on surfaceAlt 262626 | on surfaceRaised 303030 |
|---|---|---|---|---|
| text F4F1EA | 16.33 | 14.78 | 13.42 | 11.70 |
| textMuted A8A49B | 7.41 | 6.71 | 6.09 | 5.31 |
| textFaint 8A867D | 5.08 | 4.59 | **4.17** | **3.64** |
| accent E5484D | 4.71 | **4.26** | **3.87** | **3.37** |
| hairline 333333 | **1.46** | **1.32** | **1.20** | — |
| hairlineStrong 454545 | **1.92** | **1.74** | **1.58** | — |

Buttons: white on `accent` (the primary button in **both** modes) is **3.91**,
white on `accentC` is 5.84, and white on `success` is 2.28. Bold values fail
the relevant AA threshold.

**Findings**
- **P1 · a11y/contrast · `theme.dart:49`, `:61`.** Light `textFaint` #8A867D
  measures 3.63 on white, 3.22 on paper and 2.99 on surfaceAlt, all below
  4.5:1. It is used as a text colour at 154 `color: Aether.textFaint` sites,
  mostly at 11–12sp: `AetherType.caption` (`aether_primitives.dart:129-133`),
  `SectionHeader` (`:266`), `AetherSectionTitle`, field hints (`:166`,
  `aether_primitives.dart:732`), timestamps and helper text. **User impact:**
  for low-vision users and anyone outdoors on a phone, captions, section
  labels and placeholders are hard to read, and this fails WCAG AA (and EN 301
  549 for EU distribution). **Fix:** set light `textFaint` to **#6F6B62**
  (4.71 on bg, 5.31 on surface, 4.38 on surfaceAlt). Darken `textMuted` to
  about #57534B so the three text levels stay distinct, and set dark
  `textFaint` to **#9A968D** (6.25/5.65/5.13/4.48). Add a unit test that
  asserts every text token is ≥4.5:1 against bg, surface and surfaceAlt in
  both modes (see Test to add).
- **P1 · a11y/contrast · `theme.dart:67`, `:74`, `aether_primitives.dart:317`,
  `:424`, `:473`.** `Aether.accent` (brand red #E5484D) is a `const` that does
  not change with light/dark, and `accentC` (#C0292E) exists to fix that.
  However, the primitives and 90 `color: Aether.accent` text or icon sites use
  the raw brand red. The theme's `colorScheme.primary` is `accentC` (`:142`),
  so the M3 widgets and the Aether buttons do not agree. White label text on
  the primary or danger button is **3.91:1** for 14sp w600 text, which counts
  as normal text under AA. Red links on paper are 3.47:1. In dark mode, red
  text on surface is 4.26:1 and on surfaceAlt 3.87:1. **User impact:** the
  main call to action on every screen fails contrast, and red inline links or
  labels are hard to read. **Fix:** make `accent` a theme-aware getter that
  returns #C0292E in light mode (white on it is 5.84). Keep `signalRed` only
  for the brand mark, focus rings and the agent dot. Add a dark text variant
  around **#F2666A** (5.47 on surface, 4.96 on surfaceAlt) for red **text**.
  Then delete `accentC`/`dangerC` once call sites are migrated.
- **P1 · a11y/contrast · `theme.dart:69-70`, `:75`.** `successC` is commented
  as a "readable variant" but measures only 3.36:1 on white and 2.98:1 on
  paper. It colours tool "done" state text and icons in chat
  (`chat_layout.dart:186`, `chat_screen.dart:4139`). The raw `success`
  (#22C55E) and `warn` (#F59E0B) consts are used as status colours in
  **light** mode too (`schedule_screen.dart:118`, `:691`,
  `settings_health_screen.dart:474`, `:484`, `health_screen.dart:495`, `:505`,
  `:587`, `usage_screen.dart:881`, `sandbox_setup.dart:266`,
  `plugin_install_progress.dart:301`). They measure 2.28:1 and 2.15:1 on
  white, below the 3:1 non-text minimum for a status dot that carries meaning.
  `successLight`/`warnLight` also fail on paper (4.45). **User impact:**
  green "OK" and amber "warning" states are hard to tell apart from each other
  and from the background, especially for users with deuteranomaly, because
  these states have no icon or text alternative (see §9 status dot).
  **Fix:** expose one theme-aware getter each for `success`, `warn` and
  `danger`: light `success` #166534 (6.32 on bg), light `warn` #A04606
  (5.52), dark values unchanged. Make the raw consts private, and remove the
  `successC`/`successLight`/`warnLight` aliases (65 call sites).
- **P1 · a11y/non-text contrast · `theme.dart:45`, `:171-182`,
  `aether_primitives.dart:738-756`, `:1269-1287`.** Text field boundaries use
  `hairline`, which is 1.44:1 on white and 1.27:1 on paper in light mode and
  1.32:1 in dark mode. The fill (surfaceAlt) differs from the white card by
  only 1.21:1. WCAG 1.4.11 requires 3:1 for the visual boundary of an input.
  **User impact:** empty fields (login phone/OTP, MCP JSON, collaboration
  token) are nearly invisible on white cards, so users don't see where to
  tap. **Fix:** add an `inputBorder` token: light **#8F897C** (3.08 on bg,
  3.48 on surface), dark **#7F7A6E** (4.31 on bg, 3.90 on surface). Use it
  for `enabledBorder`, and keep `hairline` for dividers only.
- **P1 · theming architecture · `theme.dart:24-26`, `:52-64`,
  `main.dart:182-188`.** The palette is a global mutable static read through
  getters, so no widget registers a dependency on it. A theme switch only
  takes effect in widgets that happen to rebuild. `OvidApp.setState` rebuilds
  `MaterialApp`, but `home: const LoginGate(child: OvidShell())` is a const
  subtree: only `Theme.of` dependents and `AppState` listeners rebuild, while
  `const` children, cached `child:` arguments of `AnimatedBuilder`, and open
  dialogs or sheets that don't listen to `AppState` keep painting the old
  colours. There is also no `darkTheme`/`themeMode`, so `AnimatedTheme`
  cross-fades the Material parts while the `Aether.*` parts snap (or don't
  change at all). The static state also leaks between tests
  (`resetThemeCacheForTest`, `:107`). **User impact:** after the user toggles
  the theme in Settings, or the OS switches to dark at sunset (`system`
  mode), screens can show mixed light and dark surfaces until the user
  navigates away. Verify on device by opening a sheet, then switching the
  system theme from quick settings. **Fix:** add a
  `ThemeExtension<AetherColors>` with `light`/`dark` instances and `lerp`.
  Build `theme` and `darkTheme` once, pass
  `themeMode: ThemeMode.system|light|dark` to `MaterialApp`, and read colours
  with `context.aether.text`. To migrate incrementally, keep the static
  getters as `@Deprecated` shims for one release, migrate primitives first
  (this one change covers 111 `AetherCard` and 294 `AetherType` uses), then
  migrate screens file by file.
- **P1 · l10n readiness · `pubspec.yaml`, `main.dart:182-188`, whole
  `lib/ui`.** Localization has not started. There is no
  `flutter_localizations`, no `intl`, no `l10n.yaml`/ARB files, and no
  `localizationsDelegates`/`supportedLocales` on `MaterialApp`. Material's own
  strings (Cut/Copy/Paste, date picker, "Back" semantics) are therefore
  English only and RTL layout can never activate. `lib/ui` contains about 310
  `Text('literal')` and about 339 `label:/tooltip:/title:/hintText:/message:`
  literals. The primitives hardcode screen-reader strings: `'Loading'`
  (`aether_primitives.dart:361`, `:410`), `'Digit ${i+1} of ${n}'` (`:1193`)
  and `'Decrease'/'Increase' … 'value'` (`:1366`). There are 225
  `EdgeInsets.only/fromLTRB` and 0 `EdgeInsetsDirectional` uses, 15
  locale-insensitive `toUpperCase()` calls (`theme.dart:261`, the tagline on
  `login_gate.dart:219`; Turkish dotted i becomes the wrong glyph), and **0**
  `DateFormat`/`NumberFormat` uses, so dates, token counts and prices are
  formatted by hand. **User impact:** Ovid cannot ship in any non-English
  market (Hindi, Indonesian, Portuguese and Spanish make up most of the
  Android top-10 markets at 10M DAU) without touching every file. **Fix
  (prerequisite order):** (1) add `flutter_localizations` + `intl`,
  `generate: true`, `l10n.yaml`, an `app_en.arb`, and delegates/locales on
  `MaterialApp`; (2) change primitives to take strings from
  `AppLocalizations` (start with the a11y strings above); (3) add a
  `no-hardcoded-ui-strings` custom lint or CI grep that ratchets the literal
  count down; (4) replace `EdgeInsets.only(left/right)` with directional
  insets and `Alignment.centerLeft` with `AlignmentDirectional`; (5) route all
  dates and numbers through `DateFormat`/`NumberFormat.compact` with the
  current locale; (6) add a pseudo-locale (`en_XA`, +40% length) golden run
  to catch truncation.
- **P2 · typography · `theme.dart:154-160`, `:203-207`,
  `aether_primitives.dart:75-139`.** The app bar title is 15sp (M3 default is
  22) with 20dp icons. `AetherType` is not mapped into `ThemeData.textTheme`,
  so the four `Theme.of(context).textTheme` users and every M3 widget
  (dialogs, list tiles, chips) use the Material scale while Aether screens use
  `AetherType` or literals. `lib/ui` has about 450 hard-coded `fontSize:`
  literals, including 46 at 8.5–10.5sp (`Tag` at 10sp, `theme.dart:237`).
  **User impact:** the type scale is inconsistent, and labels under 11sp are
  unreadable for many users at the default text scale. **Fix:** map
  `AetherType` into `TextTheme` (display → displaySmall, h1 → headlineSmall,
  h2 → titleLarge, title → titleMedium, body → bodyMedium, label →
  labelLarge, caption → bodySmall). Set an 11sp floor (tags only) and 12sp for
  everything else, and add a lint or CI grep that rejects `fontSize:` < 11
  outside `widgets/`.
- **P2 · fonts · `pubspec.yaml` `fonts:` (`assets/fonts/Inter.ttf`,
  876 KB).** Inter ships as a single variable-font file with no `weight:`
  descriptors. Unless the engine maps `FontWeight` onto the `wght` axis, every
  w600/w700 is synthetic ("fake") bold, which is smeared and wider. There is
  no explicit fallback for Devanagari or CJK either (the system font is used).
  **Fix:** verify on a device with a w400-vs-w700 screenshot. If weights are
  synthesized, ship static Inter Regular/Medium/SemiBold/Bold with `weight:`
  entries (subset to Latin plus Latin-Ext, about 4×90 KB), or set
  `fontVariations: [FontVariation.weight(...)]` in the primitives.
- **P2 · theming/consistency · `theme.dart:139-148`.** The `colorScheme`
  overrides only `surface/primary/secondary/tertiary/onSurface/error`. M3 roles
  such as `outline`, `outlineVariant`, `onSurfaceVariant`,
  `surfaceContainer*`, `primaryContainer`, `secondaryContainer`, `onError`
  and `inverseSurface` stay at baseline values. **User impact:** Switch,
  Chip, SegmentedButton, NavigationBar, DropdownMenu, Slider, Card and the
  M3 date picker render with lavender or grey baseline tints that are off
  brand, next to Paper/Ink Aether widgets. **Fix:** fill every role from
  Aether tokens (outline = inputBorder, outlineVariant = hairline,
  onSurfaceVariant = textMuted, surfaceContainerLow…Highest =
  surface/surfaceAlt/surfaceRaised, primaryContainer = accentSoft,
  onError = white), and also set `switchTheme`, `chipTheme`,
  `filledButtonTheme`, `outlinedButtonTheme` and `textButtonTheme` so raw
  Material buttons (used heavily in §7) match the Aether buttons.
- **P2 · contrast · `theme.dart:184-188`.** Snackbar text is 13sp on
  surfaceRaised. The action button uses `primary` (accentC), which is 4.39:1
  on #E4DFD3, so it fails. **Fix:** use an inverse snackbar (Ink background,
  Paper text, `actionTextColor: #F2666A`) like the ChatGPT and Claude apps; it
  is also more visible.
- **P2 · motion/a11y · `theme.dart:134-136`, `:282-307`.** The custom
  fade-and-slide page transition ignores `MediaQuery.disableAnimationsOf`, so
  with "Remove animations" enabled the 2.5% slide still plays (Flutter does
  not shorten route transitions on its own). **Fix:** in `buildTransitions`,
  return `child` directly when animations are disabled.
- **P2 · duplication · `theme.dart:212-280`.** `Tag` duplicates `AetherPill`
  (8 call sites), and `SectionHeader` duplicates `AetherSectionTitle` (20
  versus 34 call sites) with different paddings. Both also use
  locale-insensitive `toUpperCase()`. **Fix:** make `Tag` and
  `SectionHeader` thin deprecated wrappers over the Aether primitives, then
  migrate the call sites.

**Missing features:** a high-contrast theme variant (Android "High contrast
text" or user setting); dynamic colour opt-out is fine, but there is no
"follow system font" or "text size" in-app setting that ChatGPT and Claude
expose; no `ThemeMode` cross-fade.

**Test to add:** `test/theme_contrast_test.dart` iterates every text token ×
{bg, surface, surfaceAlt} in both modes and asserts ≥4.5 (and ≥3.0 for
`inputBorder`, `success`, `warn` and `danger` as non-text). Add a widget test
that toggles `AppState.setLightTheme` with a bottom sheet open and asserts
the sheet's `Material.color` changes. Add a test that `MaterialApp` has
non-empty `supportedLocales` and `localizationsDelegates`.

---

## 9. Aether primitives — `lib/ui/widgets/aether_primitives.dart`

**What it is / how reached.** This is the shared widget library used by every
screen. It contains spacing, radius, shadow and type tokens (`:19-139`);
`AetherCard` (111 uses); `AetherGradientHeader`; `AetherSectionTitle`; four
button kinds built on `_AetherButton` (`:276-641`), including the chat
composer's icon-only send/stop; `AetherField` (17 uses, against 30 raw
`TextField`s in `lib/ui`); `AetherStatusDot`; `AetherPill`;
`AetherEmptyState`; `AetherSegmentedControl`; `AetherOtpField`;
`AetherStepper`; and `AetherSheet` (`:1381-1514`). Changes here affect every
screen, so they are the cheapest place to fix accessibility and consistency.

**Findings**
- **P1 · layout (default mode) · `:1386-1397`, `:1454-1480`.** `pinActions`
  defaults to `false`, and the default `_scrollingBody` puts the handle,
  title, a body clamped to the **full** body height
  (`ConstrainedBox(maxHeight: bodyConstraints.maxHeight)`) and the actions in
  one `SingleChildScrollView`. Any body that fills its height (a
  `ListView`/`Expanded`) therefore pushes the action row about 57 + 60dp
  below the fold. This is the root cause of the hidden "Create link" button
  in §3, and it affects every tall sheet (memory add, schedule editor, MCP
  OAuth, plugin permission). **User impact:** primary actions such as
  Allow, Save and Create are off-screen, and users don't know they can
  scroll the outer sheet. **Fix:** make `pinActions: true` the default, and
  in `_scrollingBody` clamp the body to
  `bodyConstraints.maxHeight - chromeHeight` (measure the title with a
  `LayoutBuilder` or use a `CustomMultiChildLayout`). Add a test that pumps
  each sheet at 320×568 with text scale 2.0 and asserts the last action
  `hitTestable()`.
- **P2 · API footgun/tablet · `:1378-1433`.** `AetherSheet` paints its own
  `surface` background, `rXl` (22) top radius and shadow, while
  `bottomSheetTheme` (`theme.dart:196-202`) also paints `surface` with a 20dp
  radius. Every caller therefore has to remember
  `backgroundColor: Colors.transparent` by hand (the current callers in memory, plugin permission, MCP OAuth, schedule, GitHub login and share sheets all do). There is no
  max width, so on tablets and foldables the sheet stretches edge to edge
  (1280dp line lengths). The title is not `Semantics(header: true)`, and the
  drag handle has no semantics or dismiss action. **Fix:** add a
  `showAetherSheet<T>(context, {title, child, actions})` helper that sets
  `isScrollControlled: true`, `useSafeArea: true`, a transparent background
  and `constraints: BoxConstraints(maxWidth: 640)`, and route all callers
  through it. Mark the title as a header.
- **P2 · a11y/tap target · `:340-353`, `:1020`.** The icon-only button (the
  chat composer's **send/stop**, the most-tapped control in the app) and
  `_SegItem` are custom `InkWell`s with a 44dp minimum, so
  `materialTapTargetSize.padded` does not apply. Android/Material guidance and
  the Play pre-launch accessibility scanner require 48dp. Label buttons are
  fine: `FilledButton`/`OutlinedButton`/`TextButton` pad their hit area to
  48dp through the theme's `tapTargetSize`. **Fix:** set the min to 48 in
  both places (keep a 44dp visual circle inside a 48dp hit box if the
  composer layout is tight), and add a `meetsGuideline(androidTapTargetGuideline)`
  test.
- **P2 · a11y/contrast · `:317-321`, `:424-427`, `:473-476`.** The primary and
  danger buttons use brand `Aether.accent` with a white label (3.91:1, see §8).
  The disabled state is white70 on accent@40% over paper, about 1.56:1, so a
  disabled "Send" or "Save" label is barely visible, and users can't tell
  whether the button is disabled or just pale. **Fix:** use the theme-aware
  accent from §8. For the disabled state use M3's onSurface@38% label on
  onSurface@12% fill, which is clearly "disabled" and still legible.
- **P2 · a11y/colour-only status · `:783-858`.** `AetherStatusDot` is an
  unlabeled 8dp coloured circle that conveys running, ok, warn and error
  states by colour alone (WCAG 1.4.1). It is used in schedule, health and
  subagent rows (`schedule_screen.dart:126`, `health_screen.dart:518`,
  `:624`, `subagent_screen.dart:647`). **User impact:** colour-blind users and
  TalkBack users get no status. **Fix:** add a required `semanticLabel`
  (wrapped in `Semantics(label:)`), and optionally a `shape` or `icon` per
  state (check, triangle, cross) so the states differ by more than hue.
- **P2 · a11y/semantics · `:712-772`.** `AetherField` puts `errorText` into
  the field's semantics label **and** renders the same text as a separate
  `liveRegion` node, so TalkBack announces the error twice when it appears and
  reads "Label, newline, error" on every focus. Hint text is not part of the
  label either. **Fix:** move the error into
  `InputDecoration(errorText:)` with a custom `errorStyle` (Material then
  exposes it once as the field's error semantics), or wrap the visible error
  text in `ExcludeSemantics`.
- **P2 · API coverage · `:648-698`.** `AetherField` has no
  `textInputAction`, `textCapitalization`, `inputFormatters`, `maxLength`,
  `readOnly`, `autocorrect`/`enableSuggestions` or `onTapOutside`
  parameters. That is why 30 raw `TextField`s bypass it (§7 collaboration,
  §3 sharing, settings) and lose its label, error and a11y handling.
  **Fix:** forward these parameters (or accept an `InputDecoration`
  override), then migrate the raw fields.
- **P2 · a11y · `:1011-1014`.** `_SegItem` semantics lack
  `inMutuallyExclusiveGroup: true`, so TalkBack says "button, selected"
  instead of "1 of 3, selected". **Fix:** add the flag and an index hint, or
  build on M3 `SegmentedButton` themed with Aether colours.
- **P2 · a11y · `:1295-1376`.** `AetherStepper` has no
  `Semantics(value:, increasedValue:, decreasedValue:, onIncrease:,
  onDecrease:)`, so screen readers cannot adjust it with swipe up/down and
  value changes are not announced. Its tooltips are English literals
  (`:1366`). **Fix:** wrap the row in an adjustable `Semantics` node.
- **P2 · dead/duplicate code · `:1052-1293`.** `AetherOtpField` has **zero**
  call sites. `auth_methods.dart:524-603` implements its own OTP cells. The
  unused one also has two latent bugs: its `Wrap` follows ambient
  `Directionality`, so digits run right-to-left in RTL locales, and at text
  scale 2.0 six cells of `scale(20)+24` dp plus 8dp gaps (about 424dp)
  wrap onto two rows on a 360dp phone. **Fix:** either delete it, or fix
  both bugs (`Directionality(textDirection: TextDirection.ltr)` and a
  `FittedBox`/single `Row`) and migrate `auth_methods` to it, so only one OTP
  implementation remains.
- **P2 · interaction feedback · `:145-212` (+ `subagent_screen.dart:640-643`).**
  `AetherCard` has no `onTap`. Callers wrap it in an outer `InkWell`, whose
  ripple paints on the *ancestor* `Material`, underneath the card's own opaque
  `Material(color: surface)`. The tap therefore shows no pressed state.
  **Fix:** add `onTap`/`onLongPress` to `AetherCard` and put the `InkWell`
  inside its `Material`, then migrate the wrapping call sites.
- **P2 · brand consistency · `:214-239`.** `AetherGradientHeader` draws a
  gradient, but the brand rules in `theme.dart:10` say "No gradients or
  glow". It is used in `sidebar.dart:337`, `usage_screen.dart:730`,
  `billing_screen.dart:280`, `browser_screen.dart` and `auth_screen.dart`.
  **Fix:** render a flat `Aether.bg` band (or delete the widget and use
  spacing).
- **P2 · overflow/l10n · `:861-905`, `theme.dart:213-245`.** `AetherPill` and
  `Tag` render `Text` with no `maxLines`/`overflow` inside a `Row(min)`. With
  translated labels, which can be 30–40% longer, or at a large text scale, a
  pill in a tight header row overflows (yellow-black stripes in debug,
  clipped in release). **Fix:** add `maxLines: 1, overflow: ellipsis` and
  `Flexible` around the label, plus a `semanticsLabel` parameter.

**Missing features:** a shared `AetherListTile` (most screens hand-roll
rows); a shared `AetherConfirmDialog` (§3, §7 and others need destructive
confirmations); `AetherSkeleton`/shimmer loading placeholders (ChatGPT and
Claude use skeletons instead of spinners); `AetherBanner` for inline
error/offline states with Retry; a `showAetherSheet` helper.

**Test to add:** `test/aether_primitives_a11y_test.dart`: pump each
primitive in both modes and assert `androidTapTargetGuideline`,
`textContrastGuideline` and `labeledTapTargetGuideline`. Add a test that
`AetherSheet` with a `ListView` body at 320×568 / 2.0× keeps its actions
hit-testable, and a test that `AetherField(errorText:)` produces exactly one
semantics node containing the error.

---

## 10. Brand mark — `lib/ui/widgets/ovid_mark.dart`

**What it is / how reached.** `OvidMark` (static `CustomPainter`),
`OvidWordmark` ("Ovid" + red "Si", `semanticsLabel: 'Ovid Si'`),
`OvidLockup`, and `OvidMarkAnimated` (drawOn/reveal/pulse/blink/chase loops,
reduce-motion aware). It is used in the sidebar header (`sidebar.dart:352-359`)
and on the login/startup splash (`login_gate.dart:200-212`, `:655`).

**Findings**
- **P2 · motion · `:212-223`, `:292-304`.** `drawOn`/`reveal` are one-shot
  intros by design (the comment calls them "ring draws, agent square pops"),
  but `_updateMotionPreference` always calls `_c.repeat()`. On the splash
  (`login_gate.dart:200`) the ring therefore erases to **blank** and redraws
  every 3 s for as long as startup or login waits, which looks like a reload
  or glitch. **Fix:** for `drawOn`/`reveal`, use `_c.forward()` (hold the
  final frame); keep `repeat()` only for pulse/blink/chase.
- **P2 · perf · `:247-257`, `:296`, `:315`.** Every animated frame calls
  `Path.addRRect(...).computeMetrics().first`, allocating and measuring a path
  60 times per second. There is no `RepaintBoundary`, so the whole splash
  column repaints each frame. **Fix:** cache the `PathMetric` per size in
  state (or memoize in the painter by `s`), and wrap the `CustomPaint` in a
  `RepaintBoundary`.
- **P2 · theming footgun · `:16-21`, `:28-34`.** The default
  `variant: primary` paints an **Ink** ring that is invisible on the dark bg
  (#1B1B1B on #141414 is about 1.1:1). Each call site has to remember
  `Aether.dark ? reversed : primary`; all three current sites do, but the
  default is wrong in half the themes, and the variant is captured at build
  time (the same static-palette issue as §8). **Fix:** add an
  `OvidMarkVariant.auto` default that resolves from the theme brightness
  (via `Theme.of(context).brightness`, which also registers a rebuild
  dependency). Do the same for `OvidWordmark.onDark`.
- **P2 · a11y · `:35-42`, `:244-258`.** `OvidMark` and `OvidMarkAnimated`
  have no semantics. That is correct when they are decorative, but on the
  splash the animated mark is the only "something is happening" signal next
  to the spinner, and the `chase` variant is documented as a loader. **Fix:**
  add an optional `semanticLabel`. When `animation == chase`, expose
  `Semantics(label: 'Loading', liveRegion: true)` (localized), otherwise
  `ExcludeSemantics`.
- **P2 · l10n · `:95`, `:114`.** The wordmark is split as `'Ovid '` + `'Si'`
  with a hardcoded trailing space and a negative letter-spacing of
  0.03×size. In RTL locales the `Text.rich` reorders the runs to "Si Ovid".
  **Fix:** wrap the wordmark (and the lockup `Row`) in
  `Directionality(textDirection: TextDirection.ltr)`; brand marks should
  never mirror.

**Missing features:** none that users would notice. An adaptive launcher
icon and splash using the same geometry (Android 12 `SplashScreen` API)
would keep the brand consistent from cold start to first frame.

**Test to add:** a widget test that pumps `OvidMarkAnimated(animation:
reveal)` for 4 s and asserts the controller is completed rather than
repeating. Add a test that `OvidMark()` under a dark theme with
`variant: auto` paints the Paper ring, and a golden of `OvidLockup` under
`TextDirection.rtl`.

---

## Group summary

Overall, the sharing, sync and collaboration screens work but are rough. The
common problems are raw debug output, one-tap destructive actions, primary
CTAs hidden below the fold, and eager lists rebuilt on every sync tick. The
design system has good bones: tokens, cached theme, reduce-motion support and
44dp minimums. However, several core tokens fail WCAG AA, the palette is not
reactive, and localization has not started. Primitive and token fixes are the
highest-leverage work, because one change fixes every screen.

**Top 10 fixes, in recommended order**

| # | Fix | Sections | Effort |
|---|---|---|---|
| 1 | Contrast token pass: theme-aware `accent` (#C0292E light, #F2666A dark text), `textFaint` #6F6B62 / #9A968D, theme-aware `success`/`warn`, a new `inputBorder` token; plus `theme_contrast_test.dart` to lock it | §8, §9 | S |
| 2 | `AetherSheet`: make `pinActions` the default, clamp the body to the height left after the chrome, add a `showAetherSheet` helper with max width 640. This fixes the hidden "Create link" button and every tall sheet | §3, §9 | S |
| 3 | Confirmation dialogs for every destructive one-tap action (revoke share link, close/leave/revoke collaboration) plus an explicit consent confirm for enabling private sync, via a new shared `AetherConfirmDialog` | §3, §4, §7, §9 | S |
| 4 | Remove debug output and raw errors from the UI: collaboration model-state map dump, the shared `owner.error` used for both success and error, generic error strings → typed, mapped copy | §4, §7 | S–M |
| 5 | Sharing reachability: a Share button in the chat app bar, native "Share…" for links, "Update link" plus a stale-preview warning | §2, §3 | M |
| 6 | Shared conversation viewer: Markdown/code rendering, role labels, `ListView.builder`, pinned CTA, retry on error | §1 | M |
| 7 | Private sync and activity performance and status: index records once in the controller, separate the status listenable from the records, use `ListView.builder`, show "Last synced · N pending", structured consent with explicit confirm | §4, §5, §6 | M |
| 8 | Collaboration UX: an invite deep link with Copy/Share/QR that prefills join, a chat layout with a pinned composer, disabled-until-valid inputs, display names | §7 | M |
| 9 | Reactive theming: `ThemeExtension<AetherColors>` + `darkTheme`/`themeMode`, migrate primitives first, then screens; fill all M3 `ColorScheme` roles and button themes | §8 | L |
| 10 | l10n foundation: `flutter_localizations` + `intl` + ARB, localized a11y strings in primitives, directional insets, `DateFormat`/`NumberFormat`, a CI ratchet on hardcoded strings, pseudo-locale goldens | §8, §9, §10 | L (foundation M, rollout L) |

Next in line after the top 10 (all S): 48dp hit targets for the icon-only send
button and segmented items; `AetherStatusDot` semantic labels and shape per
state; `AetherCard.onTap` with an internal ripple; a one-shot splash
`reveal`; deleting or unifying `AetherOtpField`; and remove-animations
support in page transitions.

**Effort key:** S ≤ 1 day, M 2–4 days, L ≥ 1 week (including migrating
call sites and tests).
