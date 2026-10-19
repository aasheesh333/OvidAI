import { BillingError } from "./domain.js";

/**
 * Minimal Google Play Developer API client (`purchases.subscriptionsv2.get`
 * only) — port of server/billing/play.py.
 *
 * Authentication uses a service account JSON file (env-path only; the key is
 * never read from the environment itself). googleapis/google-auth-library are
 * imported LAZILY so importing this module never reaches the network and tests
 * can inject a fake `PlayDeveloperApi`.
 */

const SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const RETRIES = 2;

export interface PlayDeveloperApi {
  getSubscription(purchaseToken: string): Promise<unknown>;
  /**
   * `purchases.subscriptions.acknowledge` — the service's best-effort,
   * server-side acknowledgement of a VERIFIED active purchase (SH-002). The
   * client still acknowledges too (completePurchase); either is enough for
   * Play. Optional so read-only fakes stay valid.
   */
  acknowledgeSubscription?(productId: string, purchaseToken: string): Promise<void>;
}

function statusOf(err: unknown): number | null {
  if (typeof err !== "object" || err === null) {
    return null;
  }
  const response = (err as { response?: { status?: unknown } }).response;
  return typeof response?.status === "number" ? response.status : null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * `packageName` is the Android application id; `serviceAccountFile` is the
 * path to the Play API service-account JSON. Any Google failure surfaces as a
 * BillingError: 400 purchase_invalid (forged/foreign package), 503
 * play_auth_failed (misconfigured service account) or 503 play_unavailable
 * (transient — callers must not grant or acknowledge).
 */
export function createPlayApi(packageName: string, serviceAccountFile: string): PlayDeveloperApi {
  let clientPromise: Promise<{
    purchases: {
      subscriptionsv2: {
        get(params: { packageName: string; token: string }): Promise<{ data: unknown }>;
      };
      subscriptions: {
        acknowledge(params: {
          packageName: string;
          subscriptionId: string;
          token: string;
          requestBody: Record<string, unknown>;
        }): Promise<unknown>;
      };
    };
  }> | null = null;

  function client() {
    if (clientPromise === null) {
      clientPromise = (async () => {
        const [{ google }, { GoogleAuth }] = await Promise.all([
          import("googleapis"),
          import("google-auth-library"),
        ]);
        const auth = new GoogleAuth({
          keyFile: serviceAccountFile,
          scopes: [SCOPE],
        });
        return google.androidpublisher({ version: "v3", auth });
      })();
    }
    return clientPromise;
  }

  return {
    async getSubscription(purchaseToken: string): Promise<unknown> {
      let api: Awaited<ReturnType<typeof client>>;
      try {
        api = await client();
      } catch {
        // Credentials missing/unreadable: an operator problem, never a grant.
        throw new BillingError(503, "play_auth_failed");
      }
      let last: unknown = null;
      for (let attempt = 0; attempt <= RETRIES; attempt++) {
        try {
          const response = await api.purchases.subscriptionsv2.get({
            packageName,
            token: purchaseToken,
          });
          return response.data;
        } catch (err) {
          const status = statusOf(err);
          if (status === 400 || status === 404 || status === 410) {
            throw new BillingError(400, "purchase_invalid");
          }
          if (status === 401 || status === 403) {
            throw new BillingError(503, "play_auth_failed");
          }
          last = err;
        }
        if (attempt < RETRIES) {
          await sleep(200 * 2 ** attempt);
        }
      }
      throw new BillingError(503, "play_unavailable");
    },

    async acknowledgeSubscription(productId: string, purchaseToken: string): Promise<void> {
      const api = await client();
      await api.purchases.subscriptions.acknowledge({
        packageName,
        subscriptionId: productId,
        token: purchaseToken,
        requestBody: {},
      });
    },
  };
}
