/**
 * Notification vocabulary ported from `lib/core/background_notifications.dart`.
 * The cloud worker posts the same kinds on the same three channels and routes
 * a notification tap to the same app routes, so the Android client keeps one
 * mental model across local and cloud runs.
 *
 * `notificationSummary` is a LINE-BY-LINE port of the Dart function: same
 * regexes, same order, same >60%-cut rule. Do not "improve" it — the Flutter
 * tests pin the exact output, and the server and client must agree.
 */

export type NotificationKind =
  | "agentFinished"
  | "agentFailed"
  | "agentNeedsInput"
  | "agentNeedsApproval"
  | "jobDone"
  | "scheduleSucceeded"
  | "scheduleFailed";

export type NotificationChannelKey = "agent_updates" | "scheduler_results" | "background_status";

/** Scheduled-task results have their own channel; everything else is an agent
 *  update (Dart `OvidNotificationKind.channel`). */
export function notificationChannelFor(kind: NotificationKind): NotificationChannelKey {
  switch (kind) {
    case "scheduleSucceeded":
    case "scheduleFailed":
      return "scheduler_results";
    case "agentFinished":
    case "agentFailed":
    case "agentNeedsInput":
    case "agentNeedsApproval":
    case "jobDone":
      return "agent_updates";
  }
}

/** App route a chat notification opens (`NotificationRoutes.chat`). */
export function chatRoute(sessionId: string): string {
  return `/c/${sessionId}`;
}

/** App route a schedule notification opens (`NotificationRoutes.schedule`). */
export function scheduleRoute(sessionId: string): string {
  return `/schedule/${sessionId}`;
}

/**
 * One-line, length-capped summary of model output for a notification body.
 * Port of Dart `notificationSummary(text, {int max = 140})`:
 * - fenced code blocks collapse to ` [code] `
 * - images are dropped, links keep their text
 * - `* _ ` # >` markers are stripped
 * - whitespace collapses to single spaces and the result is trimmed
 * - over `max`, cut to `max - 1` chars, prefer the last space only when it is
 *   past `max * 0.6`, trim the cut, then append `…`
 */
export function notificationSummary(text: string, opts: { max?: number } = {}): string {
  const max = opts.max ?? 140;
  let s = text
    .replace(/```[\s\S]*?```/g, " [code] ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`#>]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
  if (s.length > max) {
    const cut = s.substring(0, max - 1);
    const space = cut.lastIndexOf(" ");
    s = `${(space > max * 0.6 ? cut.substring(0, space) : cut).trimEnd()}…`;
  }
  return s;
}
