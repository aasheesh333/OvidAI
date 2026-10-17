CREATE TABLE "account_deletions" (
	"uid" text PRIMARY KEY NOT NULL,
	"state" text NOT NULL,
	"delete_after" bigint NOT NULL,
	"record" jsonb NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "billing_purchases" (
	"token" text PRIMARY KEY NOT NULL,
	"uid" text,
	"product_id" text NOT NULL,
	"tier" text NOT NULL,
	"status" text NOT NULL,
	"expires_at" bigint,
	"auto_renewing" boolean DEFAULT false NOT NULL,
	"linked_token" text,
	"account_hash" text,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "byok_keys" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"provider_id" text NOT NULL,
	"endpoint" text NOT NULL,
	"label" text,
	"wrapped_dek" text NOT NULL,
	"iv" text NOT NULL,
	"ciphertext" text NOT NULL,
	"tag" text NOT NULL,
	"status" text DEFAULT 'active' NOT NULL,
	"last_test_at" timestamp (3) with time zone,
	"last_test_ok" boolean,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "image_card_history" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"model" text NOT NULL,
	"fingerprint" text NOT NULL,
	"state" text NOT NULL,
	"card" jsonb NOT NULL,
	"at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "image_cards" (
	"model" text PRIMARY KEY NOT NULL,
	"fingerprint" text NOT NULL,
	"state" text NOT NULL,
	"card" jsonb NOT NULL,
	"priced" boolean,
	"edit_transport" text,
	"updated_at" bigint NOT NULL,
	"probed_at" bigint
);
--> statement-breakpoint
CREATE TABLE "image_deleted_accounts" (
	"account" text PRIMARY KEY NOT NULL,
	"deleted_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "image_jobs" (
	"account" text NOT NULL,
	"request" text NOT NULL,
	"fingerprint" text NOT NULL,
	"state" text NOT NULL,
	"reserved" text NOT NULL,
	"charged" text DEFAULT '0' NOT NULL,
	"actual" text,
	"response" jsonb,
	"served_model" text,
	"budget_window" text NOT NULL,
	"replay_until" bigint,
	"receipt_until" bigint,
	"created_at" bigint NOT NULL,
	CONSTRAINT "image_jobs_account_request_pk" PRIMARY KEY("account","request")
);
--> statement-breakpoint
CREATE TABLE "image_probe_log" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"model" text NOT NULL,
	"probe" text NOT NULL,
	"ok" boolean NOT NULL,
	"error_class" text,
	"latency_ms" integer,
	"cost_usd" text NOT NULL,
	"at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "image_probe_state" (
	"model" text PRIMARY KEY NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"next_attempt_at" bigint NOT NULL,
	"last_error" text
);
--> statement-breakpoint
CREATE TABLE "mint_audit" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"actor" text NOT NULL,
	"action" text NOT NULL,
	"target" jsonb,
	"before" jsonb,
	"after" jsonb,
	"ip" text
);
--> statement-breakpoint
CREATE TABLE "mint_settings" (
	"id" integer PRIMARY KEY DEFAULT 1 NOT NULL,
	"base_daily_usd" text NOT NULL,
	"scalars" jsonb NOT NULL,
	"auto_oss_members" jsonb NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "plans" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"price_usd" text NOT NULL,
	"enabled" boolean NOT NULL,
	"aliases" jsonb NOT NULL,
	"window_hours" integer NOT NULL,
	"mult" text NOT NULL,
	"slow_mode" boolean NOT NULL,
	"auto_oss" boolean NOT NULL,
	"position" integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE "reports" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"reporter_uid" text NOT NULL,
	"request_id" text NOT NULL,
	"kind" text NOT NULL,
	"reason" text NOT NULL,
	"details" text NOT NULL,
	"excerpt" text NOT NULL,
	"target_id" text,
	"model" text,
	"status" text DEFAULT 'open' NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "share_forks" (
	"token" char(43) NOT NULL,
	"recipient_uid" text NOT NULL,
	"request_id" text NOT NULL,
	"session_id" text NOT NULL,
	"created_at" timestamp (3) with time zone NOT NULL,
	CONSTRAINT "share_forks_token_recipient_uid_request_id_pk" PRIMARY KEY("token","recipient_uid","request_id")
);
--> statement-breakpoint
CREATE TABLE "shares" (
	"token" char(43) PRIMARY KEY NOT NULL,
	"owner_uid" text NOT NULL,
	"session_id" text NOT NULL,
	"request_id" text NOT NULL,
	"content" jsonb,
	"message_count" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) with time zone NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"revoked_at" timestamp (3) with time zone,
	"purged_at" timestamp (3) with time zone,
	"fork_of_token" char(43)
);
--> statement-breakpoint
CREATE TABLE "user_plan_overrides" (
	"uid" text PRIMARY KEY NOT NULL,
	"daily_usd" text,
	"monthly_cap_usd" text,
	"pools" jsonb,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "tier_expires_at" timestamp (3) with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "banned_reason" text;--> statement-breakpoint
ALTER TABLE "byok_keys" ADD CONSTRAINT "byok_keys_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_plan_overrides" ADD CONSTRAINT "user_plan_overrides_uid_users_uid_fk" FOREIGN KEY ("uid") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "billing_purchases_uid_idx" ON "billing_purchases" USING btree ("uid");--> statement-breakpoint
CREATE INDEX "byok_keys_user_id_idx" ON "byok_keys" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "image_card_history_model_at_idx" ON "image_card_history" USING btree ("model","at");--> statement-breakpoint
CREATE INDEX "image_jobs_replay_until_idx" ON "image_jobs" USING btree ("replay_until") WHERE replay_until IS NOT NULL;--> statement-breakpoint
CREATE INDEX "image_jobs_receipt_until_idx" ON "image_jobs" USING btree ("receipt_until") WHERE receipt_until IS NOT NULL;--> statement-breakpoint
CREATE INDEX "image_probe_log_at_idx" ON "image_probe_log" USING btree ("at");--> statement-breakpoint
CREATE UNIQUE INDEX "reports_reporter_request_idx" ON "reports" USING btree ("reporter_uid","request_id");--> statement-breakpoint
CREATE INDEX "reports_status_created_idx" ON "reports" USING btree ("status","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "shares_owner_request_idx" ON "shares" USING btree ("owner_uid","request_id");--> statement-breakpoint
CREATE INDEX "shares_owner_idx" ON "shares" USING btree ("owner_uid");--> statement-breakpoint
CREATE INDEX "shares_expiry_idx" ON "shares" USING btree ("expires_at") WHERE content IS NOT NULL;