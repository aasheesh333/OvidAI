import { pathToFileURL } from "node:url";
import { main } from "./index.js";

/**
 * Process entry point (`pnpm start` → `node dist/main.js`) — mirrors the
 * worker's main.ts pattern: index.ts stays a pure library (composition root
 * exported, never invoked at import), and this file is the ONLY place the
 * server is started. Kept untested-thin on purpose: the guard + fatal-error
 * exit are the whole logic, and Task 10's e2e exercises main() itself.
 */
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error("[gateway] fatal startup error", err);
    process.exit(1);
  });
}
