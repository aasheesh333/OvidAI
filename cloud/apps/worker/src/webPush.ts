import webpush from "web-push";
import { bareHost, isNonPublicAddress, parseAddressBytes } from "@ovid/shared";

const DEFAULT_PUSH_HOSTS = new Set([
  "fcm.googleapis.com",
  "updates.push.services.mozilla.com",
  "web.push.apple.com",
]);

/** Explicit provider allowlist; a subscription endpoint is never a proxy target. */
export function allowedWebPushHost(hostname: string, allowed = DEFAULT_PUSH_HOSTS): boolean {
  const host = bareHost(hostname);
  return allowed.has(host) && (parseAddressBytes(host) === null || !isNonPublicAddress(host));
}

export interface WebPushSubscription {
  endpoint: string;
  p256dh: string;
  auth: string;
}

export interface WebPushSender {
  send(input: {
    subscription: WebPushSubscription;
    title: string;
    body: string;
    route: string;
    data: Record<string, string>;
  }): Promise<{ ok: true } | { ok: false; code: "unregistered" | "error"; error?: string }>;
}

/** Web routes share the event, not Android's native route spelling. */
export function webNotificationRoute(route: string, data: Record<string, string>): string {
  if (route.startsWith("/c/")) return `/chat/${route.slice(3)}`;
  const scheduleId = data.scheduleId;
  if (scheduleId) return `/schedules/${scheduleId}/runs`;
  if (route.startsWith("/schedule/")) return `/schedules/${route.slice(10)}`;
  return route.startsWith("/") && !route.startsWith("//") ? route : "/chat";
}

export function createWebPushSender(opts: {
  publicKey: string;
  privateKey: string;
  subject: string;
  /** Test seam: no browser/network call. Production uses web-push. */
  send?: (subscription: { endpoint: string; keys: { p256dh: string; auth: string } }, payload: string) => Promise<void>;
  /** Extra operator-approved push service hosts (not arbitrary user targets). */
  allowedHosts?: readonly string[];
}): WebPushSender | null {
  if (!opts.publicKey.trim() || !opts.privateKey.trim() || !opts.subject.trim()) return null;
  const allowed = new Set([...DEFAULT_PUSH_HOSTS, ...(opts.allowedHosts ?? []).map(bareHost)]);
  webpush.setVapidDetails(opts.subject, opts.publicKey, opts.privateKey);
  return {
    async send({ subscription, title, body, route, data }) {
      const url = webNotificationRoute(route, data);
      const payload = JSON.stringify({
        title,
        body,
        data: { ...data, route: url, url },
      });
      const wire = {
        endpoint: subscription.endpoint,
        keys: { p256dh: subscription.p256dh, auth: subscription.auth },
      };
      const target = new URL(subscription.endpoint);
      if (
        target.protocol !== "https:" ||
        target.username !== "" ||
        target.password !== "" ||
        !allowedWebPushHost(target.hostname, allowed)
      ) {
        return { ok: false, code: "error", error: "push_endpoint_refused" };
      }
      try {
        if (opts.send) await opts.send(wire, payload);
        else await webpush.sendNotification(wire, payload, { TTL: 300, timeout: 10_000 });
        return { ok: true };
      } catch (error) {
        const status = (error as { statusCode?: unknown }).statusCode;
        if (status === 404 || status === 410) return { ok: false, code: "unregistered" };
        // Provider text and endpoint are deliberately not included in the inbox.
        return { ok: false, code: "error", error: "web_push_failed" };
      }
    },
  };
}
