// Two-pass archive validation (Dart parity).
//
// PASS 1 walks every entry WITHOUT touching the filesystem and rejects:
//   - absolute paths (POSIX, Windows drive-qualified, UNC)
//   - any ".." segment that climbs above the extraction root
//   - symlink/hardlink entries whose target is absolute or escapes staging
//   - every non-regular, non-directory entry (devices, fifos, sockets, ...)
//   - archives whose declared decoded size exceeds MAX_PAYLOAD_BYTES
//
// PASS 2 writes regular files and directories only. Symlinks are SKIPPED,
// never created. Every destination is re-resolved against the staging root
// (defence in depth on top of path normalisation).
//
// ZIP support is deliberately dependency-free: central-directory parse plus
// node:zlib inflateRaw. Zip64 and multi-disk archives are rejected rather
// than half-supported. TAR is a hand-rolled ustar reader (no dependency).

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve as resolvePath, sep } from "node:path";
import { inflateRawSync } from "node:zlib";
import { MAX_METADATA_BYTES, MAX_PAYLOAD_BYTES } from "./constants.js";
import { ArchiveUnsafeError } from "./errors.js";

export { ArchiveUnsafeError } from "./errors.js";

export interface ArchiveValidationInput {
  bytes: Uint8Array;
  format: "zip" | "tar";
}

export interface ArchiveValidationResult {
  /** Number of regular files written (directories and skipped links excluded). */
  fileCount: number;
}

type EntryKind = "file" | "dir" | "symlink" | "hardlink";

interface ArchiveEntry {
  normalized: string;
  kind: EntryKind;
  /** Decoded size for files. */
  size: number;
  dataOffset: number;
  /** Present for ZIP entries only. */
  zip?: {
    method: number;
    compressedSize: number;
    uncompressedSize: number;
  };
}

// ---------------------------------------------------------------------------
// Path safety
// ---------------------------------------------------------------------------

/**
 * Normalise an archive member name to a relative, slash-separated path.
 * Throws ArchiveUnsafeError for NULs, absolute paths, drive-qualified paths
 * and any ".." that would climb above the archive root. Backslashes are
 * treated as separators (Windows-built archives) so `..\evil` cannot slip
 * through on a POSIX host.
 *
 * Exported for the source resolver's GitHub tree walk (same rules, no
 * extraction). An empty result means "the archive root" (e.g. `./`).
 */
export function normalizeArchivePath(raw: string): string {
  if (raw.includes("\0")) {
    throw new ArchiveUnsafeError("archive entry name contains a NUL byte");
  }
  if (raw === "") {
    throw new ArchiveUnsafeError("archive entry has an empty name");
  }
  const unified = raw.replace(/\\/g, "/");
  if (unified.startsWith("/")) {
    throw new ArchiveUnsafeError(`archive entry uses an absolute path: ${raw}`);
  }
  if (/^[A-Za-z]:/.test(unified)) {
    throw new ArchiveUnsafeError(`archive entry uses a drive-qualified path: ${raw}`);
  }
  const out: string[] = [];
  for (const segment of unified.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (out.length === 0) {
        throw new ArchiveUnsafeError(`archive entry escapes the staging root: ${raw}`);
      }
      out.pop();
      continue;
    }
    out.push(segment);
  }
  return out.join("/");
}

/**
 * Validate a link target. Symlink targets resolve relative to the entry's
 * directory; hardlink targets resolve from the archive root (tar semantics).
 * Absolute targets and targets escaping the root are rejected.
 */
export function assertSafeLinkTarget(
  entryPath: string,
  target: string,
  kind: "symlink" | "hardlink",
): void {
  if (target === "") {
    throw new ArchiveUnsafeError("archive link entry has an empty target");
  }
  if (target.includes("\0")) {
    throw new ArchiveUnsafeError("archive link target contains a NUL byte");
  }
  const unified = target.replace(/\\/g, "/");
  if (unified.startsWith("/") || /^[A-Za-z]:/.test(unified)) {
    throw new ArchiveUnsafeError(`archive link target is absolute: ${target}`);
  }
  const base =
    kind === "symlink" ? entryPath.split("/").slice(0, -1).join("/") : "";
  const combined = base === "" ? unified : `${base}/${unified}`;
  normalizeArchivePath(combined);
}

function safeDestPath(destDir: string, normalized: string): string {
  const root = resolvePath(destDir);
  const absolute = resolvePath(root, normalized);
  if (absolute !== root && !absolute.startsWith(root + sep)) {
    throw new ArchiveUnsafeError(`archive entry escapes the staging root: ${normalized}`);
  }
  return absolute;
}

function round512(size: number): number {
  return Math.ceil(size / 512) * 512;
}

function readCString(buf: Buffer, start: number, length: number): string {
  const slice = buf.subarray(start, start + length);
  const nul = slice.indexOf(0);
  return slice.subarray(0, nul === -1 ? slice.length : nul).toString("utf8");
}

// ---------------------------------------------------------------------------
// TAR (ustar)
// ---------------------------------------------------------------------------

function parseTarNumber(field: Buffer): number {
  if (field.length === 0) return 0;
  if ((field[0]! & 0x80) !== 0) {
    // GNU base-256 encoding: high bit marks binary, remaining bits are value.
    let value = field[0]! & 0x7f;
    for (let i = 1; i < field.length; i++) value = value * 256 + field[i]!;
    if (!Number.isSafeInteger(value)) {
      throw new ArchiveUnsafeError("tar header number is out of range");
    }
    return value;
  }
  let text = field.toString("ascii");
  const nul = text.indexOf("\0");
  if (nul !== -1) text = text.slice(0, nul);
  text = text.trim();
  if (text === "") return 0;
  if (!/^[0-7]+$/.test(text)) {
    throw new ArchiveUnsafeError("tar header contains an invalid number");
  }
  const value = Number.parseInt(text, 8);
  if (!Number.isSafeInteger(value)) {
    throw new ArchiveUnsafeError("tar header number is out of range");
  }
  return value;
}

function isZeroBlock(block: Buffer): boolean {
  for (let i = 0; i < block.length; i++) {
    if (block[i] !== 0) return false;
  }
  return true;
}

function verifyTarChecksum(header: Buffer): void {
  const expected = parseTarNumber(header.subarray(148, 156));
  let unsigned = 0;
  let signed = 0;
  for (let i = 0; i < 512; i++) {
    const byte = i >= 148 && i < 156 ? 0x20 : header[i]!;
    unsigned += byte;
    signed += byte < 128 ? byte : byte - 256;
  }
  if (expected !== unsigned && expected !== signed) {
    throw new ArchiveUnsafeError("tar header checksum mismatch");
  }
}

function parseTar(bytes: Buffer): ArchiveEntry[] {
  const entries: ArchiveEntry[] = [];
  let offset = 0;
  let declaredTotal = 0;

  while (offset + 512 <= bytes.length) {
    const header = bytes.subarray(offset, offset + 512);
    if (isZeroBlock(header)) break;
    verifyTarChecksum(header);

    const name = readCString(header, 0, 100);
    const prefix = readCString(header, 345, 155);
    const fullName = prefix === "" ? name : `${prefix}/${name}`;
    const size = parseTarNumber(header.subarray(124, 136));
    const typeByte = header[156]!;
    const type = typeByte === 0 ? "0" : String.fromCharCode(typeByte);
    const dataOffset = offset + 512;

    // pax extended headers are metadata; skip their payload and continue.
    if (type === "x" || type === "g") {
      if (size > MAX_METADATA_BYTES) {
        throw new ArchiveUnsafeError("tar metadata entry exceeds the metadata cap");
      }
      if (dataOffset + size > bytes.length) {
        throw new ArchiveUnsafeError("truncated tar archive");
      }
      offset = dataOffset + round512(size);
      continue;
    }

    const normalized = normalizeArchivePath(fullName);

    if (type === "0" || type === "7") {
      if (normalized === "") {
        throw new ArchiveUnsafeError("archive file entry resolves to the root");
      }
      declaredTotal += size;
      if (declaredTotal > MAX_PAYLOAD_BYTES) {
        throw new ArchiveUnsafeError(
          `archive declared payload exceeds ${MAX_PAYLOAD_BYTES} bytes`,
        );
      }
      entries.push({ normalized, kind: "file", size, dataOffset });
    } else if (type === "5") {
      entries.push({ normalized, kind: "dir", size: 0, dataOffset });
    } else if (type === "2" || type === "1") {
      if (normalized === "") {
        throw new ArchiveUnsafeError("archive link entry resolves to the root");
      }
      const linkname = readCString(header, 157, 100);
      assertSafeLinkTarget(
        normalized,
        linkname,
        type === "2" ? "symlink" : "hardlink",
      );
      entries.push({
        normalized,
        kind: type === "2" ? "symlink" : "hardlink",
        size: 0,
        dataOffset,
      });
    } else {
      // '3' char device, '4' block device, '6' fifo, and every other
      // special type are refused outright.
      throw new ArchiveUnsafeError(`unsupported tar entry type "${type}"`);
    }

    if (dataOffset + size > bytes.length) {
      throw new ArchiveUnsafeError("truncated tar archive");
    }
    offset = dataOffset + round512(size);
  }

  if (offset < bytes.length) {
    const rest = bytes.subarray(offset);
    for (const byte of rest) {
      if (byte !== 0) throw new ArchiveUnsafeError("truncated tar archive");
    }
  }

  return entries;
}

// ---------------------------------------------------------------------------
// ZIP (central directory + inflateRaw)
// ---------------------------------------------------------------------------

const ZIP_EOCD = 0x06054b50;
const ZIP_CENTRAL = 0x02014b50;
const ZIP_LOCAL = 0x04034b50;

function findZipEocd(bytes: Buffer): number {
  if (bytes.length < 22) throw new ArchiveUnsafeError("not a zip archive");
  const min = Math.max(0, bytes.length - 22 - 0xffff);
  for (let i = bytes.length - 22; i >= min; i--) {
    if (bytes.readUInt32LE(i) !== ZIP_EOCD) continue;
    const commentLength = bytes.readUInt16LE(i + 20);
    if (i + 22 + commentLength === bytes.length) return i;
  }
  throw new ArchiveUnsafeError("not a zip archive");
}

function parseZip(bytes: Buffer): ArchiveEntry[] {
  const eocd = findZipEocd(bytes);
  const diskNumber = bytes.readUInt16LE(eocd + 4);
  const centralDisk = bytes.readUInt16LE(eocd + 6);
  const entriesOnDisk = bytes.readUInt16LE(eocd + 8);
  const totalEntries = bytes.readUInt16LE(eocd + 10);
  const centralSize = bytes.readUInt32LE(eocd + 12);
  const centralOffset = bytes.readUInt32LE(eocd + 16);

  if (diskNumber !== 0 || centralDisk !== 0 || entriesOnDisk !== totalEntries) {
    throw new ArchiveUnsafeError("multi-disk zip archives are not supported");
  }
  if (
    totalEntries === 0xffff ||
    centralOffset === 0xffffffff ||
    centralSize === 0xffffffff
  ) {
    throw new ArchiveUnsafeError("zip64 archives are not supported");
  }
  if (centralOffset + centralSize > bytes.length) {
    throw new ArchiveUnsafeError("truncated zip central directory");
  }

  const entries: ArchiveEntry[] = [];
  const centralEnd = centralOffset + centralSize;
  let pointer = centralOffset;
  let declaredTotal = 0;

  for (let index = 0; index < totalEntries; index++) {
    if (pointer + 46 > centralEnd) {
      throw new ArchiveUnsafeError("truncated zip central directory");
    }
    if (bytes.readUInt32LE(pointer) !== ZIP_CENTRAL) {
      throw new ArchiveUnsafeError("invalid zip central directory entry");
    }

    const madeBy = bytes.readUInt16LE(pointer + 4);
    const flags = bytes.readUInt16LE(pointer + 8);
    const method = bytes.readUInt16LE(pointer + 10);
    const compressedSize = bytes.readUInt32LE(pointer + 20);
    const uncompressedSize = bytes.readUInt32LE(pointer + 24);
    const nameLength = bytes.readUInt16LE(pointer + 28);
    const extraLength = bytes.readUInt16LE(pointer + 30);
    const commentLength = bytes.readUInt16LE(pointer + 32);
    const externalAttrs = bytes.readUInt32LE(pointer + 38);
    const localOffset = bytes.readUInt32LE(pointer + 42);

    if (pointer + 46 + nameLength > centralEnd) {
      throw new ArchiveUnsafeError("truncated zip central directory entry");
    }
    const rawName = bytes
      .subarray(pointer + 46, pointer + 46 + nameLength)
      .toString("utf8");
    pointer += 46 + nameLength + extraLength + commentLength;
    if (pointer > centralEnd) {
      throw new ArchiveUnsafeError("truncated zip central directory entry");
    }

    if ((flags & 0x1) !== 0) {
      throw new ArchiveUnsafeError("encrypted zip entries are not supported");
    }
    if (
      compressedSize === 0xffffffff ||
      uncompressedSize === 0xffffffff ||
      localOffset === 0xffffffff
    ) {
      throw new ArchiveUnsafeError("zip64 archives are not supported");
    }
    if (method !== 0 && method !== 8) {
      throw new ArchiveUnsafeError(`unsupported zip compression method ${method}`);
    }
    if (method === 0 && compressedSize !== uncompressedSize) {
      throw new ArchiveUnsafeError("stored zip entry has inconsistent sizes");
    }

    if (localOffset + 30 > bytes.length) {
      throw new ArchiveUnsafeError("truncated zip local header");
    }
    if (bytes.readUInt32LE(localOffset) !== ZIP_LOCAL) {
      throw new ArchiveUnsafeError("invalid zip local header");
    }
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    const dataOffset = localOffset + 30 + localNameLength + localExtraLength;
    if (dataOffset + compressedSize > bytes.length) {
      throw new ArchiveUnsafeError("truncated zip entry data");
    }

    const normalized = normalizeArchivePath(rawName);
    const madeByOs = madeBy >> 8;
    const mode = (externalAttrs >>> 16) & 0xffff;
    const fileType = mode & 0o170000;
    const isUnix = madeByOs === 3 || madeByOs === 19;

    let kind: EntryKind;
    if (rawName.endsWith("/") || (isUnix && fileType === 0o040000)) {
      kind = "dir";
    } else if (isUnix && fileType === 0o120000) {
      kind = "symlink";
    } else if (!isUnix || fileType === 0 || fileType === 0o100000) {
      kind = "file";
    } else {
      // fifo 0o010000, char device 0o020000, block device 0o060000,
      // socket 0o140000 — none may be materialised.
      throw new ArchiveUnsafeError(
        `unsupported zip entry type (mode ${fileType.toString(8)})`,
      );
    }

    if (kind === "file") {
      if (normalized === "") {
        throw new ArchiveUnsafeError("archive file entry resolves to the root");
      }
      declaredTotal += uncompressedSize;
      if (declaredTotal > MAX_PAYLOAD_BYTES) {
        throw new ArchiveUnsafeError(
          `archive declared payload exceeds ${MAX_PAYLOAD_BYTES} bytes`,
        );
      }
    }

    const entry: ArchiveEntry = {
      normalized,
      kind,
      size: kind === "file" ? uncompressedSize : 0,
      dataOffset,
      zip: { method, compressedSize, uncompressedSize },
    };

    if (kind === "symlink") {
      if (normalized === "") {
        throw new ArchiveUnsafeError("archive link entry resolves to the root");
      }
      if (uncompressedSize > 4096) {
        throw new ArchiveUnsafeError("zip symlink target is unreasonably large");
      }
      const target = readZipData(bytes, entry).toString("utf8");
      assertSafeLinkTarget(normalized, target, "symlink");
    }

    entries.push(entry);
  }

  return entries;
}

function readZipData(bytes: Buffer, entry: ArchiveEntry): Buffer {
  const meta = entry.zip;
  if (!meta) {
    return bytes.subarray(entry.dataOffset, entry.dataOffset + entry.size);
  }
  const raw = bytes.subarray(
    entry.dataOffset,
    entry.dataOffset + meta.compressedSize,
  );
  if (meta.method === 0) {
    if (raw.length !== meta.uncompressedSize) {
      throw new ArchiveUnsafeError("stored zip entry size mismatch");
    }
    return raw;
  }
  let inflated: Buffer;
  try {
    inflated = inflateRawSync(raw, { maxOutputLength: meta.uncompressedSize + 1 });
  } catch {
    throw new ArchiveUnsafeError("invalid deflate stream in zip entry");
  }
  if (inflated.length !== meta.uncompressedSize) {
    throw new ArchiveUnsafeError("zip entry decoded size does not match its header");
  }
  return inflated;
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/**
 * Validate the whole archive first, then extract regular files and
 * directories. Nothing is written when pass 1 rejects the archive.
 */
export async function validateAndExtractArchive(
  input: ArchiveValidationInput,
  destDir: string,
): Promise<ArchiveValidationResult> {
  const bytes = Buffer.from(
    input.bytes.buffer,
    input.bytes.byteOffset,
    input.bytes.byteLength,
  );

  let entries: ArchiveEntry[];
  if (input.format === "zip") {
    entries = parseZip(bytes);
  } else if (input.format === "tar") {
    entries = parseTar(bytes);
  } else {
    throw new ArchiveUnsafeError(`unsupported archive format: ${String(input.format)}`);
  }

  await mkdir(destDir, { recursive: true });

  let fileCount = 0;
  let writtenBytes = 0;
  for (const entry of entries) {
    if (entry.kind === "dir") {
      if (entry.normalized !== "") {
        await mkdir(safeDestPath(destDir, entry.normalized), { recursive: true });
      }
      continue;
    }
    // Symlinks (and tar hardlinks) are validated in pass 1 and then skipped.
    if (entry.kind !== "file") continue;

    const absolute = safeDestPath(destDir, entry.normalized);
    await mkdir(dirname(absolute), { recursive: true });
    const data = readZipData(bytes, entry);
    writtenBytes += data.length;
    if (writtenBytes > MAX_PAYLOAD_BYTES) {
      throw new ArchiveUnsafeError(
        `archive decoded payload exceeds ${MAX_PAYLOAD_BYTES} bytes`,
      );
    }
    await writeFile(absolute, data);
    fileCount += 1;
  }

  return { fileCount };
}
