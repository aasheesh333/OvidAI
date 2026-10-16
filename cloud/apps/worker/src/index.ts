// Public surface: the pieces Task 10's e2e composes (main.ts stays out — it is
// the process entry point, not a library module). The PKG placeholder from the
// repo scaffold is dropped: nothing ever imported it.
export * from "./liteLlm.js";
export * from "./runProcessor.js";
