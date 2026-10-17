import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildTar, buildZip } from "./__fixtures__/builders.js";
import { MAX_ENTRIES, MAX_PAYLOAD_BYTES } from "./constants.js";
import {
  ArchiveUnsafeError,
  validateAndExtractArchive,
} from "./archive.js";

let root: string;
let dest: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "ovid-archive-test-"));
  dest = join(root, "out");
  await mkdir(dest);
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

async function expectEmptyDest(): Promise<void> {
  expect(await readdir(dest)).toEqual([]);
}

describe("validateAndExtractArchive — tar", () => {
  it("extracts all regular files preserving relative layout and reports fileCount", async () => {
    const archive = buildTar([
      { name: "plugin.json", data: Buffer.from('{"name":"demo"}') },
      { name: "lib/", type: "5" },
      { name: "lib/a.js", data: Buffer.from("export const a = 1;\n") },
      { name: "lib/nested/b.txt", data: Buffer.from("nested") },
    ]);

    const result = await validateAndExtractArchive({ bytes: archive, format: "tar" }, dest);

    expect(result.fileCount).toBe(3);
    expect(await readFile(join(dest, "plugin.json"), "utf8")).toBe('{"name":"demo"}');
    expect(await readFile(join(dest, "lib/a.js"), "utf8")).toBe("export const a = 1;\n");
    expect(await readFile(join(dest, "lib/nested/b.txt"), "utf8")).toBe("nested");
    expect((await stat(join(dest, "lib"))).isDirectory()).toBe(true);
  });

  it("rejects a ../ entry before writing anything", async () => {
    const archive = buildTar([
      { name: "ok.txt", data: Buffer.from("ok") },
      { name: "../evil", data: Buffer.from("pwn") },
    ]);

    await expect(
      validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects absolute paths and Windows drive/UNC paths", async () => {
    for (const name of ["/etc/passwd", "C:/evil", "\\\\server\\share\\evil"]) {
      const archive = buildTar([{ name, data: Buffer.from("x") }]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("rejects symlinks that escape staging", async () => {
    for (const linkname of ["../../etc/passwd", "/etc/passwd", "..\\..\\evil"]) {
      const archive = buildTar([{ name: "link", type: "2", linkname }]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("skips contained symlinks instead of creating them", async () => {
    const archive = buildTar([
      { name: "plugin.json", data: Buffer.from("{}") },
      { name: "link", type: "2", linkname: "./plugin.json" },
    ]);

    const result = await validateAndExtractArchive({ bytes: archive, format: "tar" }, dest);

    expect(result.fileCount).toBe(1);
    expect(await readFile(join(dest, "plugin.json"), "utf8")).toBe("{}");
    await expect(stat(join(dest, "link"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects hardlinks that escape staging", async () => {
    const archive = buildTar([{ name: "hard", type: "1", linkname: "../outside" }]);
    await expect(
      validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects fifo and device entries", async () => {
    for (const type of ["3", "4", "6"]) {
      const archive = buildTar([{ name: "special", type, size: 0 }]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("rejects a declared-size sum over the payload cap without writing", async () => {
    const archive = buildTar([
      { name: "small.txt", data: Buffer.from("ok") },
      { name: "huge.bin", size: MAX_PAYLOAD_BYTES + 1 },
    ]);

    await expect(
      validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects a truncated archive", async () => {
    const archive = buildTar([{ name: "a.txt", data: Buffer.from("hello") }]);
    const truncated = archive.subarray(0, 512 + 3);
    await expect(
      validateAndExtractArchive({ bytes: truncated, format: "tar" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects an archive with more than MAX_ENTRIES entries", async () => {
    const archive = buildTar(
      Array.from({ length: MAX_ENTRIES + 1 }, (_, i) => ({
        name: `f${i}.txt`,
        data: new Uint8Array(),
      })),
    );
    await expect(
      validateAndExtractArchive({ bytes: archive, format: "tar" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });
});

describe("validateAndExtractArchive — zip", () => {
  it("extracts stored and deflated files preserving relative layout", async () => {
    const archive = buildZip([
      { name: "plugin.json", data: Buffer.from('{"name":"demo"}') },
      { name: "lib/", mode: 0o040755 },
      { name: "lib/a.js", data: Buffer.from("export const a = 1;\n"), method: 8 },
      { name: "lib/nested/b.txt", data: Buffer.from("nested") },
    ]);

    const result = await validateAndExtractArchive({ bytes: archive, format: "zip" }, dest);

    expect(result.fileCount).toBe(3);
    expect(await readFile(join(dest, "plugin.json"), "utf8")).toBe('{"name":"demo"}');
    expect(await readFile(join(dest, "lib/a.js"), "utf8")).toBe("export const a = 1;\n");
    expect(await readFile(join(dest, "lib/nested/b.txt"), "utf8")).toBe("nested");
  });

  it("rejects a ../ entry before writing anything", async () => {
    const archive = buildZip([
      { name: "ok.txt", data: Buffer.from("ok") },
      { name: "../evil", data: Buffer.from("pwn") },
    ]);
    await expect(
      validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects absolute and Windows drive paths", async () => {
    for (const name of ["/etc/passwd", "C:/evil", "\\\\server\\share\\evil"]) {
      const archive = buildZip([{ name, data: Buffer.from("x") }]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("rejects symlinks that escape staging", async () => {
    for (const target of ["../../etc/passwd", "/etc/passwd", "..\\..\\evil"]) {
      const archive = buildZip([
        { name: "link", mode: 0o120777, data: Buffer.from(target) },
      ]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("skips contained symlinks instead of creating them", async () => {
    const archive = buildZip([
      { name: "plugin.json", data: Buffer.from("{}") },
      { name: "link", mode: 0o120777, data: Buffer.from("plugin.json") },
    ]);

    const result = await validateAndExtractArchive({ bytes: archive, format: "zip" }, dest);

    expect(result.fileCount).toBe(1);
    expect(await readFile(join(dest, "plugin.json"), "utf8")).toBe("{}");
    await expect(stat(join(dest, "link"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects fifo, device and socket entries", async () => {
    for (const mode of [0o010644, 0o020644, 0o060644, 0o140644]) {
      const archive = buildZip([{ name: "special", mode, data: Buffer.alloc(0) }]);
      await expect(
        validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
      ).rejects.toBeInstanceOf(ArchiveUnsafeError);
      await expectEmptyDest();
    }
  });

  it("rejects a declared-size sum over the payload cap without writing", async () => {
    const archive = buildZip([
      { name: "small.txt", data: Buffer.from("ok") },
      { name: "huge.bin", data: Buffer.from("tiny"), method: 8, declaredSize: MAX_PAYLOAD_BYTES + 1 },
    ]);
    await expect(
      validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects non-zip input", async () => {
    await expect(
      validateAndExtractArchive({ bytes: Buffer.from("not a zip"), format: "zip" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });

  it("rejects an archive with more than MAX_ENTRIES entries", async () => {
    const archive = buildZip(
      Array.from({ length: MAX_ENTRIES + 1 }, (_, i) => ({
        name: `f${i}.txt`,
        data: new Uint8Array(),
      })),
    );
    await expect(
      validateAndExtractArchive({ bytes: archive, format: "zip" }, dest),
    ).rejects.toBeInstanceOf(ArchiveUnsafeError);
    await expectEmptyDest();
  });
});
