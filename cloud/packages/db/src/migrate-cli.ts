import { pathToFileURL } from "node:url";
import { migrate } from "./client.js";

/**
 * Thin CLI over migrate() for deploy tooling (provision.sh, one-off upgrades):
 *
 *   node dist/migrate-cli.js <DATABASE_URL>
 *
 * Exit 0 when the schema is up to date afterwards, exit 1 on ANY failure
 * (missing argument, unreachable database, failing SQL) with a one-line
 * diagnostic on stderr. Deliberately no flags, no config files: the URL is
 * the whole contract, matching how the rest of the stack is configured.
 *
 * Run from dist/ this also pins the deploy-time property that ../drizzle
 * resolves next to the PACKAGE ROOT (same relative path from src/ and dist/,
 * see client.ts) — spawn-tested in migrate-cli.test.ts.
 */
export async function run(argv: readonly string[]): Promise<number> {
  const url = argv[0]?.trim();
  if (url === undefined || url === "") {
    console.error("usage: node dist/migrate-cli.js <DATABASE_URL>");
    return 1;
  }
  try {
    // Never echo the URL — it embeds the database password.
    console.log("[migrate] applying migrations…");
    await migrate(url);
    console.log("[migrate] done — schema up to date");
    return 0;
  } catch (err) {
    console.error("[migrate] FAILED:", err instanceof Error ? err.message : err);
    return 1;
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (err: unknown) => {
      console.error("[migrate] fatal:", err);
      process.exit(1);
    },
  );
}
