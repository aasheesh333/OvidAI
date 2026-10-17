import { describe, expect, it } from "vitest";
import { isNonPublicAddress } from "./address.js";

// P9-T11 fix round 1 (review M2). The five forms below were classified SAFE by
// the route's former local classifier and are deliberately rejected by the
// canonical (agent-core) table. They are pinned here so the shared helper
// cannot regress, and the gateway route test asserts each is refused before a
// fetch.
describe("isNonPublicAddress — forms the former route classifier missed", () => {
  it.each([
    ["NAT64 64:ff9b::/96", "64:ff9b::7f00:1"],
    ["6to4 2002::/16", "2002:7f00:1::"],
    ["IPv4-compatible ::a.b.c.d", "::7f00:1"],
    ["site-local fec0::/10", "fec0::1"],
    ["multicast ff00::/8", "ff02::1"],
  ])("rejects %s (%s)", (_label, address) => {
    expect(isNonPublicAddress(address)).toBe(true);
  });
});

describe("isNonPublicAddress — ordinary classification", () => {
  it.each([
    "0.0.0.0",
    "10.1.2.3",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "192.0.0.1",
    "192.168.1.1",
    "198.18.0.1",
    "224.0.0.1",
    "::",
    "::1",
    "fc00::1",
    "fe80::1",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    "64:ff9b::a9fe:a9fe",
    "2002:a9fe:a9fe::",
  ])("rejects non-public %s", (address) => {
    expect(isNonPublicAddress(address)).toBe(true);
  });

  it.each([
    "93.184.216.34",
    "8.8.8.8",
    "1.1.1.1",
    "2606:2800:220:1:248:1893:25c8:1946",
    "64:ff9b::0808:0808", // NAT64-embedded 8.8.8.8 is public
    "2002:0808:0808::", // 6to4-embedded 8.8.8.8 is public
  ])("accepts public %s", (address) => {
    expect(isNonPublicAddress(address)).toBe(false);
  });

  it("fails closed on unparseable input", () => {
    expect(isNonPublicAddress("not-an-ip")).toBe(true);
    expect(isNonPublicAddress("")).toBe(true);
  });

  it("accepts bracketed and trailing-dot forms", () => {
    expect(isNonPublicAddress("[::1]")).toBe(true);
    expect(isNonPublicAddress("10.0.0.1.")).toBe(true);
  });
});
