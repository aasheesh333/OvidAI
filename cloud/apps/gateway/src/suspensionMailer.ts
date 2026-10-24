export type SuspensionMailOutcome = "not_configured" | "sent" | "failed";

export interface SuspensionMailInput {
  uid: string;
  /** Stable anomaly:{uid}:{window}:{reason} provider idempotency key. */
  blockId: string;
  /** Server-side users.email only; never a request- or client-supplied address. */
  registeredEmail: string | null;
}

export interface SuspensionMailer {
  send(input: SuspensionMailInput): Promise<SuspensionMailOutcome>;
}

export interface SuspensionMailerOptions {
  apiKey?: string;
  from?: string;
  /** Test seam. Production is Resend's documented HTTPS endpoint. */
  baseUrl?: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 10_000;

function validRegisteredEmail(value: string | null): value is string {
  return (
    value !== null &&
    value.length <= 320 &&
    /^[^\s@]+@[^\s@]+$/.test(value) &&
    !/[\r\n]/.test(value)
  );
}

/**
 * Real Resend delivery, deliberately returning only a three-value outcome.
 * Provider ids, response bodies, API keys, socket errors and raw payloads never
 * cross this boundary. Missing configuration/destination is not called sent.
 */
export function createSuspensionMailer(
  opts: SuspensionMailerOptions = {},
): SuspensionMailer {
  const apiKey = opts.apiKey?.trim() ?? "";
  const from = opts.from?.trim() ?? "";
  const configured = apiKey !== "" && from !== "" && !/[\r\n]/.test(from);
  const fetchImpl = opts.fetchImpl ?? fetch;
  const baseUrl = (opts.baseUrl ?? "https://api.resend.com").replace(/\/+$/, "");
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  return {
    async send({ uid, blockId, registeredEmail }) {
      if (!configured || !validRegisteredEmail(registeredEmail)) return "not_configured";
      try {
        const response = await fetchImpl(`${baseUrl}/emails`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${apiKey}`,
            "content-type": "application/json",
            "idempotency-key": blockId,
          },
          body: JSON.stringify({
            from,
            to: [registeredEmail],
            subject: "Your Ovid Si account has been suspended",
            text:
              "Ovid Si detected unusual network activity on your account. " +
              "Your account access and API keys have been suspended to protect you. " +
              `Reference: ${blockId}. ` +
              "Contact Ovid Si support if this was not you or if you need help reviewing this suspension.",
          }),
          signal: AbortSignal.timeout(timeoutMs),
        });
        // Do not parse or propagate the provider body: only 2xx means sent.
        return response.ok ? "sent" : "failed";
      } catch {
        return "failed";
      }
    },
  };
}

export function createSuspensionMailerFromEnv(
  env: NodeJS.ProcessEnv,
  fetchImpl?: typeof fetch,
): SuspensionMailer {
  return createSuspensionMailer({
    apiKey: env.OVID_RESEND_API_KEY,
    from: env.OVID_SUSPENSION_FROM_EMAIL,
    ...(fetchImpl !== undefined ? { fetchImpl } : {}),
  });
}
