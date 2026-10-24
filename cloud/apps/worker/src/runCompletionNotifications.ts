import type { EventLog } from "@ovid/events";
import type { Notifier } from "./notify.js";

/**
 * Observe the existing durable terminal event, not a second completion path.
 * Scheduled successes already use notifyScheduleSucceeded. Subagent events do
 * not pass through this queued root-run processor and therefore never notify.
 */
export function withRunCompletionNotification(
  events: EventLog,
  notifier: { notifyAgentFinished?: Notifier["notifyAgentFinished"] } | undefined,
  run: { runId: string; sessionId: string; userId: string; scheduled: boolean },
): EventLog {
  if (notifier?.notifyAgentFinished === undefined || run.scheduled) return events;
  return {
    append: async (sessionId, type, payload) => {
      const event = await events.append(sessionId, type, payload);
      if (type === "run_completed" && payload.runId === run.runId) {
        // The shared engine also emits child completions through this log.
        // Only the captured root run may notify. Never hold terminal ordering
        // on a network fan-out; the processor finalizes durable state first.
        void notifier.notifyAgentFinished!({
          userId: run.userId,
          runId: run.runId,
          sessionId: run.sessionId,
        }).catch(() => {});
      }
      return event;
    },
    readSince: events.readSince.bind(events),
    subscribe: events.subscribe.bind(events),
  };
}
