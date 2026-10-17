/**
 * UI manifest trees over an archive index (uiTree) or a live workspace dir
 * (liveTree) — the "<5 KB pruned lazy tree" of spike §9.3.
 *
 * Both run the same builder so a warm (live) and cold (manifest) session see
 * identical trees:
 * - depth default 2: roots and their children expand; dirs at the depth cap
 *   are pruned to recursive rollups {files, bytes, dirs} with no children
 * - sibling order is deterministic: subdirs first (name asc, byte-wise),
 *   then files/symlinks by sizeBytes desc, then name asc
 * - maxBytes default UI_MANIFEST_MAX_BYTES: when the serialized manifest
 *   would exceed it, remaining siblings drop into the parent's `omitted`
 *   count and truncated=true — the output is NEVER over budget
 * - mtime is ISO with second precision (the archive format stores u32 sec)
 * - symlinks are listed as nodes but not counted in rollups/totals (v1)
 */

import {
  UI_MANIFEST_MAX_BYTES,
  type FileTreeNode,
  type UiManifest,
} from "@ovid/shared";

import { StorageError } from "../errors.js";
import { walkWorkspace, type ArchiveIndex } from "./pack.js";

export interface UiTreeOpts {
  depth?: number;
  maxBytes?: number;
  now?: () => Date;
}

/** A path record from either an ArchiveIndex or a live walk. */
interface TreeRec {
  path: string;
  type: 0 | 1 | 2;
  size: number;
  mtime?: number;
}

interface RawNode {
  name: string;
  path: string;
  type: 0 | 1 | 2;
  size: number;
  mtime?: number;
  children: Map<string, RawNode>; // dirs only
}

function isoSecond(sec: number): string {
  return new Date(sec * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function nameCmp(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

/** Subdirs first (name asc), then non-dirs by size desc, then name asc. */
function sortSiblings(nodes: FileTreeNode[]): void {
  nodes.sort((a, b) => {
    const aDir = a.type === "dir" ? 0 : 1;
    const bDir = b.type === "dir" ? 0 : 1;
    if (aDir !== bDir) return aDir - bDir;
    if (aDir === 1) {
      const d = (b.sizeBytes ?? 0) - (a.sizeBytes ?? 0);
      if (d !== 0) return d;
    }
    return nameCmp(a.name, b.name);
  });
}

function buildRawTree(recs: TreeRec[]): Map<string, RawNode> {
  const roots = new Map<string, RawNode>();
  for (const rec of recs) {
    const segs = rec.path.split("/");
    let parent = roots;
    let prefix = "";
    for (let i = 0; i < segs.length - 1; i++) {
      const seg = segs[i];
      prefix = prefix === "" ? seg : `${prefix}/${seg}`;
      let node = parent.get(seg);
      if (node === undefined) {
        // synthesized dir — no record of its own (e.g. file-only index)
        node = { name: seg, path: prefix, type: 1, size: 0, children: new Map() };
        parent.set(seg, node);
      }
      parent = node.children;
    }
    const leaf = segs[segs.length - 1];
    if (rec.type === 1) {
      const existing = parent.get(leaf);
      if (existing === undefined) {
        parent.set(leaf, {
          name: leaf,
          path: rec.path,
          type: 1,
          size: 0,
          mtime: rec.mtime,
          children: new Map(),
        });
      } else if (rec.mtime !== undefined) {
        existing.mtime = rec.mtime; // record arrived after a synthesized node
      }
    } else {
      parent.set(leaf, {
        name: leaf,
        path: rec.path,
        type: rec.type,
        size: rec.size,
        mtime: rec.mtime,
        children: new Map(),
      });
    }
  }
  return roots;
}

/** Recursive {files, bytes, dirs} rollup over a dir's descendants. */
function rollup(node: RawNode): { files: number; bytes: number; dirs: number } {
  let files = 0;
  let bytes = 0;
  let dirs = 0;
  for (const child of node.children.values()) {
    if (child.type === 0) {
      files++;
      bytes += child.size;
    } else if (child.type === 1) {
      dirs++;
      const r = rollup(child);
      files += r.files;
      bytes += r.bytes;
      dirs += r.dirs;
    }
  }
  return { files, bytes, dirs };
}

function toNode(raw: RawNode, depth: number, maxDepth: number): FileTreeNode {
  const node: FileTreeNode = {
    name: raw.name,
    path: raw.path,
    type: raw.type === 1 ? "dir" : raw.type === 2 ? "symlink" : "file",
  };
  if (raw.mtime !== undefined) node.mtime = isoSecond(raw.mtime);
  if (raw.type !== 1) node.sizeBytes = raw.size;
  if (raw.type === 1) {
    if (depth < maxDepth) {
      node.children = [...raw.children.values()].map((c) =>
        toNode(c, depth + 1, maxDepth),
      );
      sortSiblings(node.children);
    } else {
      const r = rollup(raw);
      node.files = r.files;
      node.bytes = r.bytes;
      node.dirs = r.dirs;
    }
  }
  return node;
}

function totalsOf(recs: TreeRec[]): { files: number; dirs: number; bytes: number } {
  let files = 0;
  let dirs = 0;
  let bytes = 0;
  for (const r of recs) {
    if (r.type === 0) {
      files++;
      bytes += r.size;
    } else if (r.type === 1) {
      dirs++;
    }
  }
  return { files, dirs, bytes };
}

// ---------------------------------------------------------------------------
// Budget fitting — never emit > maxBytes
// ---------------------------------------------------------------------------

/** Bytes saved by a node's omission margin: omitted-count digit growth etc. */
const TRIM_MARGIN = 16;

/**
 * Fits a node within `budget` bytes of JSON. Returns null when even the
 * trimmed node cannot fit (the caller then drops it); a node with children
 * is trimmed by dropping REMAINING siblings (in display order) into
 * `omitted`.
 */
function fitNode(
  node: FileTreeNode,
  budget: number,
): { node: FileTreeNode; cost: number } | null {
  const cost = JSON.stringify(node).length;
  if (cost <= budget) return { node, cost };

  const children = node.children;
  if (children === undefined || children.length === 0) return null; // leaf

  const shellLen = JSON.stringify({ ...node, children: [] }).length;
  let inner = budget - shellLen - TRIM_MARGIN;
  if (inner < 0) return null;

  const kept: FileTreeNode[] = [];
  let omitted = 0;
  for (let i = 0; i < children.length; i++) {
    const fitted = fitNode(children[i], inner);
    if (fitted === null) {
      omitted = children.length - i; // drop the remaining siblings
      break;
    }
    kept.push(fitted.node);
    inner -= fitted.cost + 1;
  }

  const out: FileTreeNode = { ...node, children: kept };
  const baseOmitted = node.omitted ?? 0;
  if (omitted + baseOmitted > 0) out.omitted = omitted + baseOmitted;
  const outLen = JSON.stringify(out).length;
  if (outLen > budget) return null; // margin safety — drop the whole node
  return { node: out, cost: outLen };
}

function fitManifest(m: UiManifest, maxBytes: number): UiManifest {
  if (JSON.stringify(m).length <= maxBytes) return m;

  const wrapperLen = JSON.stringify({ ...m, roots: [] }).length;
  let budget = maxBytes - wrapperLen - TRIM_MARGIN;
  const kept: FileTreeNode[] = [];
  for (const root of m.roots) {
    if (budget <= 0) break;
    const fitted = fitNode(root, budget);
    if (fitted === null) break; // remaining roots dropped (no parent to hold them)
    kept.push(fitted.node);
    budget -= fitted.cost + 1;
  }

  let out: UiManifest = { ...m, roots: kept, truncated: true };
  // Hard guarantee, even if the margins above were optimistic.
  while (out.roots.length > 0 && JSON.stringify(out).length > maxBytes) {
    out = { ...out, roots: out.roots.slice(0, -1) };
  }
  if (JSON.stringify(out).length > maxBytes) {
    throw new StorageError(
      `uiTree cannot fit a manifest within maxBytes=${maxBytes} (the empty wrapper alone is ${wrapperLen} bytes)`,
      { code: "ui_manifest_budget" },
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function treeFromRecs(recs: TreeRec[], opts: UiTreeOpts): UiManifest {
  const depth = Math.max(1, Math.floor(opts.depth ?? 2));
  const maxBytes = opts.maxBytes ?? UI_MANIFEST_MAX_BYTES;
  const now = opts.now ?? (() => new Date());

  const rawRoots = buildRawTree(recs);
  const roots = [...rawRoots.values()].map((r) => toNode(r, 1, depth));
  sortSiblings(roots);

  const manifest: UiManifest = {
    version: 1,
    generatedAt: now().toISOString(),
    truncated: false,
    totals: totalsOf(recs),
    roots,
  };
  return fitManifest(manifest, maxBytes);
}

/** Pruned UI tree from a packed archive index. */
export function uiTree(index: ArchiveIndex, opts: UiTreeOpts = {}): UiManifest {
  return treeFromRecs(index.files, opts);
}

/** Pruned UI tree from the live (warm) workspace directory. */
export async function liveTree(
  wsDir: string,
  opts: UiTreeOpts = {},
): Promise<UiManifest> {
  const entries = await walkWorkspace(wsDir);
  return treeFromRecs(entries, opts);
}
