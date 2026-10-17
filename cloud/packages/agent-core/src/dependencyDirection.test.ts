import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const srcDir = join(dirname(fileURLToPath(import.meta.url)));

function listTsFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      out.push(...listTsFiles(full));
    } else if (entry.endsWith(".ts")) {
      out.push(full);
    }
  }
  return out;
}

/** Import specifiers: `from "x"`, `import "x"`, `import("x")`, `require("x")`, `export ... from "x"`. */
function importSpecifiers(source: string): string[] {
  const specifiers: string[] = [];
  const patterns = [
    /(?:^|[\s;}])from\s*["']([^"']+)["']/g,
    /(?:^|[\s;}])import\s*["']([^"']+)["']/g,
    /import\s*\(\s*["']([^"']+)["']\s*\)/g,
    /require\s*\(\s*["']([^"']+)["']\s*\)/g,
  ];
  for (const re of patterns) {
    for (const m of source.matchAll(re)) specifiers.push(m[1]);
  }
  return specifiers;
}

describe("dependency direction: agent-core must not depend on the apps", () => {
  it("every import under src/ points up the dependency graph, never at apps/", () => {
    const banned = ["apps/", "@ovid/gateway", "@ovid/worker"];
    const files = listTsFiles(srcDir);
    expect(files.length).toBeGreaterThan(0);
    const violations: string[] = [];
    for (const file of files) {
      const source = readFileSync(file, "utf8");
      for (const spec of importSpecifiers(source)) {
        for (const b of banned) {
          if (spec.includes(b)) {
            violations.push(
              `${relative(srcDir, file).split(sep).join("/")} imports "${spec}" (banned: ${b})`,
            );
          }
        }
      }
    }
    expect(violations).toEqual([]);
  });
});
