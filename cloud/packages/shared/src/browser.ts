import { z } from "zod";

/**
 * Browser channel wire protocol (P6 Task 2): the Redis channel names, the
 * screencast frame-format constants, the state DTO, the viewer input event
 * union, the ctl pub-sub message union, and their zod schemas.
 *
 * Topology (rides redis-q per the P6-Q6 ruling — ephemeral, AG3-safe):
 * - `browser:{sessionId}:frames` — the worker publishes screencast frames here
 *   as raw image bytes prefixed with the 1-byte `BROWSER_FRAME_FORMAT` value.
 *   The gateway subscribes while any viewer is attached, STRIPS the prefix,
 *   and forwards the image bytes to each attached socket as a binary WS
 *   message (see the wire contract below).
 * - `browser:{sessionId}:state` — the worker publishes a `BrowserStateDto`
 *   (JSON) on every change (navigation, title, takeover, screencast toggles);
 *   the gateway fans it out to attached sockets as a `browser_state` op.
 * - `browser:{sessionId}:ctl` — viewer lifecycle (`BrowserCtlMsg`): the
 *   gateway publishes `viewer_join`/`viewer_leave` on attach/detach and the
 *   worker echoes them to other viewers (e.g. to grey out their input while
 *   a takeover is active); `takeover` toggles input exclusivity.
 * - `browser:{sessionId}:input` — the gateway publishes `BrowserInputEvent`s
 *   (JSON) forwarded from attached sockets' `browser_input` ops.
 *
 * WIRE CONTRACT FOR BINARY FRAMES: while a socket has an active
 * `browser_attach`, the server sends screencast frames as raw BINARY WS
 * messages — image bytes only (the redis 1-byte format prefix is stripped by
 * the gateway); the image format is `state.frameFormat` from the latest
 * `browser_state` op the client received. One browser attach per socket: a
 * second `browser_attach` replaces the first (the old one gets
 * `viewer_leave`). Client input coordinates are page CSS pixels in the
 * `state.viewport` (the client scales its canvas to match).
 *
 * Pure data + zod only (no node APIs): the browser client imports this file
 * in the web app.
 */

/**
 * The 1-byte format prefix on redis `frames`-channel publishes. The gateway
 * maps the byte back to a `BrowserFrameFormat` when relaying to sockets
 * (sockets get bare image bytes; the format travels in `browser_state`).
 */
export const BROWSER_FRAME_FORMAT = { jpeg: 1, webp: 2 } as const;

export type BrowserFrameFormat = "jpeg" | "webp";

/** Snapshot of the live browser tab, published on the state channel. */
export interface BrowserStateDto {
  sessionId: string;
  /** False while the engine is (re)starting or the tab crashed. */
  live: boolean;
  /** Current page URL, or null while no page is loaded. */
  url: string | null;
  /** Current page title, or null while no page is loaded. */
  title: string | null;
  /** True while input exclusivity is active (one viewer owns input). */
  takeover: boolean;
  /** True while the worker is streaming screencast frames. */
  screencast: boolean;
  /** Format of the binary frames currently on the wire. */
  frameFormat: BrowserFrameFormat;
  /** Page CSS-pixel viewport the client scales its canvas to. */
  viewport: { width: number; height: number };
}

/** A viewer interaction, published on the input channel in page CSS pixels. */
export type BrowserInputEvent =
  | { type: "tap"; x: number; y: number }
  | { type: "double_tap"; x: number; y: number }
  | { type: "long_press"; x: number; y: number; durationMs?: number }
  | { type: "scroll"; dx: number; dy: number; x?: number; y?: number }
  | { type: "swipe"; fromX: number; fromY: number; toX: number; toY: number; steps?: number }
  | { type: "key"; key: string; text?: string };

/** Viewer lifecycle + takeover control, published on the ctl channel. */
export type BrowserCtlMsg =
  | { type: "viewer_join"; viewerId: string }
  | { type: "viewer_leave"; viewerId: string }
  | { type: "takeover"; enabled: boolean };

// -- channel helpers ----------------------------------------------------------

export function browserFramesChannel(sessionId: string): string {
  return `browser:${sessionId}:frames`;
}

export function browserStateChannel(sessionId: string): string {
  return `browser:${sessionId}:state`;
}

export function browserCtlChannel(sessionId: string): string {
  return `browser:${sessionId}:ctl`;
}

export function browserInputChannel(sessionId: string): string {
  return `browser:${sessionId}:input`;
}

// -- validation building blocks ----------------------------------------------

const id = z.string().min(1);

/** Page CSS-pixel coordinates: any finite number (viewports pan/zoom). */
const coord = z.number();

/** Viewport dimensions: positive integers. */
const viewportDim = z
  .number()
  .int()
  .positive();

// -- schemas -------------------------------------------------------------------

export const browserStateDtoSchema: z.ZodType<BrowserStateDto> = z.object({
  sessionId: id,
  live: z.boolean(),
  url: z.string().nullable(),
  title: z.string().nullable(),
  takeover: z.boolean(),
  screencast: z.boolean(),
  frameFormat: z.enum(["jpeg", "webp"]),
  viewport: z.object({ width: viewportDim, height: viewportDim }),
});

export const browserInputEventSchema: z.ZodType<BrowserInputEvent> = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("tap"),
    x: coord,
    y: coord,
  }),
  z.object({
    type: z.literal("double_tap"),
    x: coord,
    y: coord,
  }),
  z.object({
    type: z.literal("long_press"),
    x: coord,
    y: coord,
    durationMs: z.number().int().positive().optional(),
  }),
  z.object({
    type: z.literal("scroll"),
    dx: coord,
    dy: coord,
    x: coord.optional(),
    y: coord.optional(),
  }),
  z.object({
    type: z.literal("swipe"),
    fromX: coord,
    fromY: coord,
    toX: coord,
    toY: coord,
    steps: z.number().int().positive().optional(),
  }),
  z.object({
    type: z.literal("key"),
    key: z.string().min(1),
    text: z.string().optional(),
  }),
]);

export const browserCtlMsgSchema: z.ZodType<BrowserCtlMsg> = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("viewer_join"),
    viewerId: id,
  }),
  z.object({
    type: z.literal("viewer_leave"),
    viewerId: id,
  }),
  z.object({
    type: z.literal("takeover"),
    enabled: z.boolean(),
  }),
]);
