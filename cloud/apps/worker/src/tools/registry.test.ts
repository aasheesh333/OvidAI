import { describe, expect, it } from "vitest";
import { REFUSAL_MESSAGE } from "@ovid/sandbox";
import { createToolRegistry } from "./registry.js";
import { SYSTEM_PROMPT_V1, TOOL_EVENT_CONTENT_CAP, TOOL_RESULT_CAP_BYTES, MAX_TOOL_ROUNDS } from "./systemPrompt.js";

// The P3 roster seam: v1 roster is EXACTLY the six pinned names, specs() is
// sorted by name (prompt-cache-stable prefix, spec §6.1), and the system
// prompt carries the refusal notice + one line per tool.

describe("createToolRegistry", () => {
  const registry = createToolRegistry();

  it("roster is exactly the six v1 tools", () => {
    expect(registry.tools.map((t) => t.name).sort()).toEqual([
      "edit_file",
      "glob_files",
      "grep_files",
      "read_file",
      "run_shell",
      "write_file",
    ]);
  });

  it("get() resolves known tools and rejects unknown names", () => {
    for (const name of ["run_shell", "read_file", "write_file", "edit_file", "glob_files", "grep_files"]) {
      expect(registry.get(name)?.name).toBe(name);
    }
    expect(registry.get("nope")).toBeUndefined();
    expect(registry.get("")).toBeUndefined();
  });

  it("specs() is sorted by name and carries the [OI] function shape", () => {
    const specs = registry.specs();
    expect(specs.map((s) => s.function.name)).toEqual([
      "edit_file",
      "glob_files",
      "grep_files",
      "read_file",
      "run_shell",
      "write_file",
    ]);
    for (const spec of specs) {
      expect(spec.type).toBe("function");
      expect(spec.function.description.length).toBeGreaterThan(0);
      expect(spec.function.parameters).toBeTypeOf("object");
    }
  });

  it("SYSTEM_PROMPT_V1 names every tool, the /workspace jail and the refusal notice", () => {
    for (const name of registry.tools.map((t) => t.name)) {
      expect(SYSTEM_PROMPT_V1).toContain(name);
    }
    expect(SYSTEM_PROMPT_V1).toContain("/workspace");
    expect(SYSTEM_PROMPT_V1).toContain(REFUSAL_MESSAGE);
  });

  it("pinned constants", () => {
    expect(MAX_TOOL_ROUNDS).toBe(50);
    expect(TOOL_RESULT_CAP_BYTES).toBe(32_768);
    expect(TOOL_EVENT_CONTENT_CAP).toBe(8_192);
  });
});
