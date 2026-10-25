import { createHash } from "node:crypto";
import {
  createDeepForkPlanBuilder,
  DeepForkPlanError,
  type DeepForkPlan,
  type DeepForkPlanBuilderInput,
  type DeepForkPublishedRevision,
  type DeepForkRecipientQuota,
  type DeepForkSourceEvent,
  type DeepForkSourceMessage,
  type DeepForkSourceObject,
  type DeepForkSourceRun,
  type DeepForkSourceSession,
} from "./deepForkPlan.js";

/**
 * Revision-pinned canonical source paging. Implementations may use Postgres,
 * but this port is pure: each call returns at most `limit` already authorized
 * rows and a keyset cursor. It never requires a complete DeepForkSource array.
 * The async builder feeds each page directly into the incremental planner.
 */

export const DEFAULT_DEEP_FORK_SOURCE_PAGE_SIZE = 100;
export const MAX_DEEP_FORK_SOURCE_PAGE_SIZE = 500;

export type DeepForkSourceStream = "messages" | "runs" | "objects" | "events";
export type DeepForkSourceStage = DeepForkSourceStream | "complete";

export interface DeepForkCanonicalPage<T> {
  rows: readonly T[];
  /** Exclusive canonical keyset cursor; null only when this stream is complete. */
  nextCursor: string | null;
}

export interface DeepForkSourcePageRequest {
  published: DeepForkPublishedRevision;
  cursor: string | null;
  limit: number;
}

export interface DeepForkCanonicalSourceReader {
  readSession(input: { published: DeepForkPublishedRevision }): Promise<DeepForkSourceSession>;
  readMessages(input: DeepForkSourcePageRequest): Promise<DeepForkCanonicalPage<DeepForkSourceMessage>>;
  readRuns(input: DeepForkSourcePageRequest): Promise<DeepForkCanonicalPage<DeepForkSourceRun>>;
  readObjects(input: DeepForkSourcePageRequest): Promise<DeepForkCanonicalPage<DeepForkSourceObject>>;
  readEvents(input: DeepForkSourcePageRequest): Promise<DeepForkCanonicalPage<DeepForkSourceEvent>>;
}

export interface DeepForkSourceCheckpoint {
  version: 1;
  revisionFingerprint: string;
  stage: DeepForkSourceStage;
  /** Cursor for the current stage only; completed stages are never re-read. */
  cursor: string | null;
  /** Last canonical key in the current stage, for cross-page order checks. */
  afterKey: string | null;
}

interface DeepForkSourcePageMeta {
  /** True when the returned page is the terminal page of this stream. */
  streamComplete: boolean;
  /** Persist after successfully feeding this page to the plan builder. */
  checkpoint: DeepForkSourceCheckpoint;
}

export type DeepForkSourcePageResult =
  | (DeepForkSourcePageMeta & {
      stream: "messages";
      rows: readonly DeepForkSourceMessage[];
    })
  | (DeepForkSourcePageMeta & {
      stream: "runs";
      rows: readonly DeepForkSourceRun[];
    })
  | (DeepForkSourcePageMeta & {
      stream: "objects";
      rows: readonly DeepForkSourceObject[];
    })
  | (DeepForkSourcePageMeta & {
      stream: "events";
      rows: readonly DeepForkSourceEvent[];
    });

export interface ReadDeepForkSourcePageInput {
  reader: DeepForkCanonicalSourceReader;
  published: DeepForkPublishedRevision;
  checkpoint?: DeepForkSourceCheckpoint | null;
  limit?: number;
}

export interface DeepForkPlanFromPagesInput
  extends Omit<DeepForkPlanBuilderInput, "session" | "quota"> {
  reader: DeepForkCanonicalSourceReader;
  quota: DeepForkRecipientQuota;
  /** Canonical source-read bound, independent of output operation pageSize. */
  sourcePageSize?: number;
}

function fail(code: ConstructorParameters<typeof DeepForkPlanError>[0]): never {
  throw new DeepForkPlanError(code);
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareDigits(a: string, b: string): number {
  const left = a.replace(/^0+(?=\d)/, "");
  const right = b.replace(/^0+(?=\d)/, "");
  return left.length === right.length ? compareText(left, right) : left.length - right.length;
}

function compareSeq(a: string, b: string): number {
  const [ams, asub] = a.split("-") as [string, string];
  const [bms, bsub] = b.split("-") as [string, string];
  return compareDigits(ams, bms) || compareDigits(asub, bsub);
}

function canonicalTime(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) fail("invalid_published_revision");
  const ms = new Date(value).getTime();
  if (!Number.isFinite(ms)) fail("invalid_published_revision");
  return new Date(ms).toISOString();
}

function revisionFingerprint(published: DeepForkPublishedRevision): string {
  const ids = (values: readonly string[]): string[] => [...new Set(values)].sort(compareText);
  return createHash("sha256").update(JSON.stringify({
    version: 1,
    shareId: published.shareId,
    revisionId: published.revisionId,
    state: published.state,
    sessionId: published.sessionId,
    messageIds: ids(published.messageIds),
    runIds: ids(published.runIds),
    eventSeqs: ids(published.eventSeqs),
    artifactIds: ids(published.artifactIds),
    attachmentIds: ids(published.attachmentIds),
  }), "utf8").digest("hex");
}

export function initialDeepForkSourceCheckpoint(
  published: DeepForkPublishedRevision,
): DeepForkSourceCheckpoint {
  return {
    version: 1,
    revisionFingerprint: revisionFingerprint(published),
    stage: "messages",
    cursor: null,
    afterKey: null,
  };
}

function checkedLimit(value: number | undefined): number {
  const limit = value ?? DEFAULT_DEEP_FORK_SOURCE_PAGE_SIZE;
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_DEEP_FORK_SOURCE_PAGE_SIZE) {
    fail("invalid_input");
  }
  return limit;
}

function checkedCheckpoint(
  published: DeepForkPublishedRevision,
  checkpoint: DeepForkSourceCheckpoint,
): DeepForkSourceCheckpoint {
  if (checkpoint.revisionFingerprint !== revisionFingerprint(published)) {
    fail("checkpoint_mismatch");
  }
  if (
    checkpoint.version !== 1 ||
    !["messages", "runs", "objects", "events", "complete"].includes(checkpoint.stage) ||
    (checkpoint.cursor !== null && (typeof checkpoint.cursor !== "string" || checkpoint.cursor === "")) ||
    (checkpoint.afterKey !== null &&
      (typeof checkpoint.afterKey !== "string" || checkpoint.afterKey === ""))
  ) {
    fail("invalid_checkpoint");
  }
  return checkpoint;
}

function nextStage(stage: DeepForkSourceStream): DeepForkSourceStage {
  if (stage === "messages") return "runs";
  if (stage === "runs") return "objects";
  if (stage === "objects") return "events";
  return "complete";
}

type AnySourceRow =
  | DeepForkSourceMessage
  | DeepForkSourceRun
  | DeepForkSourceObject
  | DeepForkSourceEvent;

function rowKey(stage: DeepForkSourceStream, row: AnySourceRow): string {
  if (stage === "messages") return (row as DeepForkSourceMessage).id;
  if (stage === "runs") {
    const run = row as DeepForkSourceRun;
    return `${canonicalTime(run.createdAt)}\0${run.id}`;
  }
  if (stage === "objects") {
    const object = row as DeepForkSourceObject;
    const value = object.kind === "artifact" ? object.artifact : object.attachment;
    return `${canonicalTime(value.createdAt)}\0${object.kind}:${value.id}`;
  }
  return (row as DeepForkSourceEvent).seq;
}

function compareKeys(stage: DeepForkSourceStream, a: string, b: string): number {
  return stage === "events" ? compareSeq(a, b) : compareText(a, b);
}

function assertExposed(
  stage: DeepForkSourceStream,
  row: AnySourceRow,
  published: DeepForkPublishedRevision,
): void {
  let exposed = false;
  if (stage === "messages") exposed = published.messageIds.includes((row as DeepForkSourceMessage).id);
  else if (stage === "runs") exposed = published.runIds.includes((row as DeepForkSourceRun).id);
  else if (stage === "events") exposed = published.eventSeqs.includes((row as DeepForkSourceEvent).seq);
  else {
    const object = row as DeepForkSourceObject;
    exposed = object.kind === "artifact"
      ? published.artifactIds.includes(object.artifact.id)
      : published.attachmentIds.includes(object.attachment.id);
  }
  if (!exposed) fail("invalid_published_revision");
}

export async function readDeepForkSourcePage(
  input: ReadDeepForkSourcePageInput,
): Promise<DeepForkSourcePageResult | null> {
  if (input.published.state !== "published") fail("share_unavailable");
  const checkpoint = checkedCheckpoint(
    input.published,
    input.checkpoint ?? initialDeepForkSourceCheckpoint(input.published),
  );
  if (checkpoint.stage === "complete") return null;
  const stage = checkpoint.stage;
  const limit = checkedLimit(input.limit);
  const request = { published: input.published, cursor: checkpoint.cursor, limit };
  let page: DeepForkCanonicalPage<AnySourceRow>;
  if (stage === "messages") page = await input.reader.readMessages(request);
  else if (stage === "runs") page = await input.reader.readRuns(request);
  else if (stage === "objects") page = await input.reader.readObjects(request);
  else page = await input.reader.readEvents(request);

  if (!Array.isArray(page.rows) || page.rows.length > limit) fail("invalid_published_revision");
  if (
    (page.nextCursor !== null &&
      (typeof page.nextCursor !== "string" || page.nextCursor === "")) ||
    (page.nextCursor !== null && page.nextCursor === checkpoint.cursor) ||
    (page.rows.length === 0 && page.nextCursor !== null)
  ) {
    fail("invalid_published_revision");
  }

  let afterKey = checkpoint.afterKey;
  for (const row of page.rows) {
    assertExposed(stage, row, input.published);
    const key = rowKey(stage, row);
    if (typeof key !== "string" || key === "") fail("invalid_published_revision");
    if (afterKey !== null && compareKeys(stage, afterKey, key) >= 0) {
      // Includes duplicates and a cursor that failed to advance canonical order.
      fail("invalid_published_revision");
    }
    afterKey = key;
  }

  const streamComplete = page.nextCursor === null;
  const nextCheckpoint: DeepForkSourceCheckpoint = streamComplete
    ? {
        version: 1,
        revisionFingerprint: checkpoint.revisionFingerprint,
        stage: nextStage(stage),
        cursor: null,
        afterKey: null,
      }
    : {
        version: 1,
        revisionFingerprint: checkpoint.revisionFingerprint,
        stage,
        cursor: page.nextCursor,
        afterKey,
      };
  return {
    stream: stage,
    rows: page.rows,
    streamComplete,
    checkpoint: nextCheckpoint,
  } as DeepForkSourcePageResult;
}

export async function createDeepForkPlanFromPages(
  input: DeepForkPlanFromPagesInput,
): Promise<DeepForkPlan> {
  if (input.published.state !== "published") fail("share_unavailable");
  const sourcePageSize = checkedLimit(input.sourcePageSize);
  const session = await input.reader.readSession({ published: input.published });
  const builder = createDeepForkPlanBuilder({
    jobId: input.jobId,
    recipientUserId: input.recipientUserId,
    published: input.published,
    session,
    quota: input.quota,
    ...(input.pageSize === undefined ? {} : { pageSize: input.pageSize }),
  });
  let checkpoint: DeepForkSourceCheckpoint | null = null;
  for (;;) {
    const page = await readDeepForkSourcePage({
      reader: input.reader,
      published: input.published,
      checkpoint,
      limit: sourcePageSize,
    });
    if (page === null) return builder.finish();
    if (page.stream === "messages") builder.appendMessages(page.rows, page.streamComplete);
    else if (page.stream === "runs") builder.appendRuns(page.rows, page.streamComplete);
    else if (page.stream === "objects") builder.appendObjects(page.rows, page.streamComplete);
    else builder.appendEvents(page.rows, page.streamComplete);
    // The checkpoint advances only after the incremental builder accepted the
    // whole page. A rejected page cannot be mistaken for consumed source work.
    checkpoint = page.checkpoint;
  }
}
