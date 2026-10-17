/**
 * Tool-name parity with the Dart client (`McpConnectedTool._safe` /
 * `legacyToolName` / `canonicalId`). The published (legacy) name is what the
 * model sees and what the agent loop calls back with, so the sanitization
 * rules are pinned exactly.
 */

import { describe, expect, it } from "vitest";
import { canonicalToolId, safeServerName, toolNameFor } from "./toolNames.js";

describe("safeServerName (Dart _safe parity)", () => {
  it("lowercases and collapses non-[a-z0-9_-] runs to a single underscore", () => {
    expect(safeServerName("My Server!")).toBe("my_server");
    expect(safeServerName("a  b!!c")).toBe("a_b_c");
    expect(safeServerName("A.B/C")).toBe("a_b_c");
  });

  it("trims leading and trailing underscores", () => {
    expect(safeServerName("__Hello__")).toBe("hello");
    expect(safeServerName("!!!wow!!!")).toBe("wow");
  });

  it("keeps hyphens and underscores (they are already safe)", () => {
    expect(safeServerName("Google-Drive_2")).toBe("google-drive_2");
    expect(safeServerName("fetch")).toBe("fetch");
  });

  it("an all-unsafe name sanitizes to the empty string (Dart parity)", () => {
    expect(safeServerName("!!!")).toBe("");
  });
});

describe("toolNameFor", () => {
  it("publishes mcp__<safe server>__<tool>", () => {
    expect(toolNameFor("My Server!", "do_thing")).toBe("mcp__my_server__do_thing");
    expect(toolNameFor("Fetch", "fetch")).toBe("mcp__fetch__fetch");
  });
});

describe("canonicalToolId", () => {
  it("is mcp:<serverId>/<tool>", () => {
    expect(canonicalToolId("0192a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "search")).toBe(
      "mcp:0192a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b/search",
    );
    expect(canonicalToolId("curated:fetch", "fetch")).toBe("mcp:curated:fetch/fetch");
  });
});
