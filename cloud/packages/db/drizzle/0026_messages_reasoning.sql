-- "Show reasoning" needs somewhere to keep the provider's thinking for an
-- assistant turn. It is deliberately a separate nullable column rather than
-- part of `content`: the answer the user reads, full-text search and the
-- compaction ledger must never see it, and the client decides whether to
-- render it (UserPreferences.showReasoning).
--
-- NULL means "this row has no reasoning" — every user/system/tool row, every
-- assistant row written before this migration, and any model that returns
-- none. No backfill and no default: absence is the honest value.
ALTER TABLE "messages" ADD COLUMN "reasoning" text;
