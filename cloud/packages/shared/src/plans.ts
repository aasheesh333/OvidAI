/**
 * The plan table, in one place.
 *
 * Before this file the same four plans existed in three shapes that disagreed:
 * the product spec (1.5× / 5× / 20×), the mint's seed (`mult: 3 / 23 / 43`,
 * `price_usd: 5 / 25 / 60`) and the web plan screen (`$5 / $18 / $99`). The
 * gateway and the client now read THIS, so a screen cannot advertise an
 * allowance the server does not honour.
 *
 * Prices are the product's: USD is the store price and INR is what the Indian
 * Play Store charges. They are not conversions of each other.
 */

/** The four tiers, cheapest first. Order is meaningful (upgrade paths). */
export const PLAN_TIERS = ["free", "go", "plus", "pro"] as const;
export type PlanTier = (typeof PLAN_TIERS)[number];

export interface PlanDefinition {
  id: PlanTier;
  /** Product name, as the store and the plan screen show it. */
  name: string;
  /** Store price in US dollars. */
  priceUsd: number;
  /** Store price in Indian rupees. */
  priceInr: number;
  /** R2 quota in gigabytes. */
  storageGb: number;
  /**
   * How much more of the paid allowance the automatic router may spend than
   * the free baseline. `1` is the baseline itself.
   */
  autoMultiplier: number;
  /**
   * True when the person may choose a specific model instead of `auto`.
   *
   * Free and Go are auto-only: the router picks a model the plan can afford.
   * Letting them pin a premium model would let one request spend the month.
   */
  manualModels: boolean;
  /** Custom connectors (MCP servers) the plan may keep. */
  customConnectors: number;
  /** Files one project may hold. */
  projectFiles: number;
  /** Upload allowance, as a count inside a rolling window. */
  uploads: { count: number; windowHours: number };
}

export const PLANS: Readonly<Record<PlanTier, PlanDefinition>> = Object.freeze({
  free: Object.freeze({
    id: "free",
    name: "Free",
    priceUsd: 0,
    priceInr: 0,
    storageGb: 3,
    autoMultiplier: 1,
    manualModels: false,
    customConnectors: 0,
    projectFiles: 80,
    uploads: { count: 50, windowHours: 24 },
  }),
  go: Object.freeze({
    id: "go",
    name: "Ovid Go",
    priceUsd: 5,
    priceInr: 499,
    storageGb: 5,
    autoMultiplier: 1.5,
    manualModels: false,
    customConnectors: 5,
    projectFiles: 100,
    uploads: { count: 80, windowHours: 3 },
  }),
  plus: Object.freeze({
    id: "plus",
    name: "Ovid Plus",
    priceUsd: 18,
    priceInr: 1799,
    storageGb: 15,
    autoMultiplier: 5,
    manualModels: true,
    customConnectors: 20,
    projectFiles: 150,
    uploads: { count: 80, windowHours: 3 },
  }),
  pro: Object.freeze({
    id: "pro",
    name: "Ovid Pro",
    priceUsd: 99,
    priceInr: 9999,
    storageGb: 75,
    autoMultiplier: 20,
    manualModels: true,
    customConnectors: 20,
    projectFiles: 250,
    uploads: { count: 80, windowHours: 3 },
  }),
});

/**
 * Legacy ids that used to mean a plan.
 *
 * The mint seeded `starter` / `pro` / `max` and nothing ever wrote a tier, so
 * no account is on one of these — but a row could exist from a manual edit or
 * an older deployment, and reading it as "free" would silently take away a
 * paying user's allowance. `pro` and `max` are both paid tiers with manual
 * models, so mapping them to the paid side is the safe direction.
 *
 * `3x` / `7x` / `15x` are the aliases the mint actually stored: `storedTier`
 * returned `aliases[0]`, and those three were the first alias of every paid
 * plan. They are the values real `users.tier` rows hold, so resolving them is
 * what makes a paying account read as paying.
 */
const LEGACY_TIERS: Readonly<Record<string, PlanTier>> = Object.freeze({
  starter: "go",
  max: "pro",
  "3x": "go",
  "7x": "plus",
  "15x": "pro",
});

/**
 * The plan for a stored tier string.
 *
 * An unknown tier is Free. That is the safe default: it grants the least, and
 * a typo must never hand out a paid allowance.
 */
export function planFor(tier: string | null | undefined): PlanDefinition {
  const key = (tier ?? "").trim().toLowerCase();
  const direct = PLANS[key as PlanTier];
  if (direct !== undefined) return direct;
  const legacy = LEGACY_TIERS[key];
  if (legacy !== undefined) return PLANS[legacy];
  return PLANS.free;
}

/** True when this tier may pin a model instead of letting the router choose. */
export function manualModelsAllowed(tier: string | null | undefined): boolean {
  return planFor(tier).manualModels;
}

/**
 * Whether a send from this tier may name `model`.
 *
 * `auto` (and an absent value) is always allowed — it is the router's own
 * choice. Anything else is a manual pick and needs the plan for it.
 */
export function modelAllowedForTier(
  tier: string | null | undefined,
  model: string | null | undefined,
): boolean {
  const requested = (model ?? "").trim().toLowerCase();
  if (requested === "" || requested === "auto") return true;
  return manualModelsAllowed(tier);
}

/** Storage quota in bytes, for the storage screen's percentage. */
export function storageBytes(tier: string | null | undefined): number {
  return planFor(tier).storageGb * 1024 ** 3;
}

/**
 * Position of a tier in the table, cheapest first (Free is 0).
 *
 * Billing uses this to decide which of two purchases wins and which plan an
 * account keeps, so a legacy spelling MUST rank the same as the tier it
 * means — `7x` and `plus` are both 2. An unknown tier ranks as Free, which
 * is the safe direction: it can never outrank a plan someone paid for.
 */
export function tierRank(tier: string | null | undefined): number {
  return PLAN_TIERS.indexOf(planFor(tier).id);
}
