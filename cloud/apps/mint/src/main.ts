import { pathToFileURL } from "node:url";
import { main } from "./index.js";

/**
 * Process entry point (`pnpm start` → `node dist/main.js`) — mirrors the
 * gateway's main.ts pattern: index.ts stays a pure library (composition root
 * exported, never invoked at import), and this file is the ONLY place the
 * server is started. Kept untested-thin on purpose.
 */
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error("[mint] fatal startup error", err);
    process.exit(1);
  });
}
