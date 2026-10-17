import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { createLiteLlmAdmin } from "./litellmAdmin.js";

// ---------------------------------------------------------------------------
// Mock LiteLLM admin API: a local http server. NO real network, no services —
// the live stack's LiteLLM is production and is never called from tests
// (same harness shape as the worker's liteLlm.test.ts / P1 Task-9 pattern).
// ---------------------------------------------------------------------------

interface CapturedRequest {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: unknown;
}

let server: Server | undefined;
let baseUrl = "";
let lastRequest: CapturedRequest | undefined;

/** Query params of the last request, URL-decoded. */
function lastQuery(): Record<string, string> {
  const q = lastRequest?.url.split("?")[1] ?? "";
  const out: Record<string, string> = {};
  for (const pair of q.split("&")) {
    if (pair === "") continue;
    const eq = pair.indexOf("=");
    const k = decodeURIComponent(pair.slice(0, eq));
    const v = decodeURIComponent(pair.slice(eq + 1));
    out[k] = v;
  }
  return out;
}

async function startMock(
  handler: (req: IncomingMessage, res: ServerResponse) => void,
): Promise<string> {
  server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      let body: unknown = text;
      try {
        body = JSON.parse(text);
      } catch {
        // keep raw text
      }
      lastRequest = { method: req.method ?? "", url: req.url ?? "", headers: req.headers, body };
      handler(req, res);
    });
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  baseUrl = `http://127.0.0.1:${port}`;
  return baseUrl;
}

function json(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

afterEach(async () => {
  if (server !== undefined) {
    const s = server;
    server = undefined;
    // undici keeps pooled sockets alive — force them closed so server.close()
    // (and vitest) never hangs on idle keep-alive connections.
    s.closeAllConnections();
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
  lastRequest = undefined;
});

const MASTER_KEY = "sk-litellm-master-test";

function admin(): ReturnType<typeof createLiteLlmAdmin> {
  return createLiteLlmAdmin(baseUrl, MASTER_KEY);
}

// ---------------------------------------------------------------------------

describe("keyGenerate", () => {
  it("POSTs /key/generate with the Bearer master key and returns {key, token}", async () => {
    await startMock((_req, res) =>
      json(res, 200, { key: "sk-ovid-user-key", token: "tok-88ab", expires: "never" }),
    );
    const out = await admin().keyGenerate({
      user_id: "uid-1",
      max_budget: 0.15,
      models: ["gpt-x"],
    });
    expect(out).toEqual({ key: "sk-ovid-user-key", token: "tok-88ab" });
    expect(lastRequest?.method).toBe("POST");
    expect(lastRequest?.url).toBe("/key/generate");
    expect(lastRequest?.headers.authorization).toBe(`Bearer ${MASTER_KEY}`);
    expect(lastRequest?.body).toEqual({ user_id: "uid-1", max_budget: 0.15, models: ["gpt-x"] });
  });

  it("non-2xx → throws (mint.py raise_for_status parity)", async () => {
    await startMock((_req, res) => json(res, 500, { error: "boom" }));
    await expect(admin().keyGenerate({})).rejects.toThrow(/key\/generate/);
  });
});

describe("keyUpdate", () => {
  it("4xx → resolves (logged, not thrown) — Python parity: failures print status", async () => {
    await startMock((_req, res) => json(res, 400, { error: "bad key" }));
    await expect(
      admin().keyUpdate({ key: "tok-1", max_budget: 1 }),
    ).resolves.toBeUndefined();
    expect(lastRequest?.url).toBe("/key/update");
    expect(lastRequest?.headers.authorization).toBe(`Bearer ${MASTER_KEY}`);
  });

  it("2xx → resolves", async () => {
    await startMock((_req, res) => json(res, 200, { success: true }));
    await expect(admin().keyUpdate({ key: "tok-1" })).resolves.toBeUndefined();
  });

  it("keyUpdateStatus returns the HTTP status (0 on a network error)", async () => {
    await startMock((_req, res) => json(res, 400, { error: "bad key" }));
    expect(await admin().keyUpdateStatus({ key: "tok-1" })).toBe(400);
    const down = createLiteLlmAdmin("http://127.0.0.1:1", MASTER_KEY);
    expect(await down.keyUpdateStatus({ key: "tok-1" })).toBe(0);
  });
});

describe("request timeout (T3-review I1 carry)", () => {
  it("aborts a connected-but-silent admin call after the configured timeout", async () => {
    await startMock(() => {
      // never respond
    });
    const hung = createLiteLlmAdmin(baseUrl, MASTER_KEY, fetch, 40);
    await expect(hung.keyGenerate({})).rejects.toThrow();
  });
});

describe("keyInfo", () => {
  it("200 → the info object (unwrapped from LiteLLM's {info:…} envelope)", async () => {
    await startMock((_req, res) =>
      json(res, 200, { info: { key: "tok-1", budget_duration: "30d", blocked: false } }),
    );
    const info = await admin().keyInfo("tok-1");
    expect(info).toEqual({ key: "tok-1", budget_duration: "30d", blocked: false });
    expect(lastQuery()).toEqual({ key: "tok-1" });
  });

  it("404 → null", async () => {
    await startMock((_req, res) => json(res, 404, { error: "not found" }));
    expect(await admin().keyInfo("tok-gone")).toBeNull();
  });

  it("401/403 → null", async () => {
    await startMock((_req, res) => json(res, 401, { error: "nope" }));
    expect(await admin().keyInfo("tok-1")).toBeNull();
    await startMock((_req, res) => json(res, 403, { error: "nope" }));
    expect(await admin().keyInfo("tok-1")).toBeNull();
  });
});

describe("key block/unblock/delete", () => {
  it.each([
    ["keyBlock", "/key/block", "block"],
    ["keyUnblock", "/key/unblock", "unblock"],
  ] as const)("%s posts {key} and returns the status", async (method, path, _label) => {
    await startMock((_req, res) => json(res, 200, { success: true }));
    const status = await admin()[method]("tok-1");
    expect(status).toBe(200);
    expect(lastRequest?.url).toBe(path);
    expect(lastRequest?.body).toEqual({ key: "tok-1" });
  });

  it("keyDelete posts {keys:[…]} and returns the status", async () => {
    await startMock((_req, res) => json(res, 201, { success: true }));
    const status = await admin().keyDelete(["tok-1", "tok-2"]);
    expect(status).toBe(201);
    expect(lastRequest?.url).toBe("/key/delete");
    expect(lastRequest?.body).toEqual({ keys: ["tok-1", "tok-2"] });
  });
});

describe("userInfo / userUpdate", () => {
  it("userInfo maps {user_info:{spend,budget_duration}}", async () => {
    await startMock((_req, res) =>
      json(res, 200, { user_info: { user_id: "uid-1", spend: 1.25, budget_duration: "30d" } }),
    );
    const out = await admin().userInfo("uid-1");
    expect(out).toEqual({ spend: 1.25, budget_duration: "30d" });
    expect(lastQuery()).toEqual({ user_id: "uid-1" });
  });

  it("userInfo 404 → null", async () => {
    await startMock((_req, res) => json(res, 404, { error: "no such user" }));
    expect(await admin().userInfo("uid-404")).toBeNull();
  });

  it("userInfoStatus distinguishes 404 from an outage (0/5xx) for the budget-clock rule", async () => {
    await startMock((_req, res) => json(res, 404, { error: "no such user" }));
    expect(await admin().userInfoStatus("uid-404")).toEqual({ status: 404, info: null });

    await startMock((_req, res) => json(res, 500, { error: "boom" }));
    expect(await admin().userInfoStatus("uid-1")).toEqual({ status: 500, info: null });
  });

  it("userUpdate posts the body and returns the status", async () => {
    await startMock((_req, res) => json(res, 200, { success: true }));
    const status = await admin().userUpdate({ user_id: "uid-1", max_budget: 2 });
    expect(status).toBe(200);
    expect(lastRequest?.url).toBe("/user/update");
    expect(lastRequest?.body).toEqual({ user_id: "uid-1", max_budget: 2 });
  });
});

describe("teams", () => {
  it("teamNew posts the body and returns {team_id}", async () => {
    await startMock((_req, res) => json(res, 200, { team_id: "team-9", team_alias: "ovid-web" }));
    const out = await admin().teamNew({ team_alias: "ovid-web", max_budget: 25 });
    expect(out).toEqual({ team_id: "team-9" });
    expect(lastRequest?.url).toBe("/team/new");
    expect(lastRequest?.body).toEqual({ team_alias: "ovid-web", max_budget: 25 });
  });

  it("teamNew non-2xx → throws", async () => {
    await startMock((_req, res) => json(res, 500, { error: "boom" }));
    await expect(admin().teamNew({})).rejects.toThrow(/team\/new/);
  });

  it("teamUpdate posts the body and returns the status", async () => {
    await startMock((_req, res) => json(res, 200, { success: true }));
    const status = await admin().teamUpdate({ team_id: "team-9", max_budget: 40 });
    expect(status).toBe(200);
    expect(lastRequest?.url).toBe("/team/update");
    expect(lastRequest?.body).toEqual({ team_id: "team-9", max_budget: 40 });
  });
});

describe("spendLogs", () => {
  it("maps query params key/start_date/end_date and unwraps {data:[…]}", async () => {
    await startMock((_req, res) =>
      json(res, 200, { data: [{ api_key: "tok-1", spend: 0.01, model: "gpt-x" }] }),
    );
    const rows = await admin().spendLogs({
      key: "tok-1",
      start_date: "2026-10-01",
      end_date: "2026-10-18",
    });
    expect(rows).toEqual([{ api_key: "tok-1", spend: 0.01, model: "gpt-x" }]);
    // LiteLLM's /spend/logs query param is api_key (mint.py `_spend_logs`);
    // the wrapper's argument is still named `key`.
    expect(lastQuery()).toEqual({
      api_key: "tok-1",
      start_date: "2026-10-01",
      end_date: "2026-10-18",
    });
  });

  it("a bare JSON array response is accepted as-is (mint.py parity)", async () => {
    await startMock((_req, res) => json(res, 200, [{ api_key: "tok-1", spend: 0.02 }]));
    const rows = await admin().spendLogs({ key: "tok-1", start_date: "s", end_date: "e" });
    expect(rows).toEqual([{ api_key: "tok-1", spend: 0.02 }]);
  });

  it("non-200 → [] (fail-soft like _spend_logs)", async () => {
    await startMock((_req, res) => json(res, 500, { error: "boom" }));
    const rows = await admin().spendLogs({ key: "tok-1", start_date: "s", end_date: "e" });
    expect(rows).toEqual([]);
  });
});

describe("modelInfo / globalSpend", () => {
  it("modelInfo unwraps {data:[…]}", async () => {
    await startMock((_req, res) =>
      json(res, 200, { data: [{ model_name: "ovid-chat", model_info: {} }] }),
    );
    const rows = await admin().modelInfo();
    expect(rows).toEqual([{ model_name: "ovid-chat", model_info: {} }]);
    expect(lastRequest?.url).toBe("/model/info");
    expect(lastRequest?.headers.authorization).toBe(`Bearer ${MASTER_KEY}`);
  });

  it("modelInfo non-200 → [] (mint.py fail-soft parity)", async () => {
    await startMock((_req, res) => json(res, 503, { error: "down" }));
    expect(await admin().modelInfo()).toEqual([]);
  });

  it("globalSpend maps {spend: number}", async () => {
    await startMock((_req, res) => json(res, 200, { spend: 123.45 }));
    expect(await admin().globalSpend()).toBe(123.45);
    expect(lastRequest?.url).toBe("/global/spend");
  });
});

describe("rawModels", () => {
  it("forwards the USER's Authorization header untouched (never the master key)", async () => {
    await startMock((_req, res) =>
      json(res, 200, { object: "list", data: [{ id: "ovid-chat" }] }),
    );
    const out = await admin().rawModels("Bearer sk-user-virtual-key");
    expect(out.status).toBe(200);
    expect(out.body).toEqual({ object: "list", data: [{ id: "ovid-chat" }] });
    expect(out.text).toBe(JSON.stringify({ object: "list", data: [{ id: "ovid-chat" }] }));
    expect(lastRequest?.url).toBe("/v1/models");
    expect(lastRequest?.headers.authorization).toBe("Bearer sk-user-virtual-key");
  });

  it("a non-JSON body is surfaced as text with body null", async () => {
    await startMock((_req, res) => {
      res.writeHead(502, { "content-type": "text/html" });
      res.end("<html>bad gateway</html>");
    });
    const out = await admin().rawModels("Bearer sk-user");
    expect(out.status).toBe(502);
    expect(out.body).toBeNull();
    expect(out.text).toBe("<html>bad gateway</html>");
  });
});
