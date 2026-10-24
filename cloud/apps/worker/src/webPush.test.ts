import { describe, expect, it, vi } from "vitest";
import { createWebPushSender, webNotificationRoute } from "./webPush.js";

const PUBLIC_KEY = "BKBHvuDGW_6ackgurp40RDuENqLMsHRo2QeVyY_B1MlhyQ0Hl9gmq_e-MNpKBBw_hEQdQD87PnUT0X7JwSCC4zQ";
const PRIVATE_KEY = "CttV1eHay6jqHhooh1eH1GKDi0qGGFgyAXxgnKNMVlM";

describe("web push delivery", () => {
  it("maps shared chat and schedule routes to the Web client", () => {
    expect(webNotificationRoute("/c/session-1", {})).toBe("/chat/session-1");
    expect(webNotificationRoute("/schedule/session-1", { scheduleId: "schedule-1" })).toBe("/schedules/schedule-1/runs");
    expect(webNotificationRoute("/schedule/session-1", {})).toBe("/schedules/session-1");
  });

  it("sends the subscription keys and no private answer text", async () => {
    const send = vi.fn(async () => {});
    const sender = createWebPushSender({
      publicKey: PUBLIC_KEY,
      privateKey: PRIVATE_KEY,
      subject: "mailto:ops@example.test",
      send,
    });
    expect(sender).not.toBeNull();
    await sender!.send({
      subscription: { endpoint: "https://fcm.googleapis.com/one", p256dh: "client-key", auth: "client-auth" },
      title: "Ovid finished your task",
      body: "Tap to see the answer.",
      route: "/c/session-1",
      data: { runId: "run-1", sessionId: "session-1" },
    });
    expect(send).toHaveBeenCalledOnce();
    const [subscription, payload] = send.mock.calls[0]!;
    expect(payload).not.toContain("private answer");
    expect(subscription).toEqual({
      endpoint: "https://fcm.googleapis.com/one",
      keys: { p256dh: "client-key", auth: "client-auth" },
    });
    expect(JSON.parse(payload)).toMatchObject({
      title: "Ovid finished your task",
      data: { route: "/chat/session-1", url: "/chat/session-1", runId: "run-1" },
    });
  });

  it("refuses arbitrary and credential-bearing endpoints before network access", async () => {
    const send = vi.fn(async () => {});
    const sender = createWebPushSender({
      publicKey: PUBLIC_KEY, privateKey: PRIVATE_KEY, subject: "mailto:ops@example.test", send,
    })!;
    for (const endpoint of [
      "https://169.254.169.254/latest/meta-data",
      "https://push.example.test/private",
      "https://user:secret@fcm.googleapis.com/one",
    ]) {
      const result = await sender.send({
        subscription: { endpoint, p256dh: "key", auth: "auth" },
        title: "title", body: "body", route: "/c/session-1", data: {},
      });
      expect(result).toEqual({ ok: false, code: "error", error: "push_endpoint_refused" });
    }
    expect(send).not.toHaveBeenCalled();
  });

  it("marks 404/410 endpoints unregistered and never enables itself without keys", async () => {
    const sender = createWebPushSender({
      publicKey: PUBLIC_KEY, privateKey: PRIVATE_KEY, subject: "mailto:ops@example.test",
      send: async () => { throw Object.assign(new Error("gone"), { statusCode: 410 }); },
    });
    const result = await sender!.send({
      subscription: { endpoint: "https://updates.push.services.mozilla.com/expired", p256dh: "key", auth: "auth" },
      title: "title", body: "body", route: "/c/session-1", data: {},
    });
    expect(result).toEqual({ ok: false, code: "unregistered" });
    expect(createWebPushSender({ publicKey: "", privateKey: "", subject: "" })).toBeNull();
  });
});
