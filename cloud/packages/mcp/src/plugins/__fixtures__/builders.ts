// Test-only fixture builders for archive.test.ts / sources.test.ts.
// Not exported from the package barrel; lives under __fixtures__ so it is
// obviously not production code.

import { deflateRawSync } from "node:zlib";

export interface TarFixtureEntry {
  name: string;
  /** ustar typeflag: "0" file, "5" dir, "2" symlink, "1" hardlink, "6" fifo, ... */
  type?: string;
  data?: Uint8Array;
  /** Overrides the size field without supplying data (crafted-header tests). */
  size?: number;
  linkname?: string;
}

function octal(value: number, width: number): string {
  const digits = width - 1;
  return value.toString(8).padStart(digits, "0") + "\0";
}

function round512(n: number): number {
  return Math.ceil(n / 512) * 512;
}

/** Build an uncompressed ustar archive. */
export function buildTar(entries: TarFixtureEntry[]): Uint8Array {
  const blocks: Buffer[] = [];
  for (const entry of entries) {
    const data = entry.data === undefined ? Buffer.alloc(0) : Buffer.from(entry.data);
    const size = entry.size === undefined ? data.length : entry.size;
    const header = Buffer.alloc(512, 0);
    header.write(entry.name.slice(0, 100), 0, 100, "utf8");
    header.write(octal(0o644, 8), 100, 8, "ascii");
    header.write(octal(0, 8), 108, 8, "ascii"); // uid
    header.write(octal(0, 8), 116, 8, "ascii"); // gid
    header.write(octal(size, 12), 124, 12, "ascii");
    header.write(octal(0, 12), 136, 12, "ascii"); // mtime
    header.write("        ", 148, 8, "ascii"); // checksum placeholder
    header.write(entry.type ?? "0", 156, 1, "ascii");
    if (entry.linkname !== undefined) {
      header.write(entry.linkname.slice(0, 100), 157, 100, "utf8");
    }
    header.write("ustar\0", 257, 6, "ascii");
    header.write("00", 263, 2, "ascii");
    let sum = 0;
    for (const byte of header) sum += byte;
    header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");

    blocks.push(header);
    if (size > 0) {
      blocks.push(data);
      const pad = round512(size) - size;
      if (pad > 0) blocks.push(Buffer.alloc(pad));
    }
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

export interface ZipFixtureEntry {
  name: string;
  data?: Uint8Array;
  /** Unix mode; defaults to 0o100644 (regular file). */
  mode?: number;
  /** 0 = stored, 8 = deflate. */
  method?: number;
  /** Override the declared uncompressed size in the central directory. */
  declaredSize?: number;
}

/** Build a minimal (non-zip64) zip archive with a central directory. */
export function buildZip(entries: ZipFixtureEntry[]): Uint8Array {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const data = Buffer.from(entry.data ?? new Uint8Array());
    const method = entry.method ?? 0;
    const payload = method === 0 ? data : deflateRawSync(data);
    const mode = entry.mode ?? 0o100644;
    const declared = entry.declaredSize ?? data.length;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 name flag
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10); // time
    local.writeUInt16LE(0, 12); // date
    local.writeUInt32LE(0, 14); // crc (parser does not verify)
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(declared, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28); // extra
    locals.push(local, name, payload);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x031e, 4); // made by: unix, 3.0
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0, 14);
    central.writeUInt32LE(0, 16);
    central.writeUInt32LE(payload.length, 20);
    central.writeUInt32LE(declared, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30); // extra
    central.writeUInt16LE(0, 32); // comment
    central.writeUInt16LE(0, 34); // disk
    central.writeUInt16LE(0, 36); // internal attrs
    central.writeUInt32LE(((mode << 16) >>> 0), 38);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, name);

    offset += local.length + name.length + payload.length;
  }

  const centralDir = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralDir.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);
  return Buffer.concat([...locals, centralDir, eocd]);
}
