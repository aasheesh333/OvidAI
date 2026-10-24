-- Only one worker may own a pending delivery claim at a time. The claimant is
-- a unique delivery-attempt id; pending remains retryable when that attempt fails.
ALTER TABLE "notification_delivery_claims" ADD COLUMN IF NOT EXISTS "claimant" text;
