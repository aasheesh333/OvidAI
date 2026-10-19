import { describe, expect, it } from "vitest";
import type { App } from "firebase-admin/app";
import { createFirebaseVerifier, type AppCheckMode } from "./auth.js";
import { loadGatewayEnv } from "./env.js";

/**
 * OVID_APPCHECK_MODE (required | optional | off). The Firebase ID token is
 * verified identically in every mode; only the App Check half changes.
 */

interface Calls {
  idTokens: string[];
  appCheckTokens: string[];
}

function fakeServices(calls: Calls, opts: { badAppCheck?: boolean; badIdToken?: boolean } = {}) {
  return () => ({
    auth: {
      verifyIdToken: async (token: string) => {
        calls.idTokens.push(token);
        if (opts.badIdToken === true) throw new Error("id token expired");
        return { uid: "u1", email: null, auth_time: 1, firebase: { sign_in_provider: "google.com" } };
      },
    },
    appCheck: {
      verifyToken: async (token: string) => {
        calls.appCheckTokens.push(token);
        if (opts.badAppCheck === true) throw new Error("app check invalid");
        return { appId: "app", token: {} };
      },
    },
  });
}

function verifierFor(mode: AppCheckMode, opts: { badAppCheck?: boolean; badIdToken?: boolean } = {}) {
  const calls: Calls = { idTokens: [], appCheckTokens: [] };
  const verifier = createFirebaseVerifier({} as unknown as App, {
    appCheckMode: mode,
    services: fakeServices(calls, opts) as never,
  });
  return { verifier, calls };
}

describe("createFirebaseVerifier — OVID_APPCHECK_MODE", () => {
  it("defaults to required (missing token rejected before any firebase call)", async () => {
    const verifier = createFirebaseVerifier({} as unknown as App);
    await expect(verifier("id", null)).rejects.toThrow();
  });

  describe("required", () => {
    it("rejects a missing App Check token without touching the ID token", async () => {
      const { verifier, calls } = verifierFor("required");
      await expect(verifier("id", null)).rejects.toThrow();
      expect(calls.idTokens).toEqual([]);
    });
    it("rejects an invalid App Check token", async () => {
      const { verifier } = verifierFor("required", { badAppCheck: true });
      await expect(verifier("id", "bad")).rejects.toThrow();
    });
    it("accepts a valid pair", async () => {
      const { verifier, calls } = verifierFor("required");
      await expect(verifier("id", "ac")).resolves.toMatchObject({ uid: "u1" });
      expect(calls).toEqual({ idTokens: ["id"], appCheckTokens: ["ac"] });
    });
  });

  describe("optional", () => {
    it("accepts a missing App Check token (ID token still verified)", async () => {
      const { verifier, calls } = verifierFor("optional");
      await expect(verifier("id", null)).resolves.toMatchObject({ uid: "u1" });
      expect(calls).toEqual({ idTokens: ["id"], appCheckTokens: [] });
    });
    it("verifies a present token and rejects it when invalid", async () => {
      const { verifier, calls } = verifierFor("optional", { badAppCheck: true });
      await expect(verifier("id", "bad")).rejects.toThrow();
      expect(calls.appCheckTokens).toEqual(["bad"]);
    });
    it("accepts a present valid token", async () => {
      const { verifier, calls } = verifierFor("optional");
      await expect(verifier("id", "ac")).resolves.toMatchObject({ uid: "u1" });
      expect(calls.appCheckTokens).toEqual(["ac"]);
    });
    it("still rejects a bad ID token", async () => {
      const { verifier } = verifierFor("optional", { badIdToken: true });
      await expect(verifier("id", null)).rejects.toThrow();
    });
  });

  describe("off", () => {
    it("ignores the App Check header entirely", async () => {
      const { verifier, calls } = verifierFor("off", { badAppCheck: true });
      await expect(verifier("id", "garbage")).resolves.toMatchObject({ uid: "u1" });
      await expect(verifier("id", null)).resolves.toMatchObject({ uid: "u1" });
      expect(calls.appCheckTokens).toEqual([]);
      expect(calls.idTokens).toEqual(["id", "id"]);
    });
    it("still rejects a bad ID token", async () => {
      const { verifier } = verifierFor("off", { badIdToken: true });
      await expect(verifier("id", "ac")).rejects.toThrow();
    });
  });
});

describe("loadGatewayEnv — OVID_APPCHECK_MODE", () => {
  const base: NodeJS.ProcessEnv = { OVID_AUTH_MODE: "test" };

  it("defaults to required so nothing silently weakens", () => {
    expect(loadGatewayEnv(base).appCheckMode).toBe("required");
    expect(loadGatewayEnv({ ...base, OVID_APPCHECK_MODE: "" }).appCheckMode).toBe("required");
  });

  it("parses each mode (trimmed, case-insensitive)", () => {
    for (const [raw, mode] of [
      ["required", "required"],
      ["optional", "optional"],
      ["off", "off"],
      [" OFF ", "off"],
      ["Optional", "optional"],
    ] as const) {
      expect(loadGatewayEnv({ ...base, OVID_APPCHECK_MODE: raw }).appCheckMode).toBe(mode);
    }
  });

  it("rejects anything else and names the variable", () => {
    for (const bad of ["false", "disabled", "0", "yes"]) {
      expect(() => loadGatewayEnv({ ...base, OVID_APPCHECK_MODE: bad })).toThrow(
        /OVID_APPCHECK_MODE/,
      );
    }
  });
});
