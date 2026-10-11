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
in progress

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

