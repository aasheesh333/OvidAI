import { describe, expect, it } from "vitest";
import { createDb, dbPoolOptionsFromEnv } from "./client.js";

describe("dbPoolOptionsFromEnv", () => {
  it("falls back to the per-process defaults", () => {
    expect(dbPoolOptionsFromEnv({}, { max: 20 })).toEqual({ max: 20 });
    expect(dbPoolOptionsFromEnv({})).toEqual({});
  });

  it("env overrides the defaults", () => {
    expect(
      dbPoolOptionsFromEnv({ OVID_DB_POOL_MAX: "40", OVID_DB_IDLE_TIMEOUT_S: "60" }, { max: 20 }),
    ).toEqual({ max: 40, idleTimeoutSec: 60 });
  });

  it("rejects invalid values loudly", () => {
    expect(() => dbPoolOptionsFromEnv({ OVID_DB_POOL_MAX: "0" })).toThrow(/OVID_DB_POOL_MAX/);
    expect(() => dbPoolOptionsFromEnv({ OVID_DB_POOL_MAX: "x" })).toThrow(/OVID_DB_POOL_MAX/);
    expect(() => dbPoolOptionsFromEnv({ OVID_DB_IDLE_TIMEOUT_S: "-5" })).toThrow(
      /OVID_DB_IDLE_TIMEOUT_S/,
    );
  });
});

describe("createDb pool wiring", () => {
  it("passes max/idle_timeout to postgres.js (no connection is opened)", async () => {
    const db = createDb("postgres://u:p@127.0.0.1:1/none", { max: 33, idleTimeoutSec: 7 });
    const options = (db.$client as unknown as { options: { max: number; idle_timeout: number } })
      .options;
    expect(options.max).toBe(33);
    expect(options.idle_timeout).toBe(7);
    await db.$client.end({ timeout: 0 });
  });

  it("keeps the postgres.js default (10) when unset", async () => {
    const db = createDb("postgres://u:p@127.0.0.1:1/none");
    expect((db.$client as unknown as { options: { max: number } }).options.max).toBe(10);
    await db.$client.end({ timeout: 0 });
  });
});
