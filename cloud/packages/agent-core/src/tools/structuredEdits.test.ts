import { describe, expect, it } from "vitest";

import {
  StructuredEditError,
  applyMultiEdit,
  applyNotebookEdit,
  parseEditList,
  parseNotebookEditMode,
  type TextEdit,
} from "./structuredEdits.js";

const edit = (oldString: string, newString: string, replaceAll = false): TextEdit => ({
  oldString,
  newString,
  replaceAll,
});

// -- parseEditList -----------------------------------------------------------

describe("parseEditList", () => {
  it("accepts the [CC] key spelling", () => {
    expect(parseEditList([{ old_string: "a", new_string: "b", replace_all: true }])).toEqual([
      { oldString: "a", newString: "b", replaceAll: true },
    ]);
  });

  it("accepts the Ovid fs_edit spelling (old_str/new_str)", () => {
    expect(parseEditList([{ old_str: "a", new_str: "b" }])).toEqual([
      { oldString: "a", newString: "b", replaceAll: false },
    ]);
  });

  it("treats a non-array as the exact StructuredEditError", () => {
    expect(() => parseEditList("edits")).toThrow(StructuredEditError);
    expect(() => parseEditList(null)).toThrow(
      "edits must be a non-empty array of {old_string, new_string}",
    );
  });

  it("treats an empty array as the exact StructuredEditError", () => {
    expect(() => parseEditList([])).toThrow(
      "edits must be a non-empty array of {old_string, new_string}",
    );
  });

  it("rejects a non-object element, naming its 1-based index", () => {
    expect(() => parseEditList([edit("a", "b"), "nope"])).toThrow("edit 2 is not an object");
  });
});

// -- applyMultiEdit ----------------------------------------------------------

describe("applyMultiEdit", () => {
  it("applies a single edit", () => {
    expect(applyMultiEdit("one two", [edit("one", "1")])).toBe("1 two");
  });

  it("applies edits sequentially, each on the previous result", () => {
    expect(applyMultiEdit("a b c", [edit("a", "x"), edit("x b", "y")])).toBe("y c");
  });

  it("is atomic: a failing edit throws naming the edit index and nothing is written", () => {
    expect(() =>
      applyMultiEdit("one two", [edit("one", "1"), edit("missing", "?")]),
    ).toThrow(StructuredEditError);
    expect(() =>
      applyMultiEdit("one two", [edit("one", "1"), edit("missing", "?")]),
    ).toThrow(/edit 2/);
  });

  it("zero occurrences throws naming the edit index", () => {
    expect(() => applyMultiEdit("abc", [edit("a", "1"), edit("zzz", "2")])).toThrow(
      /edit 2.*not found/,
    );
  });

  it("throws when old_string matches twice without replace_all", () => {
    expect(() => applyMultiEdit("x x", [edit("x", "y")])).toThrow(/matches 2 times/);
  });

  it("replaceAll: true replaces every occurrence", () => {
    expect(applyMultiEdit("x x", [edit("x", "y", true)])).toBe("y y");
  });

  it("rejects identical old and new strings", () => {
    expect(() => applyMultiEdit("x", [edit("x", "x")])).toThrow(/identical/);
  });

  it("create rule: empty content + a first edit with an empty old_string creates", () => {
    expect(applyMultiEdit("", [edit("", "hello\n"), edit("hello", "goodbye")])).toBe(
      "goodbye\n",
    );
  });

  it("an empty old_string after the first edit throws", () => {
    expect(() => applyMultiEdit("a", [edit("a", "b"), edit("", "c")])).toThrow(
      /must not be empty/,
    );
  });
});

// -- notebook edits ----------------------------------------------------------

const notebook = JSON.stringify({
  cells: [
    {
      cell_type: "markdown",
      id: "intro",
      metadata: { tags: ["title"] },
      source: ["# Title\n", "text"],
    },
    {
      cell_type: "code",
      id: "calc",
      metadata: { collapsed: false },
      execution_count: 3,
      outputs: [{ output_type: "stream", name: "stdout", text: ["2\n"] }],
      source: ["print(1 + 1)"],
    },
  ],
  metadata: { kernelspec: { name: "python3", display_name: "Python 3" } },
  nbformat: 4,
  nbformat_minor: 5,
});

const parseNb = (s: string) => JSON.parse(s) as Record<string, unknown>;

describe("parseNotebookEditMode", () => {
  it("defaults to replace for null/empty/undefined", () => {
    expect(parseNotebookEditMode(null)).toBe("replace");
    expect(parseNotebookEditMode("")).toBe("replace");
    expect(parseNotebookEditMode(undefined)).toBe("replace");
  });

  it("accepts insert and delete", () => {
    expect(parseNotebookEditMode("insert")).toBe("insert");
    expect(parseNotebookEditMode("delete")).toBe("delete");
  });

  it("rejects anything else with the pinned message", () => {
    expect(() => parseNotebookEditMode("swap")).toThrow(
      'edit_mode must be replace, insert or delete (got "swap")',
    );
  });
});

describe("applyNotebookEdit", () => {
  it("replace overwrites the target source and preserves its outputs and metadata", () => {
    const out = applyNotebookEdit(notebook, { cellId: "calc", newSource: "print(2)" });
    const nb = parseNb(out) as { cells: Array<Record<string, unknown>> };
    const calc = nb.cells.find((c) => c.id === "calc")!;
    expect(calc.source).toEqual(["print(2)"]);
    expect(calc.execution_count).toBe(3);
    expect(calc.outputs).toEqual([{ output_type: "stream", name: "stdout", text: ["2\n"] }]);
    expect(calc.metadata).toEqual({ collapsed: false });
    const intro = nb.cells.find((c) => c.id === "intro")!;
    expect(intro.source).toEqual(["# Title\n", "text"]);
    expect(out.endsWith("\n")).toBe(true);
  });

  it("cell_id may be a 0-based index or cell-N", () => {
    const byIndex = parseNb(
      applyNotebookEdit(notebook, { cellId: "0", newSource: "first" }),
    ) as { cells: Array<Record<string, unknown>> };
    expect(byIndex.cells[0].source).toEqual(["first"]);
    const byCellN = parseNb(
      applyNotebookEdit(notebook, { cellId: "cell-1", newSource: "second" }),
    ) as { cells: Array<Record<string, unknown>> };
    expect(byCellN.cells[1].source).toEqual(["second"]);
  });

  it("an unknown cell_id throws", () => {
    expect(() => applyNotebookEdit(notebook, { cellId: "nope", newSource: "x" })).toThrow(
      'cell_id "nope" not found in the notebook',
    );
  });

  it("replace without a cell_id throws", () => {
    expect(() => applyNotebookEdit(notebook, { newSource: "x" })).toThrow(
      /replace needs a cell_id/,
    );
  });

  it("changing cell_type code→markdown drops outputs and execution_count", () => {
    const nb = parseNb(
      applyNotebookEdit(notebook, { cellId: "calc", newSource: "prose", cellType: "markdown" }),
    ) as { cells: Array<Record<string, unknown>> };
    const calc = nb.cells.find((c) => c.id === "calc")!;
    expect(calc.cell_type).toBe("markdown");
    expect(calc.outputs).toBeUndefined();
    expect(calc.execution_count).toBeUndefined();
  });

  it("insert adds a new cell after the target, with an id when nbformat wants ids", () => {
    const nb = parseNb(
      applyNotebookEdit(notebook, {
        cellId: "intro",
        newSource: "new cell\n",
        cellType: "markdown",
        mode: "insert",
      }),
    ) as { cells: Array<Record<string, unknown>> };
    expect(nb.cells).toHaveLength(3);
    const inserted = nb.cells[1] as Record<string, unknown>;
    expect(inserted.cell_type).toBe("markdown");
    expect(typeof inserted.id).toBe("string");
    expect((inserted.id as string)).toMatch(/^[0-9a-f]{8}$/);
    expect(inserted.source).toEqual(["new cell\n"]);
    expect((nb.cells[2] as Record<string, unknown>).id).toBe("calc");
  });

  it("insert without a cell_id puts the cell first", () => {
    const nb = parseNb(
      applyNotebookEdit(notebook, { newSource: "top", cellType: "code", mode: "insert" }),
    ) as { cells: Array<Record<string, unknown>> };
    expect((nb.cells[0] as Record<string, unknown>).source).toEqual(["top"]);
    expect((nb.cells[0] as Record<string, unknown>).outputs).toEqual([]);
  });

  it("insert without cell_type throws", () => {
    expect(() =>
      applyNotebookEdit(notebook, { newSource: "x", mode: "insert" }),
    ).toThrow(/insert needs cell_type/);
  });

  it("delete removes the target cell; without a cell_id it throws", () => {
    const nb = parseNb(
      applyNotebookEdit(notebook, { cellId: "intro", newSource: "", mode: "delete" }),
    ) as { cells: Array<Record<string, unknown>> };
    expect(nb.cells).toHaveLength(1);
    expect((nb.cells[0] as Record<string, unknown>).id).toBe("calc");
    expect(() => applyNotebookEdit(notebook, { newSource: "", mode: "delete" })).toThrow(
      /delete needs a cell_id/,
    );
  });

  it("invalid JSON and non-notebook JSON each throw their pinned message", () => {
    expect(() => applyNotebookEdit("not json", { newSource: "x" })).toThrow(
      "not a valid .ipynb (invalid JSON)",
    );
    expect(() => applyNotebookEdit('{"a":1}', { newSource: "x" })).toThrow(
      "not a valid .ipynb (no cells array)",
    );
  });

  it("a bad cell_type throws before any cell lookup", () => {
    expect(() =>
      applyNotebookEdit(notebook, { cellId: "calc", newSource: "x", cellType: "ruby" }),
    ).toThrow('cell_type must be code or markdown (got "ruby")');
  });
});
