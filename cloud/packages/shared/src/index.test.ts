import { expect, it } from "vitest";
import { PKG } from "./index.js";
it("shared package exports placeholder", () => expect(PKG).toBe("shared"));
