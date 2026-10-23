-- Rewrite the first-run plan rows from the seed the first deployment wrote
-- (`starter` $5/3x, `pro` $25/23x, `max` $60/43x) to the one table the
-- product now sells (`@ovid/shared` PLANS: free/go/plus/pro at 1x/1.5x/5x/20x
-- and $0/$5/$18/$99).
--
-- WHY A MIGRATION: the mint's seed is ADD-only — it writes the plan list only
-- when the `plans` table is empty, so an existing install keeps whatever the
-- first boot wrote forever. Changing packages/shared/src/plans.ts fixes new
-- installs only; this is the one-time repair for live rows.
--
-- THE MAPPING IS BY TIER, NOT BY ID:
--   starter (rank 1, $5/3x)   -> go    (rank 1, $5/1.5x)
--   pro     (rank 2, $25/23x) -> plus  (rank 2, $18/5x)
--   max     (rank 3, $60/43x) -> pro   (rank 3, $99/20x)
-- The old middle tier is the id `pro`; the new top tier reuses that id. A
-- blind `id` swap would turn every $25 customer into a $99 one (or the
-- reverse), so old `pro` is renamed to `plus` FIRST, which frees `pro` for
-- old `max`.
--
-- COLLIDING IDS: a row already carrying the target id may exist (a
-- half-migrated or hand-edited install). The canonical row — the one already
-- on the target id — WINS and the legacy duplicate is dropped. That cannot
-- strand an account: users.tier is a text tier (`3x`/`7x`/`15x`), resolved by
-- the mint's findPlan against plan ids OR aliases, and the canonical rewrite
-- below puts every legacy user's alias on the target row. No row references a
-- plan by foreign key.
--
-- `pro` DISCRIMINATOR: an `id = 'pro'` row is the OLD middle tier unless its
-- price is the new table's canonical `'99'` text (the mint writes
-- String(99), never a float spelling). Only one row can hold the id, so the
-- test is unambiguous. If a canonical `plus` already exists, the old middle
-- row is a duplicate and is deleted; otherwise it is renamed to `plus`.
--
-- `users` IS NOT TOUCHED. Its stored tier strings resolve through
-- `@ovid/shared` planFor() and through the aliases written below. Rewriting
-- them would change what a stored string means on the strength of an
-- assumption; carrying the aliases makes the rewrite unnecessary.
--
-- `enabled` and `window_hours` are operational state the shared table does not
-- carry. A rename preserves both; a canonical row that is already present
-- keeps its own. Nothing is INSERTed: an empty `plans` table stays empty so
-- the app's first-boot seed still runs (24h on a new install, 720h on an
-- existing one).
--
-- Redis is not touched here. The mint republishes `config:limits` from
-- Postgres at boot (projection.resyncAtBoot) and on the next settings write.

-- 1. Drop a legacy row when its target id is already taken. The `pro` probe
--    requires the canonical $99 price so the old middle row does not count as
--    its own target.
DELETE FROM "plans"
WHERE ("id" = 'starter' AND EXISTS (SELECT 1 FROM "plans" AS "t" WHERE "t"."id" = 'go'))
   OR ("id" = 'max' AND EXISTS (SELECT 1 FROM "plans" AS "t" WHERE "t"."id" = 'pro' AND "t"."price_usd" = '99'))
   OR ("id" = 'pro' AND "price_usd" <> '99'
       AND EXISTS (SELECT 1 FROM "plans" AS "t" WHERE "t"."id" = 'plus'));--> statement-breakpoint

-- 2. Move the survivors onto their new ids. Order matters: `pro` -> `plus`
--    frees `pro` before `max` takes it.
UPDATE "plans" SET "id" = 'plus' WHERE "id" = 'pro' AND "price_usd" <> '99';--> statement-breakpoint
UPDATE "plans" SET "id" = 'pro' WHERE "id" = 'max';--> statement-breakpoint
UPDATE "plans" SET "id" = 'go' WHERE "id" = 'starter';--> statement-breakpoint

-- 3. The shared table's names, prices, multipliers and aliases. Only rows
--    that exist are touched; `enabled` and `window_hours` are deliberately
--    not in the SET, so operational state survives the rename.
UPDATE "plans" SET "name" = 'Free', "price_usd" = '0', "aliases" = '[]'::jsonb,
  "mult" = '1', "slow_mode" = false, "auto_oss" = false, "position" = 0
WHERE "id" = 'free';--> statement-breakpoint
UPDATE "plans" SET "name" = 'Ovid Go', "price_usd" = '5', "aliases" = '["starter","3x"]'::jsonb,
  "mult" = '1.5', "slow_mode" = false, "auto_oss" = false, "position" = 1
WHERE "id" = 'go';--> statement-breakpoint
UPDATE "plans" SET "name" = 'Ovid Plus', "price_usd" = '18', "aliases" = '["7x"]'::jsonb,
  "mult" = '5', "slow_mode" = false, "auto_oss" = true, "position" = 2
WHERE "id" = 'plus';--> statement-breakpoint
UPDATE "plans" SET "name" = 'Ovid Pro', "price_usd" = '99', "aliases" = '["max","15x"]'::jsonb,
  "mult" = '20', "slow_mode" = false, "auto_oss" = true, "position" = 3
WHERE "id" = 'pro';
