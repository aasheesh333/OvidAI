/**
 * Browser tool seam (P6 Task 12) — the shape Task 13 extends and Task 14's
 * engine consumes.
 *
 * Artifact refs are WORKSPACE-RELATIVE paths under the P2 session workspace
 * jail root (never absolute, never outside it). The P3 loop attaches the
 * referenced files to the next model request; P7's artifact pipeline resolves
 * the same path against the workspace to upload it. This package never owns
 * the workspace root — `BrowserToolsDeps.workspaceDir` is the seam.
 *
 * Every `execute` NEVER throws: validation failures, takeover refusals and
 * runtime errors all come back as content strings, so the P3 loop stays
 * healthy even when the browser is gone.
 */

import { randomBytes } from "node:crypto";

import type { Page } from "playwright-core";
import { z } from "zod";

import type { BrowserEngineConfig } from "../config.js";
import { BrowserPoolBusyError, type BrowserPool } from "../pool.js";
import type { BrowserSessionRegistry } from "../sessions.js";
import type { StorageStatePersistence } from "../stateStore.js";

export interface BrowserToolContext {
  sessionId: string;
  userId: string;
}

export interface BrowserArtifactRef {
  kind: "screenshot" | "download";
  /** Workspace-relative (P2 jail root), e.g. "browser/screenshots/x.jpg". */
  path: string;
  mimeType: string;
  bytes: number;
}

export interface BrowserToolResult {
  content: string;
  artifacts?: BrowserArtifactRef[];
}

export interface BrowserToolDef {
  /** "browser_open", … */
  name: string;
  /** Model-facing copy (Dart descriptions ported, panel references removed). */
  description: string;
  /** JSON Schema object handed to the model (Dart-parity shapes). */
  parameters: Record<string, unknown>;
  /** Server-side validation of the model's arguments. */
  inputSchema: z.ZodTypeAny;
  /** Never throws; failures are content strings. */
  execute(input: unknown, ctx: BrowserToolContext): Promise<BrowserToolResult>;
}

export interface BrowserToolsDeps {
  pool: BrowserPool;
  registry: BrowserSessionRegistry;
  /** null ⇒ no login restore/flush (dev mode). */
  persistence: StorageStatePersistence | null;
  cfg: BrowserEngineConfig;
  /** P2 seam; impl must mkdir -p. Tests inject a tmpdir. */
  workspaceDir(userId: string, sessionId: string): Promise<string>;
  /** Engine → bridge.publishState hook (Task 14). */
  notifyState?(sessionId: string): void;
  now?(): number;
}

/** Every failure content starts with this (except takeover/URL refusals). */
export const TOOL_ERROR_PREFIX = "error: ";
/** Dart spillToolOutput parity for open/navigate. */
export const TEXT_OUTPUT_CAP = 5000;
export const READ_MARKDOWN_CAP = 8000;
/** Accessibility snapshot cap (the a11y tree the model picks targets from). */
export const SNAPSHOT_CAP = 8000;

/**
 * Internal control-flow error: a tool body (or `withSession`) can abort with a
 * fully-formed content string that the execute wrapper returns VERBATIM
 * (no `error: ` prefix) — takeover refusals are the canonical case.
 */
export class BrowserToolFailure extends Error {
  readonly content: string;

  constructor(content: string) {
    super(content);
    this.name = "BrowserToolFailure";
    this.content = content;
  }
}

export interface BrowserToolSpec {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  inputSchema: z.ZodTypeAny;
  execute(input: any, ctx: BrowserToolContext, deps: BrowserToolsDeps): Promise<BrowserToolResult>;
}

function formatIssues(error: z.ZodError): string {
  return error.issues
    .map((issue) => `${issue.path.length > 0 ? issue.path.join(".") : "(root)"}: ${issue.message}`)
    .join("; ");
}

export function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Cap `text` and append the Dart-style truncation note (chars dropped). */
export function capText(text: string, cap: number): string {
  if (text.length <= cap) return text;
  return `${text.slice(0, cap)}\n…[truncated ${text.length - cap} chars]`;
}

/**
 * `document.body.innerText` from the page. Written through `globalThis` so the
 * package's tsc run needs no DOM lib; the callback is serialized into the
 * page where the global exists.
 */
export async function pageInnerText(page: Page): Promise<string> {
  return page.evaluate(() => {
    const doc = (globalThis as { document?: { body?: { innerText?: string } } }).document;
    return doc?.body?.innerText ?? "";
  });
}

/** Monotonic-ish short suffix for generated artifact filenames. */
export function randomSuffix(): string {
  return randomBytes(3).toString("hex");
}

/**
 * Build a `BrowserToolDef` around the shared execute preamble:
 *   1. `inputSchema.safeParse` → invalid arguments content on failure,
 *   2. takeover refusal BEFORE any browser work,
 *   3. body execution wrapped so it can never throw:
 *      - `BrowserToolFailure` ⇒ its content verbatim,
 *      - `BrowserPoolBusyError` ⇒ its clean message verbatim (model backs off),
 *      - anything else ⇒ `error: {message}`.
 */
export function defineBrowserTool(deps: BrowserToolsDeps, spec: BrowserToolSpec): BrowserToolDef {
  return {
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters,
    inputSchema: spec.inputSchema,
    async execute(input: unknown, ctx: BrowserToolContext): Promise<BrowserToolResult> {
      const parsed = spec.inputSchema.safeParse(input);
      if (!parsed.success) {
        return { content: `${TOOL_ERROR_PREFIX}invalid arguments: ${formatIssues(parsed.error)}` };
      }
      const refusal = deps.registry.refuseReasonIfTakeover(ctx.sessionId);
      if (refusal !== null) return { content: refusal };
      try {
        return await spec.execute(parsed.data, ctx, deps);
      } catch (err) {
        if (err instanceof BrowserToolFailure) return { content: err.content };
        if (err instanceof BrowserPoolBusyError) return { content: err.message };
        return { content: TOOL_ERROR_PREFIX + messageOf(err) };
      }
    },
  };
}
