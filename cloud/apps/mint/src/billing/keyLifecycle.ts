import {
  BillingRemotePlaintextUnavailableError,
  BillingRemoteUnresolvedError,
} from "@ovid/db";
import type { MintDeps } from "../app.js";
import type { LiteLlmAdmin } from "../litellmAdmin.js";
import {
  executeBillingRemoteOperation,
  withBillingAccountWrite,
} from "../windows.js";

/**
 * Owner-rotation adapter. The action service still sees its small generate /
 * delete port, but every call is durable, account-fenced, and readback-verified.
 * No recovered create is turned into plaintext that LiteLLM cannot return.
 */
export function createProtocolKeyLifecycle(
  deps: MintDeps,
  uid: string,
): Pick<LiteLlmAdmin, "keyGenerate" | "keyDelete"> {
  return {
    async keyGenerate(body) {
      return withBillingAccountWrite(deps, uid, async () => {
        if (body.user_id !== uid || typeof body.key_alias !== "string" || body.key_alias === "") {
          throw new BillingRemoteUnresolvedError();
        }
        const alias = body.key_alias;
        const created = await executeBillingRemoteOperation(
          deps,
          uid,
          "key",
          alias,
          body,
          { effect: "generate", idempotencyKey: alias },
        );
        const response = created.response;
        if (response === undefined) throw new BillingRemotePlaintextUnavailableError();
        const key = response.key;
        const token = response.token ?? response.key;
        if (typeof key !== "string" || key === "" || typeof token !== "string" || token === "") {
          throw new BillingRemoteUnresolvedError();
        }
        return { key, token };
      });
    },

    async keyDelete(keys) {
      return withBillingAccountWrite(deps, uid, async () => {
        for (const target of [...new Set(keys)]) {
          await executeBillingRemoteOperation(
            deps,
            uid,
            "key",
            target,
            { keys: [target] },
            { effect: "delete" },
          );
        }
        return 200;
      });
    },
  };
}
