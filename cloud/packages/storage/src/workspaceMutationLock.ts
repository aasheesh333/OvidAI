import { realpath } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";

interface Mutation {
  paths: readonly string[];
  done: Promise<void>;
}

function overlaps(a: string, b: string): boolean {
  return a === b || a.startsWith(b + sep) || b.startsWith(a + sep);
}

/**
 * Process-local, FIFO locking of overlapping paths (including subtrees).
 * A move requests both ends together, so there is no hold-and-wait deadlock.
 * Unrelated files/users never wait on one another. Only live requests are kept;
 * completion and failure both remove their entry. No lock files are created.
 *
 * This is NOT filesystem CAS: writers in other processes, agent shell commands,
 * and lifecycle operations do not participate in this protocol.
 */
export class WorkspaceMutationLocks {
  private readonly pending = new Set<Mutation>();

  async run<T>(paths: readonly string[], fn: () => Promise<T>): Promise<T> {
    let release!: () => void;
    const mutation: Mutation = {
      paths,
      done: new Promise<void>((resolveDone) => { release = resolveDone; }),
    };
    const blockers = [...this.pending].filter((other) =>
      paths.some((path) => other.paths.some((otherPath) => overlaps(path, otherPath))),
    );
    // Publish before awaiting: later conflicting callers queue behind this one.
    this.pending.add(mutation);
    try {
      await Promise.all(blockers.map((blocker) => blocker.done));
      return await fn();
    } finally {
      this.pending.delete(mutation);
      release();
    }
  }
}

const mutations = new WorkspaceMutationLocks();

/** Resolve existing parent symlinks, preserving a missing suffix and the leaf. */
async function physicalParentPath(path: string): Promise<string> {
  let parent = dirname(path);
  let suffix = basename(path);
  for (;;) {
    try {
      return join(await realpath(parent), suffix);
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== "ENOENT" && code !== "ENOTDIR") throw err;
      const up = dirname(parent);
      if (up === parent) throw err;
      suffix = join(basename(parent), suffix);
      parent = up;
    }
  }
}

async function lockPaths(paths: readonly string[]): Promise<string[]> {
  const lexical = paths.map((path) => resolve(path));
  // Keep lexical names too: removing an in-workspace symlink folder conflicts
  // with writes through it, while aliases of the same parent share physical keys.
  const physical = await Promise.all(lexical.map(physicalParentPath));
  return [...new Set([...lexical, ...physical])].sort();
}

/** All warm Studio mutations in this process must use this shared singleton. */
export async function withWorkspaceMutation<T>(
  paths: readonly string[],
  fn: () => Promise<T>,
): Promise<T> {
  for (;;) {
    const keys = await lockPaths(paths);
    const result = await mutations.run(keys, async () => {
      // A queued folder mutation may have changed a symlinked parent. Retry
      // under the new keys rather than run under a stale physical identity.
      const current = await lockPaths(paths);
      if (keys.length !== current.length || keys.some((key, i) => key !== current[i])) {
        return { retry: true as const };
      }
      return { retry: false as const, value: await fn() };
    });
    if (!result.retry) return result.value;
  }
}
