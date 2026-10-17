import { hostname } from "node:os";

/**
 * Alert delivery — mint's existing Telegram mechanism, reused verbatim:
 *   env  ALERT_TELEGRAM_BOT_TOKEN + ALERT_TELEGRAM_CHAT_ID
 *   POST https://api.telegram.org/bot<TOKEN>/sendMessage {"chat_id":…,"text":…}
 * plus the optional `OVID_ALERT_WEBHOOK_URL` (POST {text}).
 *
 * Unlike mint's fire-and-forget alerter, watch is a one-shot process whose
 * whole job is delivery: a failed send THROWS (and is logged) so the systemd
 * unit exits nonzero and the state file keeps the alert pending. A swallowed
 * delivery failure is exactly the "blind monitor" failure mode Review Focus
 * #5 forbids.
 */

export interface AlertSink {
  telegram?: { botToken: string; chatId: string };
  webhookUrl?: string;
  log: (line: string) => void;
}

export interface AlertSendOptions {
  /** Test seam; production uses the global fetch. */
  fetchImpl?: typeof fetch;
  /** Per-channel timeout (mint pins 10 s on its alert client). */
  timeoutMs?: number;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function sendAlert(
  sink: AlertSink,
  text: string,
  opts: AlertSendOptions = {},
): Promise<void> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? 10_000;

  const channels: Array<{ name: string; url: string; body: unknown }> = [];
  if (
    sink.telegram !== undefined &&
    sink.telegram.botToken !== "" &&
    sink.telegram.chatId !== ""
  ) {
    channels.push({
      name: "telegram",
      url: `https://api.telegram.org/bot${sink.telegram.botToken}/sendMessage`,
      body: { chat_id: sink.telegram.chatId, text },
    });
  }
  if (sink.webhookUrl !== undefined && sink.webhookUrl !== "") {
    channels.push({
      name: "webhook",
      url: sink.webhookUrl,
      body: { text },
    });
  }

  if (channels.length === 0) {
    const message =
      "no alert sink configured (set ALERT_TELEGRAM_BOT_TOKEN + ALERT_TELEGRAM_CHAT_ID or OVID_ALERT_WEBHOOK_URL)";
    sink.log(`[watch] alert not sent: ${message}`);
    throw new Error(message);
  }

  const failures: string[] = [];
  for (const channel of channels) {
    try {
      const res = await fetchImpl(channel.url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(channel.body),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new Error(`HTTP ${res.status}${body !== "" ? `: ${body.slice(0, 200)}` : ""}`);
      }
      sink.log(`[watch] alert delivered via ${channel.name}`);
    } catch (err) {
      const message = `${channel.name} alert delivery failed: ${errorMessage(err)}`;
      sink.log(`[watch] ${message}`);
      failures.push(message);
    }
  }

  if (failures.length > 0) {
    throw new Error(failures.join("; "));
  }
}

export interface SelfTestOptions extends AlertSendOptions {
  host?: string;
  now?: Date;
}

/**
 * `--self-test`: prove the configured sink end to end at install. The exact
 * line is pinned by the plan; delivery must return HTTP 200 or this throws
 * (main maps that to exit code 1).
 */
export async function runSelfTest(
  sink: AlertSink,
  opts: SelfTestOptions = {},
): Promise<string> {
  const host = opts.host ?? hostname();
  const now = opts.now ?? new Date();
  const text = `TEST alert from ovid-cloud-watch on ${host} at ${now.toISOString()}`;
  await sendAlert(sink, text, opts);
  return text;
}
