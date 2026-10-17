import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

/**
 * Local FakeLiteLLM for the Task 5 tests — a port of
 * server/mint/tests/conftest.py's FakeLiteLLM onto a real
 * http.createServer (the Task 3 harness pattern). NO network, no services:
 * the live stack's LiteLLM is production and is never called from tests.
 *
 * Endpoints covered: /key/info, /key/update, /key/generate, /key/block,
 * /key/unblock, /user/info, /user/update, /model/info, /spend/logs,
 * /team/new, /team/update. Every call is recorded with its body/query so the
 * budget-clock assertions can inspect exactly what mint sent.
 */

export const MASTER_KEY = "sk-litellm-master-test";

export interface FakeKey {
  token: string;
  spend: number;
  max_budget: number | null;
  budget_duration: string | null;
  blocked: boolean;
  budget_reset_at: string | null;
}

export interface FakeUser {
  spend: number;
  budget_duration?: string | null;
  max_budget?: number | null;
}

export interface FakeModel {
  model_name: string;
  litellm_params: { model: string };
  model_info: Record<string, unknown>;
}

export interface FakeLog {
  api_key: string;
  model: string;
  model_group: string | null;
  prompt_tokens: number;
  completion_tokens: number;
  spend: number;
  call_type: string;
  startTime: string;
  status: string;
  model_id?: string;
}

export interface FakeCall {
  method: string;
  path: string;
  body: Record<string, unknown>;
  params: Record<string, string>;
}

export class FakeLiteLlm {
  readonly keys = new Map<string, FakeKey>();
  readonly users = new Map<string, FakeUser>();
  readonly models: FakeModel[] = [];
  readonly logs: FakeLog[] = [];
  readonly calls: FakeCall[] = [];

  /** When true /user/info answers 500 (the outage path). */
  failUserInfo = false;

  baseUrl = "";
  private server: Server | undefined;
  private counter = 0;

  async start(): Promise<string> {
    this.server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let body: Record<string, unknown> = {};
        try {
          const parsed: unknown = JSON.parse(text);
          if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
            body = parsed as Record<string, unknown>;
          }
        } catch {
          // keep {}
        }
        this.handle(req, res, body);
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const { port } = this.server.address() as AddressInfo;
    this.baseUrl = `http://127.0.0.1:${port}`;
    return this.baseUrl;
  }

  async stop(): Promise<void> {
    if (this.server === undefined) return;
    const server = this.server;
    this.server = undefined;
    // undici keeps pooled sockets alive — force them closed so close() never
    // hangs on idle keep-alive connections.
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  /** Per-test isolation: keys, users, logs, calls and the generate counter. */
  reset(): void {
    this.keys.clear();
    this.users.clear();
    this.models.length = 0;
    this.logs.length = 0;
    this.calls.length = 0;
    this.counter = 0;
  }

  addKey(token: string, opts: Partial<FakeKey> = {}): string {    this.keys.set(token, {
      token,
      spend: 0,
      max_budget: null,
      budget_duration: "24h",
      blocked: false,
      budget_reset_at: new Date(Date.now() + 10 * 3600_000).toISOString(),
      ...opts,
    });
    return token;
  }

  addModel(
    name: string,
    under: string,
    inp?: number,
    out?: number,
    perImage?: number,
    mode?: string,
    mid?: string,
  ): void {
    const info: Record<string, unknown> = { id: mid ?? `dep-${this.models.length}` };
    if (inp !== undefined) info.input_cost_per_token = inp;
    if (out !== undefined) info.output_cost_per_token = out;
    if (perImage !== undefined) info.output_cost_per_image = perImage;
    if (mode !== undefined) info.mode = mode;
    this.models.push({
      model_name: name,
      litellm_params: { model: under },
      model_info: info,
    });
  }

  addLog(
    token: string,
    model: string,
    opts: {
      group?: string | null;
      pin?: number;
      pout?: number;
      spend?: number;
      callType?: string;
      agoMin?: number;
      status?: string;
      modelId?: string;
    } = {},
  ): void {
    this.logs.push({
      api_key: token,
      model,
      model_group: opts.group ?? null,
      prompt_tokens: opts.pin ?? 100,
      completion_tokens: opts.pout ?? 50,
      spend: opts.spend ?? 0.001,
      call_type: opts.callType ?? "acompletion",
      startTime: new Date(Date.now() - (opts.agoMin ?? 5) * 60_000).toISOString(),
      status: opts.status ?? "success",
      ...(opts.modelId === undefined ? {} : { model_id: opts.modelId }),
    });
  }

  /** POST bodies captured for one path, in call order. */
  posts(path: string): Record<string, unknown>[] {
    return this.calls
      .filter((c) => c.method === "POST" && c.path === path)
      .map((c) => c.body);
  }

  private handle(
    req: IncomingMessage,
    res: ServerResponse,
    body: Record<string, unknown>,
  ): void {
    if (req.headers.authorization !== `Bearer ${MASTER_KEY}`) {
      json(res, 401, { error: "auth" });
      return;
    }
    const url = new URL(req.url ?? "/", "http://fake");
    const path = url.pathname;
    const params: Record<string, string> = {};
    for (const [k, v] of url.searchParams) params[k] = v;
    this.calls.push({ method: req.method ?? "", path, body, params });

    if (path === "/key/info") {
      const info = this.keys.get(params.key ?? "");
      if (info === undefined) {
        json(res, 404, { error: "nf" });
      } else {
        json(res, 200, { key: params.key, info });
      }
      return;
    }
    if (path === "/key/update") {
      const info = this.keys.get(String(body.key ?? ""));
      if (info === undefined) {
        json(res, 404, {});
        return;
      }
      for (const field of ["max_budget", "budget_duration", "spend"] as const) {
        if (field in body) {
          (info as unknown as Record<string, unknown>)[field] = body[field];
        }
      }
      json(res, 200, info);
      return;
    }
    if (path === "/key/block" || path === "/key/unblock") {
      const info = this.keys.get(String(body.key ?? ""));
      if (info !== undefined) info.blocked = path === "/key/block";
      json(res, 200, {});
      return;
    }
    if (path === "/key/generate") {
      this.counter += 1;
      const token = `hashed-${this.counter}`;
      this.addKey(token, {
        max_budget: (body.max_budget as number | null | undefined) ?? null,
        budget_duration: (body.budget_duration as string | null | undefined) ?? null,
      });
      json(res, 200, { key: `sk-live-${this.counter}`, token });
      return;
    }
    if (path === "/user/info") {
      if (this.failUserInfo) {
        json(res, 500, { error: "boom" });
        return;
      }
      const user = this.users.get(params.user_id ?? "");
      if (user === undefined) {
        json(res, 404, {});
      } else {
        json(res, 200, { user_info: user });
      }
      return;
    }
    if (path === "/user/update") {
      const uid = String(body.user_id ?? "");
      const user = this.users.get(uid) ?? { spend: 0 };
      for (const field of ["max_budget", "budget_duration", "spend"] as const) {
        if (field in body) {
          (user as unknown as Record<string, unknown>)[field] = body[field];
        }
      }
      this.users.set(uid, user);
      json(res, 200, user);
      return;
    }
    if (path === "/model/info") {
      json(res, 200, { data: this.models });
      return;
    }
    if (path === "/spend/logs") {
      // LiteLLM's real query param is api_key (mint.py `_spend_logs`); accept
      // the legacy `key` spelling too so the harness is not the subject.
      const key = params.api_key ?? params.key ?? "";
      json(res, 200, this.logs.filter((row) => row.api_key === key));
      return;
    }
    if (path === "/team/new" || path === "/team/update") {
      json(res, 200, { team_id: "team-web" });
      return;
    }
    json(res, 404, { error: path });
  }
}

function json(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

/** conftest.py standard_models: six auto members + big-pro + image + mystery. */
export function standardModels(fake: FakeLiteLlm): Record<string, [number, number]> {
  const prices: Record<string, [number, number]> = {
    "deepseek-v4.1-flash": [1e-7, 4e-7],
    "glm-5.3-flash": [2e-7, 8e-7],
    "gemini-3.7-flash": [1.5e-7, 6e-7],
    "gemini-3.8-flash": [3e-7, 2.5e-6],
    "minimax-m3": [2e-7, 1e-6],
    "gpt-5.6-luna": [2.5e-7, 2e-6],
  };
  for (const [name, [inp, out]] of Object.entries(prices)) {
    fake.addModel(name, `prov/${name}`, inp, out, undefined, "chat");
    fake.addModel("auto", `prov/${name}`, inp, out, undefined, "chat");
  }
  fake.addModel("big-pro", "prov/big-pro", 5e-6, 2e-5, undefined, "chat");
  fake.addModel("ovid-image", "prov/img-1", undefined, undefined, 0.04, "image_generation");
  fake.addModel("mystery", "prov/mystery");
  return prices;
}
