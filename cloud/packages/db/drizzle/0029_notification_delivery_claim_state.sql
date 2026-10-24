-- Notification claims are retryable until the whole fan-out completes.
-- Existing pending rows from the initial claim-only migration remain pending.
ALTER TABLE "notification_delivery_claims"
  ADD COLUMN IF NOT EXISTS "state" text NOT NULL DEFAULT 'pending';
