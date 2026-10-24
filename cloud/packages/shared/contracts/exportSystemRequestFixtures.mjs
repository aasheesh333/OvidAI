import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, unlink } from "node:fs/promises";
import { isAbsolute, join, parse, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const DIRECTORY_FLAGS = constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW;
const READ_FLAGS = constants.O_RDONLY | constants.O_NOFOLLOW;
const TEMP_FLAGS = constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW;
const FIXTURE_NAME = "system-requests-v1.json";

// The override keeps exporter tests isolated from the three real repositories.
const alternateRoot = process.env.OVID_SYSTEM_REQUEST_FIXTURE_ROOT;
const sourceSpec = alternateRoot
  ? { base: alternateRoot, segments: ["contracts", "fixtures"] }
  : {
      base: fileURLToPath(new URL("../../../../", import.meta.url)),
      segments: ["cloud", "packages", "shared", "contracts", "fixtures"],
    };
const mirrorSpecs = alternateRoot
  ? [
      { base: alternateRoot, segments: ["web", "test", "fixtures"] },
      { base: alternateRoot, segments: ["flutter", "test", "fixtures"] },
    ]
  : [
      {
        base: fileURLToPath(new URL("../../../../../OvidWeb/", import.meta.url)),
        segments: ["web", "test", "fixtures"],
      },
      {
        base: fileURLToPath(new URL("../../../../../OvidFlutter/", import.meta.url)),
        segments: ["test", "fixtures"],
      },
    ];
const check = process.argv.includes("--check");

function specPath(spec) {
  return resolve(spec.base, ...spec.segments);
}

function fdPath(directory, ...parts) {
  return join("/proc/self/fd", String(directory.handle.fd), ...parts);
}

function containedBy(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function refuse(path, reason) {
  throw new Error(`Unsafe system request fixture path ${path}: ${reason}`);
}

async function closeDirectory(directory) {
  if (directory !== null) await directory.handle.close();
}

async function assertPlainPath(path) {
  const absolute = resolve(path);
  const root = parse(absolute).root;
  let current = root;
  const parts = absolute.slice(root.length).split(sep).filter(Boolean);
  for (let index = 0; index < parts.length; index += 1) {
    current = join(current, parts[index]);
    const stats = await lstat(current);
    if (stats.isSymbolicLink()) refuse(current, "symbolic-link ancestry is not allowed");
    if (index < parts.length - 1 && !stats.isDirectory()) {
      refuse(current, "a non-directory ancestor is not allowed");
    }
  }
}

async function openDirectory(path) {
  const absolute = resolve(path);
  await assertPlainPath(absolute);
  let handle;
  try {
    handle = await open(absolute, DIRECTORY_FLAGS);
    const stats = await handle.stat();
    if (!stats.isDirectory()) refuse(absolute, "not a directory");
    const directory = {
      handle,
      path: absolute,
      realPath: await realpath(fdPath({ handle })),
      baseReal: absolute,
    };
    if (directory.realPath !== absolute) {
      refuse(absolute, `real path ${directory.realPath} differs from the approved path`);
    }
    return directory;
  } catch (error) {
    if (handle !== undefined) await handle.close().catch(() => {});
    throw error;
  }
}

async function assertDirectoryCurrent(directory) {
  await assertPlainPath(directory.path);
  const pathStats = await lstat(directory.path);
  if (!pathStats.isDirectory()) refuse(directory.path, "destination is not a real directory");
  const [fdStats, lexicalReal, fdReal] = await Promise.all([
    directory.handle.stat(),
    realpath(directory.path),
    realpath(fdPath(directory)),
  ]);
  if (pathStats.dev !== fdStats.dev || pathStats.ino !== fdStats.ino) {
    refuse(directory.path, "directory was replaced after it was verified");
  }
  if (lexicalReal !== directory.realPath || fdReal !== directory.realPath) {
    refuse(directory.path, `directory identity changed (${lexicalReal} / ${fdReal})`);
  }
  if (!containedBy(directory.baseReal, fdReal)) {
    refuse(directory.path, `real path ${fdReal} escapes ${directory.baseReal}`);
  }
}

async function openTree(spec, create) {
  let current = await openDirectory(spec.base);
  current.baseReal = current.realPath;
  try {
    for (const segment of spec.segments) {
      await assertDirectoryCurrent(current);
      const childPath = join(current.path, segment);
      const anchoredChild = fdPath(current, segment);
      let stats;
      try {
        stats = await lstat(anchoredChild);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
        if (!create) {
          await closeDirectory(current);
          return null;
        }
        await assertDirectoryCurrent(current);
        try {
          await mkdir(anchoredChild);
        } catch (mkdirError) {
          if (mkdirError?.code !== "EEXIST") throw mkdirError;
        }
        stats = await lstat(anchoredChild);
      }
      if (stats.isSymbolicLink()) refuse(childPath, "symbolic-link directories are not allowed");
      if (!stats.isDirectory()) refuse(childPath, "a non-directory path blocks the destination");

      const handle = await open(anchoredChild, DIRECTORY_FLAGS);
      const child = {
        handle,
        path: childPath,
        realPath: await realpath(fdPath({ handle })),
        baseReal: current.baseReal,
      };
      const statsAfterOpen = await handle.stat();
      if (!statsAfterOpen.isDirectory()) refuse(childPath, "not a directory");
      const expectedReal = join(current.realPath, segment);
      if (child.realPath !== expectedReal || !containedBy(child.baseReal, child.realPath)) {
        refuse(childPath, `real path ${child.realPath} is outside the approved destination`);
      }
      await closeDirectory(current);
      current = child;
    }
    await assertDirectoryCurrent(current);
    return current;
  } catch (error) {
    await closeDirectory(current).catch(() => {});
    throw error;
  }
}

async function validateRegularDestination(directory, name, allowMissing = false) {
  await assertDirectoryCurrent(directory);
  const path = join(directory.path, name);
  let stats;
  try {
    stats = await lstat(fdPath(directory, name));
  } catch (error) {
    if (allowMissing && error?.code === "ENOENT") return null;
    throw error;
  }
  if (stats.isSymbolicLink()) refuse(path, "symbolic-link destinations are not allowed");
  if (!stats.isFile()) refuse(path, "destination is not a regular file");
  return stats;
}

async function readRegular(directory, name, allowMissing = false) {
  const path = join(directory.path, name);
  let handle;
  try {
    await assertDirectoryCurrent(directory);
    handle = await open(fdPath(directory, name), READ_FLAGS);
    const openedStats = await handle.stat();
    if (!openedStats.isFile()) refuse(path, "not a regular file");
    const bytes = await handle.readFile();
    const currentStats = await validateRegularDestination(directory, name, allowMissing);
    if (
      currentStats === null ||
      currentStats.dev !== openedStats.dev ||
      currentStats.ino !== openedStats.ino
    ) {
      refuse(path, "file changed while it was being read");
    }
    return bytes;
  } catch (error) {
    if (allowMissing && error?.code === "ENOENT") return null;
    if (error?.code === "ELOOP") refuse(path, "symbolic-link destinations are not allowed");
    throw error;
  } finally {
    if (handle !== undefined) await handle.close().catch(() => {});
  }
}

async function writeAtomic(directory, name, bytes) {
  await validateRegularDestination(directory, name, true);
  const tempName = `.${name}.${process.pid}.${randomUUID()}.tmp`;
  let handle;
  let tempStats;
  let created = false;
  let renamed = false;
  try {
    handle = await open(fdPath(directory, tempName), TEMP_FLAGS, 0o666);
    created = true;
    await handle.writeFile(bytes);
    tempStats = await handle.stat();
    await handle.close();
    handle = undefined;

    await assertDirectoryCurrent(directory);
    await validateRegularDestination(directory, name, true);
    const currentTemp = await lstat(fdPath(directory, tempName));
    if (
      currentTemp.isSymbolicLink() ||
      !currentTemp.isFile() ||
      currentTemp.dev !== tempStats.dev ||
      currentTemp.ino !== tempStats.ino
    ) {
      refuse(join(directory.path, tempName), "temporary file changed before rename");
    }

    // Both names resolve through the verified directory handle. rename replaces
    // a last-minute destination link itself; it never follows that link.
    await rename(fdPath(directory, tempName), fdPath(directory, name));
    renamed = true;
    await assertDirectoryCurrent(directory);
    const destination = await validateRegularDestination(directory, name);
    if (destination.dev !== tempStats.dev || destination.ino !== tempStats.ino) {
      refuse(join(directory.path, name), "destination changed during atomic replacement");
    }
  } finally {
    if (handle !== undefined) await handle.close().catch(() => {});
    if (created && !renamed) await unlink(fdPath(directory, tempName)).catch(() => {});
  }
}

const openedDirectories = [];
try {
  const source = await openTree(sourceSpec, false);
  if (source === null) throw new Error(`Missing canonical source ${specPath(sourceSpec)}`);
  openedDirectories.push(source);
  const payload = await readRegular(source, FIXTURE_NAME);

  const mirrors = [];
  for (const spec of mirrorSpecs) {
    const directory = await openTree(spec, !check);
    if (directory !== null) {
      openedDirectories.push(directory);
      // Preflight every destination before writing either mirror.
      await validateRegularDestination(directory, FIXTURE_NAME, true);
    }
    mirrors.push({ spec, directory, path: specPath(spec) });
  }

  const drift = [];
  if (check) {
    for (const mirror of mirrors) {
      const bytes = mirror.directory === null
        ? null
        : await readRegular(mirror.directory, FIXTURE_NAME, true);
      if (bytes === null || !bytes.equals(payload)) {
        drift.push(join(mirror.path, FIXTURE_NAME));
      }
    }
  } else {
    for (const mirror of mirrors) {
      await writeAtomic(mirror.directory, FIXTURE_NAME, payload);
    }
  }

  if (drift.length > 0) {
    for (const path of drift) console.error(`System request fixture mirror drift: ${path}`);
    process.exitCode = 1;
  } else if (check) {
    console.log("Canonical system request fixture matches both mirrors exactly.");
  } else {
    console.log("Exported the canonical system request fixture to both mirrors.");
  }
} catch (error) {
  console.error(`System request fixture export refused: ${error?.message ?? error}`);
  process.exitCode = 1;
} finally {
  for (const directory of openedDirectories.reverse()) {
    await closeDirectory(directory).catch(() => {});
  }
}
