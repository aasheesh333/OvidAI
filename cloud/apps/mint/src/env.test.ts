import { describe, expect, it } from "vitest";
import { loadMintEnv } from "./env.js";

/**
 * loadMintEnv contract: defaults are the mint.py defaults (this app is the
 * Node port of server/mint/mint.py), every required var throws NAMING the
 * offending variable, and the test-upgrade escape hatch is refused outright
 * in production. Pure function — no services touched.
 */

/** Minimal valid env: every REQUIRED var present, everything else defaulted. */
function baseEnv(): NodeJS.ProcessEnv {
  return {
    NODE_ENV: "test",
    DATABASE_URL: "postgres://u:p@localhost:5432/ovid_cloud_test",
    REDIS_DB2_URL: "redis://localhost:6379/9",
    LITELLM_MASTER_KEY: "sk-litellm-master",
    OVID_ADMIN_MASTER_KEY: "sk-admin-master",
    OVID_INTERNAL_API_SECRET: "sk-internal",
    FIREBASE_PROJECT_ID: "ovid-test-project",
  };
}

describe("loadMintEnv defaults (mint.py parity)", () => {
  it("ports + host default to 8091/8092/127.0.0.1", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.publicPort).toBe(8091);
    expect(env.adminPort).toBe(8092);
    expect(env.host).toBe("127.0.0.1");
  });

  it("LiteLLM + Redis + public base URL defaults match mint.py", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.litellmBaseUrl).toBe("http://litellm:4000");
    expect(env.litellmMasterKey).toBe("sk-litellm-master");
    // The URL itself carries the db selector (prod …/2, tests …/9) — the
    // loader never parses or rewrites it.
    expect(env.redisDb2Url).toBe("redis://localhost:6379/9");
    expect(env.publicBaseUrl).toBe("https://cloud.dhanuksoftwares.com/v1");
  });

  it("abuse knobs default to mint.py's 40/3600/12/600/86400/20/3600/500/3600", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.abuse).toEqual({
      mintCallsPerIp: 40,
      mintWindowS: 3600,
      newAccountsPerIpPerWindow: 12,
      signupVelocityWindowS: 600,
      ipAccountWindowS: 86400,
      abuseStrikeLimit: 20,
      abuseWindowS: 3600,
      globalNewkeysPerWindow: 500,
      newkeyWindowS: 3600,
    });
  });

  it("state/ops knobs default to mint.py values", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.mintStateDir).toBe("/data");
    expect(env.reapplySyncMax).toBe(200);
    expect(env.auditMax).toBe(5000);
    expect(env.usageCacheS).toBe(15);
    expect(env.sweepS).toBe(30);
    expect(env.webTeamDailyUsd).toBe(25);
    expect(env.dailySpendAlertUsd).toBe(20);
    expect(env.alertTelegramBotToken).toBe("");
    expect(env.alertTelegramChatId).toBe("");
    expect(env.alertWebhookUrl).toBe("");
  });

  it("app check defaults: enabled, no apps, allowTestUpgrade false", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.appcheckEnabled).toBe(true);
    expect(env.appcheckApps).toEqual({});
    expect(env.allowTestUpgrade).toBe(false);
  });

  it("play billing defaults match server/billing/api.py", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.play).toEqual({
      serviceAccountFile: null,
      packageName: "com.dhanuk.ovidai",
      products: null,
      rtdnAudience: null,
      rtdnServiceAccount: null,
      rtdnSharedSecret: null,
      requireAccountId: true,
    });
  });

  it("images defaults match deploy/images_gateway.py", () => {
    const env = loadMintEnv(baseEnv());
    expect(env.images).toEqual({
      maxUpstreamCostUsd: null,
      inferhubApiKey: null,
      directEditHosts: "api.inferhub.dev",
      editCostUsd: null,
      probeKey: null,
      probeMaxUsd: 0.5,
      probeDailyUsd: 5,
      probeTtlS: 7 * 24 * 3600,
      probeStaggerS: 30,
      probeMaxSizes: 4,
    });
  });
});

describe("loadMintEnv parsing", () => {
  it("OVID_APPCHECK_APPS 'android:<id>,web:<id>' maps appId → platform", () => {
    const env = loadMintEnv({
      ...baseEnv(),
      OVID_APPCHECK_APPS: "android:1:234:android:abc, web:1:234:web:def",
    });
    expect(env.appcheckApps).toEqual({
      "1:234:android:abc": "android",
      "1:234:web:def": "web",
    });
  });

  it("APPCHECK_ENABLED=false disables app check", () => {
    const env = loadMintEnv({ ...baseEnv(), APPCHECK_ENABLED: "false" });
    expect(env.appcheckEnabled).toBe(false);
  });

  it("OVID_PLAY_PRODUCTS parses a JSON product→tier map", () => {
    const env = loadMintEnv({
      ...baseEnv(),
      OVID_PLAY_PRODUCTS: '{"ovid-monthly-7x":"7x"}',
    });
    expect(env.play.products).toEqual({ "ovid-monthly-7x": "7x" });
  });

  it("OVID_PLAY_PRODUCTS invalid JSON → throws naming the var", () => {
    expect(() =>
      loadMintEnv({ ...baseEnv(), OVID_PLAY_PRODUCTS: "{not json" }),
    ).toThrow(/OVID_PLAY_PRODUCTS/);
  });

  it("an explicitly-set knob overrides its default", () => {
    const env = loadMintEnv({ ...baseEnv(), WEB_TEAM_DAILY_USD: "40", USAGE_CACHE_S: "30" });
    expect(env.webTeamDailyUsd).toBe(40);
    expect(env.usageCacheS).toBe(30);
  });

  it("a malformed integer knob → throws naming the var", () => {
    expect(() => loadMintEnv({ ...baseEnv(), MINT_WINDOW_S: "soon" })).toThrow(
      /MINT_WINDOW_S/,
    );
  });
});

describe("loadMintEnv required vars", () => {
  it.each(["LITELLM_MASTER_KEY", "OVID_ADMIN_MASTER_KEY", "OVID_INTERNAL_API_SECRET"])(
    "missing %s → throws naming it",
    (name) => {
      const raw = baseEnv();
      delete raw[name];
      expect(() => loadMintEnv(raw)).toThrow(name);
    },
  );

  it("missing DATABASE_URL → throws naming it", () => {
    const raw = baseEnv();
    delete raw.DATABASE_URL;
    expect(() => loadMintEnv(raw)).toThrow(/DATABASE_URL/);
  });

  it("missing FIREBASE_PROJECT_ID → throws naming it", () => {
    const raw = baseEnv();
    delete raw.FIREBASE_PROJECT_ID;
    expect(() => loadMintEnv(raw)).toThrow(/FIREBASE_PROJECT_ID/);
  });
});

describe("MINT_PROJECTION_MODE (Task 18 activation switch)", () => {
  it("defaults to authoritative", () => {
    expect(loadMintEnv(baseEnv()).projectionMode).toBe("authoritative");
  });

  it("accepts import-first (installed-base first boot)", () => {
    expect(
      loadMintEnv({ ...baseEnv(), MINT_PROJECTION_MODE: "import-first" }).projectionMode,
    ).toBe("import-first");
  });

  it("is case/whitespace tolerant", () => {
    expect(
      loadMintEnv({ ...baseEnv(), MINT_PROJECTION_MODE: "  Import-First " }).projectionMode,
    ).toBe("import-first");
  });

  it("refuses any other value, naming the variable", () => {
    expect(() =>
      loadMintEnv({ ...baseEnv(), MINT_PROJECTION_MODE: "authorative" }),
    ).toThrow(/MINT_PROJECTION_MODE/);
  });
});

describe("ALLOW_TEST_UPGRADE gate", () => {
  it("ALLOW_TEST_UPGRADE=true + NODE_ENV=production → throws naming ALLOW_TEST_UPGRADE", () => {
    expect(() =>
      loadMintEnv({ ...baseEnv(), NODE_ENV: "production", ALLOW_TEST_UPGRADE: "true" }),
    ).toThrow(/ALLOW_TEST_UPGRADE/);
  });

  it("ALLOW_TEST_UPGRADE=true outside production is accepted", () => {
    const env = loadMintEnv({ ...baseEnv(), ALLOW_TEST_UPGRADE: "true" });
    expect(env.allowTestUpgrade).toBe(true);
  });

  it("ALLOW_TEST_UPGRADE=false in production is fine", () => {
    const env = loadMintEnv({ ...baseEnv(), NODE_ENV: "production" });
    expect(env.allowTestUpgrade).toBe(false);
  });
});
