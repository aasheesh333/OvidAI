import type { Redis } from "ioredis";
import type { MintEnv } from "./env.js";

/**
 * Port of mint.py alert(): send an operator alert AT MOST ONCE per `everyS`
 * per kind. Rate limiting is a Redis SETNX on `alertsent:{kind}:{bucket}`
 * (bucket = floor(epoch / everyS)) with TTL everyS — the same key + TTL the
 * Python side used, so both stacks can run side by side during the cutover.
 *
 * Delivery (Telegram + webhook) fires WITHOUT awaiting the caller (Python
 * used a daemon thread; here the promise is deliberately not awaited) and
 * NEVER throws — an alerting outage must not take down request serving.
 */

export type Alerter = (kind: string, message: string, everyS?: number) => Promise<void>;

export function createAlerter(redis: Redis, env: MintEnv): Alerter {
  return async (kind: string, message: string, everyS: number = 3600): Promise<void> => {
    const nowSeconds = Date.now() / 1000;
    const bucket = Math.floor(nowSeconds / everyS);
    const key = `alertsent:${kind}:${bucket}`;
    let first: string | null = null;
    try {
      // SET key "1" NX EX everyS — returns "OK" only for the first caller in
      // the bucket. Redis outages degrade to "assume already sent" (fail
      // closed on noise, never on availability).
      first = await redis.set(key, "1", "EX", everyS, "NX");
    } catch (err) {
      console.log(`[mint] alert ratelimit error: ${errorName(err)}`);
      return;
    }
    if (first !== "OK") {
      return;
    }

    console.log(`[mint] ALERT ${kind}: ${message}`);
    const text = `Ovid gateway alert [${kind}]\n${message}`;

    // Fire-and-forget delivery — never awaited by the caller, never throws.
    void (async () => {
      try {
        if (env.alertTelegramBotToken !== "" && env.alertTelegramChatId !== "") {
          await fetch(
            `https://api.telegram.org/bot${env.alertTelegramBotToken}/sendMessage`,
            {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ chat_id: env.alertTelegramChatId, text }),
            },
          );
        }
        if (env.alertWebhookUrl !== "") {
          await fetch(env.alertWebhookUrl, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ kind, text }),
          });
        }
      } catch (err) {
        console.log(`[mint] alert send failed: ${errorName(err)}`);
      }
    })();
  };
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
