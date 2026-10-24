ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "content_type" text DEFAULT 'application/octet-stream' NOT NULL;--> statement-breakpoint
ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "upload_status" text DEFAULT 'pending' NOT NULL;--> statement-breakpoint
ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "actual_bytes" bigint;--> statement-breakpoint
ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "actual_content_type" text;--> statement-breakpoint
ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "finalized_at" timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "provider_id" text;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "agent_enabled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "auth_state" text DEFAULT 'unknown' NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "health_state" text DEFAULT 'never_checked' NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "last_checked_at" timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "last_success_at" timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "config_version" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "disconnect_generation" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "approved_source_id" text;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "approved_digest" text;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD COLUMN IF NOT EXISTS "normalized_connection_name" text;--> statement-breakpoint
UPDATE "mcp_servers" SET "provider_id" = "curated_id" WHERE "provider_id" IS NULL AND "curated_id" IS NOT NULL;--> statement-breakpoint
UPDATE "mcp_servers" SET "normalized_connection_name" = lower(btrim("name")) WHERE "normalized_connection_name" IS NULL;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "mcp_servers_curated_provider_uq" ON "mcp_servers" USING btree ("user_id",COALESCE("provider_id", "curated_id")) WHERE "mcp_servers"."curated_id" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "mcp_servers_custom_identity_uq" ON "mcp_servers" USING btree ("user_id",COALESCE("normalized_connection_name", lower(btrim("name"))),COALESCE("approved_source_id", "approved_digest", '')) WHERE "mcp_servers"."curated_id" IS NULL;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'attachments_upload_status_check'
      AND conrelid = 'attachments'::regclass
  ) THEN
    ALTER TABLE "attachments" ADD CONSTRAINT "attachments_upload_status_check"
      CHECK ("attachments"."upload_status" IN ('pending','ready','failed'));
  END IF;
END
$$;
