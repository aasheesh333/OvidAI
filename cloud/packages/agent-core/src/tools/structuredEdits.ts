/**
 * Pure, I/O-free cores of the [CC] MultiEdit and NotebookEdit tools (ported
 * from lib/core/structured_edits.dart). The tools in sandboxTools.ts own
 * paths, reads and writes; these functions only turn old content into new
 * content, or throw a {@link StructuredEditError} and change nothing (atomic).
 */

export class StructuredEditError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StructuredEditError";
  }
}

/** One MultiEdit operation. */
export interface TextEdit {
  oldString: string;
  newString: string;
  replaceAll: boolean;
}

function asString(v: unknown): string {
  return v === null || v === undefined ? "" : String(v);
}

/**
 * Parses the `edits` array of a multi_edit call. Accepts the [CC] keys
 * (old_string/new_string/replace_all) and Ovid's fs_edit spellings
 * (old_str/new_str). An empty or non-array input is the pinned error.
 */
export function parseEditList(raw: unknown): TextEdit[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new StructuredEditError(
      "edits must be a non-empty array of {old_string, new_string}",
    );
  }
  return raw.map((e, i) => {
    if (typeof e !== "object" || e === null) {
      throw new StructuredEditError(`edit ${i + 1} is not an object`);
    }
    const o = e as Record<string, unknown>;
    return {
      oldString: asString(o.old_string ?? o.old_str),
      newString: asString(o.new_string ?? o.new_str),
      replaceAll: o.replace_all === true,
    };
  });
}

function countOccurrences(haystack: string, needle: string): number {
  if (needle === "") return 0;
  let n = 0;
  let i = haystack.indexOf(needle);
  while (i >= 0) {
    n += 1;
    i = haystack.indexOf(needle, i + needle.length);
  }
  return n;
}

/**
 * Applies [edits] in order, each to the result of the previous one. All or
 * nothing: the first failing edit throws and nothing is returned.
 *
 * Create rule ([CC] MultiEdit): when the content is empty and the FIRST edit's
 * oldString is empty, that edit creates the content (its newString becomes the
 * text the remaining edits apply to). An empty oldString anywhere else is an
 * error.
 */
export function applyMultiEdit(content: string, edits: readonly TextEdit[]): string {
  let text = content;
  for (let i = 0; i < edits.length; i += 1) {
    const e = edits[i];
    const n = i + 1;
    if (i === 0 && text === "" && e.oldString === "") {
      text = e.newString;
      continue;
    }
    if (e.oldString === "") {
      throw new StructuredEditError(`edit ${n}: old_string must not be empty`);
    }
    if (e.oldString === e.newString) {
      throw new StructuredEditError(`edit ${n}: old_string and new_string are identical`);
    }
    const count = countOccurrences(text, e.oldString);
    if (count === 0) {
      throw new StructuredEditError(
        `edit ${n}: old_string not found (after applying edits 1..${n - 1})`,
      );
    }
    if (count > 1 && !e.replaceAll) {
      throw new StructuredEditError(
        `edit ${n}: old_string matches ${count} times — add surrounding context ` +
          "to make it unique, or set replace_all: true",
      );
    }
    text = e.replaceAll
      ? text.split(e.oldString).join(e.newString)
      : text.replace(e.oldString, e.newString);
  }
  return text;
}

// -- notebook edits -----------------------------------------------------------

export type NotebookEditMode = "replace" | "insert" | "delete";

export function parseNotebookEditMode(raw: unknown): NotebookEditMode {
  if (raw === null || raw === undefined || raw === "" || raw === "replace") return "replace";
  if (raw === "insert") return "insert";
  if (raw === "delete") return "delete";
  throw new StructuredEditError(
    `edit_mode must be replace, insert or delete (got "${String(raw)}")`,
  );
}

interface NotebookCell {
  cell_type: string;
  id?: string;
  metadata: Record<string, unknown>;
  source?: string[];
  execution_count?: number | null;
  outputs?: unknown[];
}

/** nbformat stores source as a list of lines, each keeping its "\n". */
function splitLines(s: string): string[] {
  if (s === "") return [];
  const parts = s.split("\n");
  const out: string[] = [];
  for (let i = 0; i < parts.length; i += 1) {
    if (i < parts.length - 1) out.push(`${parts[i]}\n`);
    else if (parts[i] !== "") out.push(parts[i]);
  }
  return out;
}

let cellIdCounter = 0;

function newCellId(cells: NotebookCell[]): string {
  const used = new Set(cells.map((c) => c.id).filter((id) => typeof id === "string"));
  let n = Date.now() * 1000;
  while (true) {
    const id = (n + cellIdCounter).toString(16).padStart(8, "0").slice(-8);
    cellIdCounter += 1;
    if (!used.has(id)) return id;
    n += 1;
  }
}

/**
 * Applies one [CC] NotebookEdit to a `.ipynb` JSON source.
 *
 * - replace (default): overwrite the target cell's source; metadata, id and
 *   outputs are preserved. Changing cell_type drops outputs/execution_count
 *   when the cell becomes markdown and adds empty ones when it becomes code.
 * - insert: add a new cell AFTER the target (first when cellId is omitted);
 *   cellType ("code" | "markdown") is required.
 * - delete: remove the target cell.
 *
 * cellId matches a cell's id, a 0-based index, or "cell-N". Returns the new
 * JSON (1-space indent, the nbformat convention) with a trailing newline.
 */
export function applyNotebookEdit(
  source: string,
  o: { cellId?: string; newSource: string; cellType?: string; mode?: NotebookEditMode },
): string {
  const mode = o.mode ?? "replace";
  let decoded: unknown;
  try {
    decoded = JSON.parse(source);
  } catch {
    throw new StructuredEditError("not a valid .ipynb (invalid JSON)");
  }
  if (
    typeof decoded !== "object" ||
    decoded === null ||
    !Array.isArray((decoded as Record<string, unknown>).cells)
  ) {
    throw new StructuredEditError("not a valid .ipynb (no cells array)");
  }
  const nb = decoded as Record<string, unknown>;
  const cells = nb.cells as unknown[];
  if (o.cellType !== undefined && o.cellType !== "code" && o.cellType !== "markdown") {
    throw new StructuredEditError(
      `cell_type must be code or markdown (got "${o.cellType}")`,
    );
  }

  const indexOf = (id: string | undefined): number | null => {
    if (id === undefined || id === "") return null;
    for (let i = 0; i < cells.length; i += 1) {
      const c = cells[i] as Record<string, unknown>;
      if (c && typeof c === "object" && c.id === id) return i;
    }
    const m = /^(?:cell-)?(\d+)$/.exec(id);
    if (m) {
      const i = Number(m[1]);
      if (i >= 0 && i < cells.length) return i;
    }
    throw new StructuredEditError(`cell_id "${id}" not found in the notebook`);
  };

  const target = indexOf(o.cellId);
  const minor = typeof nb.nbformat_minor === "number" ? nb.nbformat_minor : 0;
  const major = typeof nb.nbformat === "number" ? nb.nbformat : 4;
  const wantsIds = major > 4 || (major === 4 && minor >= 5);

  if (mode === "delete") {
    if (target === null) throw new StructuredEditError("delete needs a cell_id");
    cells.splice(target, 1);
  } else if (mode === "insert") {
    if (o.cellType === undefined) {
      throw new StructuredEditError("insert needs cell_type (code or markdown)");
    }
    const cell: Record<string, unknown> = {
      cell_type: o.cellType,
      ...(wantsIds ? { id: newCellId(cells as NotebookCell[]) } : {}),
      metadata: {},
      source: splitLines(o.newSource),
    };
    if (o.cellType === "code") {
      cell.execution_count = null;
      cell.outputs = [];
    }
    cells.splice(target === null ? 0 : target + 1, 0, cell);
  } else {
    if (target === null) throw new StructuredEditError("replace needs a cell_id");
    const cell = { ...(cells[target] as Record<string, unknown>) };
    cell.source = splitLines(o.newSource);
    if (o.cellType !== undefined && o.cellType !== cell.cell_type) {
      cell.cell_type = o.cellType;
      if (o.cellType === "markdown") {
        delete cell.outputs;
        delete cell.execution_count;
      } else {
        cell.outputs = [];
        cell.execution_count = null;
      }
    }
    cells[target] = cell;
  }
  nb.cells = cells;
  return `${JSON.stringify(nb, null, 1)}\n`;
}
