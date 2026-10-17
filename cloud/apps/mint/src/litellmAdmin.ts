/**
 * Thin typed wrapper over the on-box LiteLLM admin API — the Node port of
 * mint.py's litellm_client()/_admin_headers() call sites. Every admin call
 * carries `Authorization: Bearer <masterKey>`; rawModels is the one exception
 * (Task 6's /v1/models passthrough forwards the USER's key untouched).
 *
 * The LIVE stack's LiteLLM is production: tests always inject fetchImpl (or
 * point baseUrl at a local http.createServer mock) — never the real box.
 *
 * Failure semantics follow mint.py exactly:
 *  - keyGenerate / teamNew raise on non-2xx (Python raise_for_status) — their
 *    callers translate failures into contract errors;
 *  - keyUpdate / userUpdate / keyBlock / keyUnblock / keyDelete only LOG a
 *    non-2xx status (Python prints the status and moves on) — mint must keep
 *    serving when a backstop write fails;
 *  - keyInfo / userInfo map misses (404/401/403 and other non-200s) to null;
 *  - spendLogs / modelInfo fail soft to [] (Python returns []);
 *  - network errors on the log-only calls resolve to status 0 (never thrown).
 */

/** /key/info row — LiteLLM's key info object (mint.py: data.info ?? data). */
export interface KeyInfo {
  budget_duration?: string | null;
  max_budget?: number | null;
  spend?: number;
  blocked?: boolean;
  models?: string[];
  metadata?: Record<string, unknown> | null;
  expires?: string | null;
  [field: string]: unknown;
}

/** /spend/logs row (attribution is Task 5's job — this is the raw row). */
export interface SpendLogRow {
  api_key?: string | null;
  model?: string | null;
  spend?: number | string | null;
  startTime?: string | null;
  call_type?: string | null;
  requester_ip?: string | null;
  tokens?: Record<string, unknown> | null;
  [field: string]: unknown;
}

/** /model/info deployment row: {model_name, model_info, litellm_params, …}. */
export interface ModelInfoRow {
  model_name?: string;
  model_info?: Record<string, unknown>;
  litellm_params?: Record<string, unknown>;
  [field: string]: unknown;
}

export interface LiteLlmAdmin {
  /** POST /key/generate — throws on non-2xx. */
  keyGenerate(body: Record<string, unknown>): Promise<{ key: string; token?: string }>;
  /** POST /key/update — non-2xx logged, NOT thrown (Python parity). */
  keyUpdate(body: Record<string, unknown>): Promise<void>;
  /** Same call as keyUpdate but returns the HTTP status (0 = network error). */
  keyUpdateStatus(body: Record<string, unknown>): Promise<number>;
  /** GET /key/info?key= — 404/401/403 (any non-200) → null. */
  keyInfo(key: string): Promise<KeyInfo | null>;
  /**
   * GET /key/info?key= WITH the HTTP status. Task 6's key-state rule must tell
   * a gone key (401/403/404 → re-issue) from a LiteLLM outage (status 0/5xx →
   * keep the key; never churn keys during an outage), exactly like mint.py's
   * _key_state.
   */
  keyInfoStatus(key: string): Promise<{ status: number; info: KeyInfo | null }>;
  /** POST /key/block {key} — returns the HTTP status (0 = network error). */
  keyBlock(key: string): Promise<number>;
  /** POST /key/unblock {key} — returns the HTTP status (0 = network error). */
  keyUnblock(key: string): Promise<number>;
  /** POST /key/delete {keys} — returns the HTTP status (0 = network error). */
  keyDelete(keys: string[]): Promise<number>;
  /** GET /user/info?user_id= — non-200 → null. */
  userInfo(
    userId: string,
  ): Promise<{ spend: number; budget_duration?: string | null } | null>;
  /**
   * userInfo WITH the HTTP status: the budget-clock rule must tell a 404
   * (user unknown → send the duration) from an outage (status 0/5xx → leave
   * the clock alone). mint.py's ensure_user_budget branches on exactly this.
   */
  userInfoStatus(userId: string): Promise<{
    status: number;
    info: { spend: number; budget_duration?: string | null } | null;
  }>;
  /** POST /user/update — returns the HTTP status (0 = network error). */
  userUpdate(body: Record<string, unknown>): Promise<number>;
  /** POST /team/new — throws on non-2xx. */
  teamNew(body: Record<string, unknown>): Promise<{ team_id: string }>;
  /** POST /team/update — returns the HTTP status (0 = network error). */
  teamUpdate(body: Record<string, unknown>): Promise<number>;
  /** GET /spend/logs — non-200 → [] (fail-soft like _spend_logs). */
  spendLogs(params: { key: string; start_date: string; end_date: string }): Promise<SpendLogRow[]>;
  /** GET /model/info — non-200 → [] (fail-soft like model_catalog). */
  modelInfo(): Promise<ModelInfoRow[]>;
  /** GET /global/spend — throws on non-2xx (a masked 0 would silence alerts). */
  globalSpend(): Promise<number>;
  /**
   * GET /v1/models with the USER's key (Task 6 passthrough): the
   * authorizationHeader is forwarded UNTOUCHED — never the master key.
   */
  rawModels(authorizationHeader: string): Promise<{ status: number; body: unknown; text: string }>;
}

interface RequestOptions {
  method: "GET" | "POST";
  json?: Record<string, unknown>;
  params?: Record<string, string>;
  /** Overrides the master-key Authorization (rawModels only). */
  authorization?: string;
}

export function createLiteLlmAdmin(
  baseUrl: string,
  masterKey: string,
  fetchImpl: typeof fetch = fetch,
  /**
   * T3-review I1 carry: mint.py pins `litellm_client(timeout=20)`; undici's
   * default would let a connected-but-silent LiteLLM hang a request-path call
   * for ~300 s. Every admin fetch carries this AbortSignal timeout.
   */
  timeoutMs: number = 20_000,
): LiteLlmAdmin {
  const root = baseUrl.replace(/\/+$/, "");

  async function request(
    path: string,
    opts: RequestOptions,
  ): Promise<Response> {
    const url = new URL(`${root}${path}`);
    for (const [k, v] of Object.entries(opts.params ?? {})) {
      url.searchParams.set(k, v);
    }
    const headers: Record<string, string> = {
      authorization: opts.authorization ?? `Bearer ${masterKey}`,
    };
    if (opts.json !== undefined) {
      headers["content-type"] = "application/json";
    }
    return fetchImpl(url, {
      method: opts.method,
      headers,
      body: opts.json === undefined ? undefined : JSON.stringify(opts.json),
      signal: AbortSignal.timeout(timeoutMs),
    });
  }

  /** Read + parse JSON, tolerating a non-JSON body (→ undefined). */
  async function readJson(res: Response): Promise<unknown> {
    const text = await res.text();
    try {
      return JSON.parse(text);
    } catch {
      return undefined;
    }
  }

  /** Status-only POST: logs non-2xx + network errors, never throws. */
  async function logOnlyPost(
    path: string,
    body: Record<string, unknown>,
  ): Promise<number> {
    try {
      const res = await request(path, { method: "POST", json: body });
      if (!res.ok) {
        console.log(`[mint] ${path.slice(1)} ${res.status}`);
      }
      return res.status;
    } catch (err) {
      console.log(`[mint] ${path.slice(1)} error: ${errorName(err)}`);
      return 0;
    }
  }

  /** user/info with the HTTP status (see userInfoStatus in the interface). */
  async function userInfoStatus(userId: string): Promise<{
    status: number;
    info: { spend: number; budget_duration?: string | null } | null;
  }> {
    try {
      const res = await request("/user/info", {
        method: "GET",
        params: { user_id: userId },
      });
      if (!res.ok) {
        return { status: res.status, info: null };
      }
      const data = (await readJson(res)) as {
        user_info?: { spend?: unknown; budget_duration?: unknown };
      };
      const info = data?.user_info ?? {};
      return {
        status: res.status,
        info: {
          spend: Number(info.spend ?? 0) || 0,
          budget_duration:
            info.budget_duration === undefined || info.budget_duration === null
              ? null
              : String(info.budget_duration),
        },
      };
    } catch (err) {
      console.log(`[mint] user/info error: ${errorName(err)}`);
      return { status: 0, info: null };
    }
  }

  /** key/info with the HTTP status (see keyInfoStatus in the interface). */
  async function keyInfoStatus(key: string): Promise<{
    status: number;
    info: KeyInfo | null;
  }> {
    try {
      const res = await request("/key/info", { method: "GET", params: { key } });
      if (!res.ok) {
        return { status: res.status, info: null };
      }
      // mint.py: data.get("info", data) or {} — the row is under "info"
      // when present, otherwise the body itself is the row.
      const data = await readJson(res);
      if (data === undefined || data === null || typeof data !== "object" || Array.isArray(data)) {
        return { status: res.status, info: {} };
      }
      const obj = data as Record<string, unknown>;
      const row = "info" in obj ? obj.info : obj;
      if (row === null || row === undefined || typeof row !== "object" || Array.isArray(row)) {
        return { status: res.status, info: {} };
      }
      return { status: res.status, info: row as KeyInfo };
    } catch (err) {
      console.log(`[mint] key/info error: ${errorName(err)}`);
      return { status: 0, info: null };
    }
  }

  return {
    async keyGenerate(body) {
      const res = await request("/key/generate", { method: "POST", json: body });
      if (!res.ok) {
        throw new Error(`key/generate ${res.status}`);
      }
      const data = (await readJson(res)) as { key?: unknown; token?: unknown };
      return {
        key: String(data?.key ?? ""),
        token: data?.token === undefined || data?.token === null ? undefined : String(data.token),
      };
    },

    async keyUpdate(body) {
      // Python parity: key/update failures print the status, never raise.
      await logOnlyPost("/key/update", body);
    },

    keyUpdateStatus: (body) => logOnlyPost("/key/update", body),

    async keyInfo(key) {
      return (await keyInfoStatus(key)).info;
    },

    keyInfoStatus,

    keyBlock: (key) => logOnlyPost("/key/block", { key }),
    keyUnblock: (key) => logOnlyPost("/key/unblock", { key }),
    keyDelete: (keys) => logOnlyPost("/key/delete", { keys }),

    async userInfo(userId) {
      const { info } = await userInfoStatus(userId);
      return info;
    },

    userInfoStatus,

    userUpdate: (body) => logOnlyPost("/user/update", body),

    async teamNew(body) {
      const res = await request("/team/new", { method: "POST", json: body });
      if (!res.ok) {
        throw new Error(`team/new ${res.status}`);
      }
      const data = (await readJson(res)) as { team_id?: unknown };
      return { team_id: String(data?.team_id ?? "") };
    },

    teamUpdate: (body) => logOnlyPost("/team/update", body),

    async spendLogs(params) {
      try {
        // mint.py's _spend_logs sends api_key (LiteLLM's real query param);
        // the wrapper's argument stays `key` for its callers.
        const res = await request("/spend/logs", {
          method: "GET",
          params: {
            api_key: params.key,
            start_date: params.start_date,
            end_date: params.end_date,
          },
        });
        if (!res.ok) {
          return [];
        }
        const data = await readJson(res);
        const rows = Array.isArray(data)
          ? data
          : ((data as { data?: unknown[] } | undefined)?.data ?? []);
        return rows.filter((r): r is SpendLogRow => typeof r === "object" && r !== null);
      } catch (err) {
        console.log(`[mint] spend/logs error: ${errorName(err)}`);
        return [];
      }
    },

    async modelInfo() {
      try {
        const res = await request("/model/info", { method: "GET" });
        if (!res.ok) {
          return [];
        }
        const data = (await readJson(res)) as { data?: unknown[] } | undefined;
        const rows = data?.data ?? [];
        return rows.filter((r): r is ModelInfoRow => typeof r === "object" && r !== null);
      } catch (err) {
        console.log(`[mint] model/info error: ${errorName(err)}`);
        return [];
      }
    },

    async globalSpend() {
      const res = await request("/global/spend", { method: "GET" });
      if (!res.ok) {
        // NOT fail-soft: a silent 0 would read as "no spend today" and mute
        // the daily-spend alert — let the sweep monitor log the failure.
        throw new Error(`global/spend ${res.status}`);
      }
      const data = (await readJson(res)) as { spend?: unknown };
      return Number(data?.spend ?? 0) || 0;
    },

    async rawModels(authorizationHeader) {
      const res = await request("/v1/models", {
        method: "GET",
        authorization: authorizationHeader,
      });
      const text = await res.text();
      let body: unknown = null;
      try {
        body = JSON.parse(text);
      } catch {
        body = null;
      }
      return { status: res.status, body, text };
    },
  };
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
