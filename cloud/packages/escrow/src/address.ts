// SSRF address classification — shared by the BYOK probe (P9 Task 11 fix
// round 1, review M2).
//
// This used to be a copy of the canonical `isNonPublicAddress` table from
// `@ovid/agent-core`. It now re-exports the ONE implementation from
// `@ovid/shared` (`netAddress.ts`), so adding a reserved prefix is a
// single-file change. Keep this module so the package barrel and
// `address.test.ts` keep resolving.

export { isNonPublicAddress } from "@ovid/shared";
