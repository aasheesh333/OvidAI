import { defineConfig } from "vitest/config";

// The migration-script suites share the disposable Postgres/Redis with the
// mint suites (TEST_DATABASE_URL / TEST_MINT_REDIS_URL). Serialize files so
// their reset/flush blocks cannot race each other.
export default defineConfig({
  // Vite 5's builtin list predates `node:sqlite` (Node 22.5+); keep it
  // external so the import reaches Node instead of being bundled.
  ssr: { external: ["node:sqlite"] },
  test: {
    fileParallelism: false,
    server: { deps: { external: ["node:sqlite"] } },
  },
});
