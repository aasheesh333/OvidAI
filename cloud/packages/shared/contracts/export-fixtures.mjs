import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// The override keeps exporter tests isolated from the three real repositories.
const alternateRoot = process.env.OVID_CONTRACT_EXPORT_ROOT;
const sourceDir = alternateRoot
  ? join(alternateRoot, "contracts", "fixtures")
  : fileURLToPath(new URL("./fixtures/", import.meta.url));
const mirrorDirs = alternateRoot
  ? [
      join(alternateRoot, "web", "contracts", "fixtures"),
      join(alternateRoot, "flutter", "test", "fixtures", "contracts"),
    ]
  : [
      fileURLToPath(new URL("../../../../../OvidWeb/web/contracts/fixtures/", import.meta.url)),
      fileURLToPath(new URL("../../../../../OvidFlutter/test/fixtures/contracts/", import.meta.url)),
    ];
const check = process.argv.includes("--check");

async function jsonNames(directory, allowMissing = false) {
  try {
    return (await readdir(directory, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => entry.name)
      .sort();
  } catch (error) {
    if (allowMissing && error?.code === "ENOENT") return [];
    throw error;
  }
}

// This fixture has its own hardened exporter and test-fixture mirror roots.
const canonicalNames = (await jsonNames(sourceDir)).filter(
  (name) => name !== "system-requests-v1.json",
);
if (canonicalNames.length === 0) {
  console.error("No canonical fixture JSON files found; refusing an empty canonical source.");
  process.exitCode = 1;
} else {
  const canonicalNameSet = new Set(canonicalNames);
  const mirrorNames = await Promise.all(mirrorDirs.map((directory) => jsonNames(directory, true)));
  const drift = [];

  if (check) {
    for (let index = 0; index < mirrorDirs.length; index += 1) {
      const mirrorDir = mirrorDirs[index];
      for (const name of mirrorNames[index]) {
        if (!canonicalNameSet.has(name)) drift.push(join(mirrorDir, name));
      }
      for (const name of canonicalNames) {
        const mirrorPath = join(mirrorDir, name);
        try {
          const [canonical, mirror] = await Promise.all([
            readFile(join(sourceDir, name)),
            readFile(mirrorPath),
          ]);
          if (!mirror.equals(canonical)) drift.push(mirrorPath);
        } catch {
          drift.push(mirrorPath);
        }
      }
    }
  } else {
    for (let index = 0; index < mirrorDirs.length; index += 1) {
      const mirrorDir = mirrorDirs[index];
      await mkdir(mirrorDir, { recursive: true });
      for (const name of mirrorNames[index]) {
        if (!canonicalNameSet.has(name)) await unlink(join(mirrorDir, name));
      }
      for (const name of canonicalNames) {
        await writeFile(join(mirrorDir, name), await readFile(join(sourceDir, name)));
      }
    }
  }

  if (drift.length > 0) {
    for (const path of drift) console.error(`Fixture mirror drift: ${path}`);
    process.exitCode = 1;
  } else if (check) {
    console.log(`${canonicalNames.length} canonical fixture files match both mirrors exactly.`);
  } else {
    console.log(`Exported ${canonicalNames.length} canonical fixture files to both mirrors.`);
  }
}
