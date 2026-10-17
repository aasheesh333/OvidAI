/**
 * Worker-thread entry for parallel extractAll (Task 5).
 *
 * Loaded directly by node:worker_threads (from dist/ in production, or from
 * a transpiled bundle in tests — Node's type stripping cannot remap the
 * package's ".js" specifiers to ".ts", so this file must only ever be loaded
 * in compiled form). Imports stay runtime-minimal: openReader (its own
 * reader for its frame range) and extractFrameRange.
 *
 * Protocol: workerData = { spec, destDir, restoreMeta, frames, recs,
 * baseFrameIndex }; posts { files, bytes } on success or
 * { error: { code, message } } on failure (typed errors cannot cross the
 * structured-clone boundary — the parent rebuilds them by code).
 */

import { isMainThread, parentPort, workerData } from "node:worker_threads";

import { openReader } from "../rangeReader.js";
import { extractFrameRange } from "./extract.js";
import type { FileRec, FrameRec } from "./pack.js";
import type { ReaderSpec } from "../rangeReader.js";

interface WorkerData {
  spec: ReaderSpec;
  destDir: string;
  restoreMeta: boolean;
  frames: FrameRec[];
  recs: FileRec[];
  baseFrameIndex: number;
}

export async function runWorker(): Promise<void> {
  const port = parentPort;
  if (port === null) throw new Error("extractWorker: no parent port");
  const wd = workerData as WorkerData;
  try {
    const r = await openReader(wd.spec);
    let out: { files: number; bytes: number };
    try {
      out = await extractFrameRange(
        r,
        wd.frames,
        wd.recs,
        wd.destDir,
        wd.restoreMeta,
        wd.baseFrameIndex,
      );
    } finally {
      await r.close();
    }
    port.postMessage(out);
  } catch (err) {
    const e = err as { code?: string; message?: string };
    port.postMessage({
      error: {
        code: typeof e.code === "string" ? e.code : "storage",
        message: err instanceof Error ? err.message : String(err),
      },
    });
  }
}

if (!isMainThread) {
  void runWorker();
}
