import { ImageError } from "./types.js";

/**
 * Port of service.py validate_image(): PNG / JPEG / WebP, one frame, at most
 * 4096x4096 (16 Mpx), at most 16 MB, and the declared MIME must match.
 *
 * PINNED DEVIATION: Python uses PIL `im.verify()` + `im.load()`, which fully
 * decodes the image. The plan pins header sniffing plus a complete-file marker
 * check instead (PNG IEND, JPEG EOI, WebP RIFF length + no ANIM), so a
 * truncated image is still rejected without pulling a native decoder into the
 * request path.
 */

export const MAX_BYTES = 16 * 1024 * 1024;
export const MAX_PIXELS = 4096 * 4096;
export const MAX_DIMENSION = 4096;

/** Python `(MAX_BYTES + 2) // 3 * 4` — the encoded-length ceiling. */
const MAX_ENCODED = Math.floor((MAX_BYTES + 2) / 3) * 4;

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

function fail(): never {
  throw new ImageError(400, "invalid_image");
}

function checkDimensions(width: number, height: number): void {
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width <= 0 ||
    height <= 0 ||
    width > MAX_DIMENSION ||
    height > MAX_DIMENSION ||
    width * height > MAX_PIXELS
  ) {
    fail();
  }
}

/** PNG: signature, IHDR dimensions, and a terminating IEND chunk. */
function pngMime(raw: Buffer): string {
  if (raw.length < 8 + 25 + 12 || !raw.subarray(0, 8).equals(PNG_SIGNATURE)) fail();
  if (raw.readUInt32BE(8) !== 13) fail();
  if (raw.toString("ascii", 12, 16) !== "IHDR") fail();
  checkDimensions(raw.readUInt32BE(16), raw.readUInt32BE(20));
  if (raw.readUInt32BE(raw.length - 12) !== 0) fail();
  if (raw.toString("ascii", raw.length - 8, raw.length - 4) !== "IEND") fail();
  return "image/png";
}

/** JPEG: SOI/EOI plus a frame header carrying the dimensions. */
function jpegMime(raw: Buffer): string {
  if (raw.length < 4 || raw[0] !== 0xff || raw[1] !== 0xd8) fail();
  if (raw[raw.length - 2] !== 0xff || raw[raw.length - 1] !== 0xd9) fail();

  let dimensions: { width: number; height: number } | null = null;
  let i = 2;
  while (i < raw.length) {
    if (raw[i] !== 0xff) fail();
    while (i < raw.length && raw[i] === 0xff) i += 1;
    if (i >= raw.length) fail();
    const marker = raw[i]!;
    i += 1;
    if (marker === 0xd9 || marker === 0xda) break; // EOI / start of scan
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (i + 2 > raw.length) fail();
    const length = raw.readUInt16BE(i);
    if (length < 2 || i + length > raw.length) fail();
    if (SOF_MARKERS.has(marker)) {
      if (length < 7) fail();
      dimensions = {
        height: raw.readUInt16BE(i + 3),
        width: raw.readUInt16BE(i + 5),
      };
    }
    i += length;
  }
  if (dimensions === null) fail();
  checkDimensions(dimensions.width, dimensions.height);
  return "image/jpeg";
}

/** WebP: RIFF length must cover the file exactly; ANIM/ANMF is multi-frame. */
function webpMime(raw: Buffer): string {
  if (raw.length < 12 || raw.toString("ascii", 0, 4) !== "RIFF") fail();
  if (raw.toString("ascii", 8, 12) !== "WEBP") fail();
  if (raw.readUInt32LE(4) + 8 !== raw.length) fail();

  let dimensions: { width: number; height: number } | null = null;
  let animated = false;
  let i = 12;
  while (i + 8 <= raw.length) {
    const fourcc = raw.toString("ascii", i, i + 4);
    const size = raw.readUInt32LE(i + 4);
    const data = i + 8;
    if (data + size > raw.length) fail();
    if (fourcc === "ANIM" || fourcc === "ANMF") animated = true;
    if (fourcc === "VP8X") {
      if (size < 10) fail();
      if ((raw[data]! & 0x02) !== 0) animated = true;
      dimensions = {
        width: raw.readUIntLE(data + 4, 3) + 1,
        height: raw.readUIntLE(data + 7, 3) + 1,
      };
    } else if (fourcc === "VP8L") {
      if (size < 5 || raw[data] !== 0x2f) fail();
      const bits = raw.readUInt32LE(data + 1);
      dimensions = {
        width: (bits & 0x3fff) + 1,
        height: ((bits >>> 14) & 0x3fff) + 1,
      };
    } else if (fourcc === "VP8 ") {
      if (size < 10) fail();
      if (raw[data + 3] !== 0x9d || raw[data + 4] !== 0x01 || raw[data + 5] !== 0x2a) fail();
      dimensions = {
        width: raw.readUInt16LE(data + 6) & 0x3fff,
        height: raw.readUInt16LE(data + 8) & 0x3fff,
      };
    }
    i = data + size + (size & 1);
  }
  if (animated) fail();
  if (dimensions === null) fail();
  checkDimensions(dimensions.width, dimensions.height);
  return "image/webp";
}

function sniff(raw: Buffer): string {
  if (raw.length >= 8 && raw.subarray(0, 8).equals(PNG_SIGNATURE)) return pngMime(raw);
  if (raw.length >= 2 && raw[0] === 0xff && raw[1] === 0xd8) return jpegMime(raw);
  if (raw.length >= 12 && raw.toString("ascii", 0, 4) === "RIFF" && raw.toString("ascii", 8, 12) === "WEBP") {
    return webpMime(raw);
  }
  fail();
}

/**
 * service.py validate_image(): returns the detected MIME. Throws
 * ImageError(400, "invalid_image") for anything Python's PIL gate rejects.
 */
export function validateImage(encoded: unknown, mime?: string | null): string {
  if (typeof encoded !== "string" || encoded.length === 0 || encoded.length > MAX_ENCODED) fail();
  // Python b64decode(validate=True): strict alphabet + correct padding.
  if (
    encoded.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)
  ) {
    fail();
  }
  const raw = Buffer.from(encoded, "base64");
  if (raw.length === 0 || raw.length > MAX_BYTES) fail();
  const actual = sniff(raw);
  if (mime !== undefined && mime !== null && actual !== mime) fail();
  return actual;
}
