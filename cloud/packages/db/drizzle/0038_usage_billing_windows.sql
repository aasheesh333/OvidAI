CREATE TABLE IF NOT EXISTS "usage_quota_counters" (
	"actor_user_id" text NOT NULL,
	"window_kind" text NOT NULL,
	"window_start" timestamp (3) with time zone NOT NULL,
	"window_end" timestamp (3) with time zone NOT NULL,
	"used_tokens" bigint DEFAULT 0 NOT NULL,
	"reserved_tokens" bigint DEFAULT 0 NOT NULL,
	"used_usd" numeric(38, 10) DEFAULT '0' NOT NULL,
	"reserved_usd" numeric(38, 10) DEFAULT '0' NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "usage_quota_counters_actor_user_id_window_kind_window_start_pk" PRIMARY KEY("actor_user_id", "window_kind", "window_start"),
	CONSTRAINT "usage_quota_counters_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "usage_quota_counters_window_check" CHECK ("window_kind" IN ('day','month') AND "window_end" > "window_start"),
	CONSTRAINT "usage_quota_counters_tokens_check" CHECK ("used_tokens" >= 0 AND "reserved_tokens" >= 0),
	CONSTRAINT "usage_quota_counters_usd_check" CHECK ("used_usd" >= 0 AND "reserved_usd" >= 0)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "usage_run_admissions" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"actor_user_id" text NOT NULL,
	"source" text NOT NULL,
	"run_id" char(36) NOT NULL,
	"idempotency_key" text NOT NULL,
	"billing_class" text DEFAULT 'ovid_allowance' NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "usage_run_admissions_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "usage_run_admissions_source_check" CHECK ("source" IN ('interactive','schedule_create','schedule_run_now','schedule_tick','schedule_retry','parent_wake','subagent','collab'))
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "usage_quota_reservations" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"actor_user_id" text NOT NULL,
	"run_id" char(36) NOT NULL,
	"attempt_id" char(36),
	"session_id" char(36),
	"run_source" text,
	"reservation_key" text NOT NULL,
	"state" text DEFAULT 'reserved' NOT NULL,
	"input_tokens" bigint NOT NULL,
	"max_output_tokens" bigint NOT NULL,
	"reserved_cost_usd" numeric(38, 10) DEFAULT '0' NOT NULL,
	"requested_model" text,
	"provider_model" text,
	"actual_input_tokens" bigint,
	"actual_output_tokens" bigint,
	"actual_cache_read_tokens" bigint,
	"actual_cache_write_tokens" bigint,
	"cost_usd" numeric(38, 10),
	"cost_source" text,
	"billing_class" text DEFAULT 'ovid_allowance' NOT NULL,
	"day_window_start" timestamp (3) with time zone NOT NULL,
	"month_window_start" timestamp (3) with time zone NOT NULL,
	"run_usage_id" char(36),
	"reserved_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"settled_at" timestamp (3) with time zone,
	"released_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "usage_quota_reservations_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "usage_quota_reservations_state_check" CHECK ("state" IN ('reserved','settled','released')),
	CONSTRAINT "usage_quota_reservations_tokens_check" CHECK ("input_tokens" >= 0 AND "max_output_tokens" >= 0 AND ("actual_input_tokens" IS NULL OR "actual_input_tokens" >= 0) AND ("actual_output_tokens" IS NULL OR "actual_output_tokens" >= 0)),
	CONSTRAINT "usage_quota_reservations_usd_check" CHECK ("reserved_cost_usd" >= 0 AND ("cost_usd" IS NULL OR "cost_usd" >= 0))
);--> statement-breakpoint

ALTER TABLE "usage_run_admissions" ADD COLUMN IF NOT EXISTS "billing_class" text DEFAULT 'ovid_allowance' NOT NULL;--> statement-breakpoint
ALTER TABLE "usage_quota_reservations" ADD COLUMN IF NOT EXISTS "billing_class" text DEFAULT 'ovid_allowance' NOT NULL;--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "upload_window_counters" (
	"actor_user_id" text NOT NULL,
	"window_hours" integer NOT NULL,
	"window_start" timestamp (3) with time zone NOT NULL,
	"window_end" timestamp (3) with time zone NOT NULL,
	"used_uploads" integer DEFAULT 0 NOT NULL,
	"reserved_uploads" integer DEFAULT 0 NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "upload_window_counters_actor_user_id_window_hours_pk" PRIMARY KEY("actor_user_id", "window_hours"),
	CONSTRAINT "upload_window_counters_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "upload_window_counters_window_check" CHECK ("window_hours" > 0 AND "window_end" > "window_start"),
	CONSTRAINT "upload_window_counters_counts_check" CHECK ("used_uploads" >= 0 AND "reserved_uploads" >= 0)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "storage_usage_counters" (
	"owner_user_id" text PRIMARY KEY NOT NULL,
	"used_bytes" bigint DEFAULT 0 NOT NULL,
	"reserved_bytes" bigint DEFAULT 0 NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "storage_usage_counters_owner_user_id_users_uid_fk" FOREIGN KEY ("owner_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "storage_usage_counters_bytes_check" CHECK ("used_bytes" >= 0 AND "reserved_bytes" >= 0)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "storage_reservations" (
	"id" text PRIMARY KEY NOT NULL,
	"actor_user_id" text NOT NULL,
	"owner_user_id" text NOT NULL,
	"session_id" char(36) NOT NULL,
	"object_id" text,
	"state" text DEFAULT 'reserved' NOT NULL,
	"declared_bytes" bigint NOT NULL,
	"actual_bytes" bigint,
	"actual_content_type" text,
	"etag" text,
	"reserved_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"finalized_at" timestamp (3) with time zone,
	"released_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "storage_reservations_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "storage_reservations_owner_user_id_users_uid_fk" FOREIGN KEY ("owner_user_id") REFERENCES "users"("uid") ON DELETE cascade,
	CONSTRAINT "storage_reservations_state_check" CHECK ("state" IN ('reserved','finalized','released')),
	CONSTRAINT "storage_reservations_bytes_check" CHECK ("declared_bytes" >= 0 AND ("actual_bytes" IS NULL OR "actual_bytes" >= 0)),
	CONSTRAINT "storage_reservations_state_fields_check" CHECK (("state" = 'reserved' AND "actual_bytes" IS NULL AND "finalized_at" IS NULL AND "released_at" IS NULL) OR ("state" = 'finalized' AND "actual_bytes" IS NOT NULL AND "finalized_at" IS NOT NULL AND "released_at" IS NULL) OR ("state" = 'released' AND "actual_bytes" IS NULL AND "finalized_at" IS NULL AND "released_at" IS NOT NULL))
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "image_usage_facts" (
	"account" text NOT NULL,
	"request" text NOT NULL,
	"session_id" char(36),
	"run_id" char(36),
	"generate_count" integer,
	"edit_count" integer,
	"cost_usd" numeric(38, 10),
	CONSTRAINT "image_usage_facts_account_request_pk" PRIMARY KEY("account", "request"),
	CONSTRAINT "image_usage_facts_account_request_image_jobs_account_request_fk" FOREIGN KEY ("account", "request") REFERENCES "image_jobs"("account", "request") ON DELETE cascade,
	CONSTRAINT "image_usage_facts_counts_check" CHECK (("generate_count" IS NULL OR "generate_count" >= 0) AND ("edit_count" IS NULL OR "edit_count" >= 0)),
	CONSTRAINT "image_usage_facts_cost_check" CHECK ("cost_usd" IS NULL OR "cost_usd" >= 0)
);--> statement-breakpoint

ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "quota_reservation_id" char(36);--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "quota_call_id" text;--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "attempt_id" char(36);--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "requested_model" text;--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "provider_model" text;--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "cost_usd" numeric(38, 10);--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "cost_source" text;--> statement-breakpoint
ALTER TABLE "run_usage" ADD COLUMN IF NOT EXISTS "billing_class" text DEFAULT 'ovid_allowance' NOT NULL;--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "usage_run_admissions_actor_key_uq" ON "usage_run_admissions" ("actor_user_id", "idempotency_key");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "usage_run_admissions_run_idx" ON "usage_run_admissions" ("actor_user_id", "run_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "usage_quota_reservations_actor_key_uq" ON "usage_quota_reservations" ("actor_user_id", "reservation_key");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "usage_quota_reservations_actor_window_idx" ON "usage_quota_reservations" ("actor_user_id", "state", "day_window_start", "month_window_start");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "usage_quota_reservations_run_attempt_idx" ON "usage_quota_reservations" ("run_id", "attempt_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "upload_window_counters_actor_window_idx" ON "upload_window_counters" ("actor_user_id", "window_start", "window_end");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "storage_reservations_actor_state_window_idx" ON "storage_reservations" ("actor_user_id", "state", "reserved_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "storage_reservations_owner_state_idx" ON "storage_reservations" ("owner_user_id", "state");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "storage_reservations_session_idx" ON "storage_reservations" ("session_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "storage_reservations_object_idx" ON "storage_reservations" ("object_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_usage_session_created_idx" ON "run_usage" ("session_id", "created_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_usage_quota_reservation_uq" ON "run_usage" ("quota_reservation_id") WHERE "quota_reservation_id" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_usage_run_quota_call_uq" ON "run_usage" ("run_id", "quota_call_id") WHERE "quota_call_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "image_usage_facts_session_idx" ON "image_usage_facts" ("session_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "image_usage_facts_run_idx" ON "image_usage_facts" ("run_id");--> statement-breakpoint

-- Existing run_usage remains the actual ledger. Backfill only its evidenced
-- token/cost sums; unknown costs stay NULL on the ledger and contribute no
-- fabricated amount to the numeric counter.
INSERT INTO "usage_quota_counters"
	("actor_user_id", "window_kind", "window_start", "window_end",
	 "used_tokens", "reserved_tokens", "used_usd", "reserved_usd")
SELECT
	"usage_by_day"."user_id",
	'day',
	"usage_by_day"."day_start",
	"usage_by_day"."day_start" + interval '1 day',
	sum("usage_by_day"."input_tokens" + "usage_by_day"."output_tokens"),
	0,
	sum(COALESCE("usage_by_day"."cost_usd", 0)),
	0
FROM (
	SELECT
		"user_id", "input_tokens", "output_tokens", "cost_usd",
		(date_trunc('day', "created_at" AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS "day_start"
	FROM "run_usage"
) AS "usage_by_day"
INNER JOIN "users" ON "users"."uid" = "usage_by_day"."user_id"
GROUP BY "usage_by_day"."user_id", "usage_by_day"."day_start"
ON CONFLICT ("actor_user_id", "window_kind", "window_start") DO NOTHING;--> statement-breakpoint

INSERT INTO "usage_quota_counters"
	("actor_user_id", "window_kind", "window_start", "window_end",
	 "used_tokens", "reserved_tokens", "used_usd", "reserved_usd")
SELECT
	"usage_by_month"."user_id",
	'month',
	"usage_by_month"."month_start",
	"usage_by_month"."month_start" + interval '1 month',
	sum("usage_by_month"."input_tokens" + "usage_by_month"."output_tokens"),
	0,
	sum(COALESCE("usage_by_month"."cost_usd", 0)),
	0
FROM (
	SELECT
		"user_id", "input_tokens", "output_tokens", "cost_usd",
		(date_trunc('month', "created_at" AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS "month_start"
	FROM "run_usage"
) AS "usage_by_month"
INNER JOIN "users" ON "users"."uid" = "usage_by_month"."user_id"
GROUP BY "usage_by_month"."user_id", "usage_by_month"."month_start"
ON CONFLICT ("actor_user_id", "window_kind", "window_start") DO NOTHING;--> statement-breakpoint

CREATE OR REPLACE FUNCTION "ovid_record_run_usage_quota_0038"() RETURNS trigger AS $$
DECLARE
	"day_start" timestamptz;
	"day_end" timestamptz;
	"month_start" timestamptz;
	"month_end" timestamptz;
BEGIN
	-- BYOK is actual actor telemetry, but it never spends Ovid allowance.
	IF NEW."billing_class" = 'byok' THEN
		RETURN NEW;
	END IF;
	-- Preserve the legacy ledger's ability to record an already-deleted user.
	-- Such a user cannot acquire a new quota reservation in any case.
	IF NOT EXISTS (SELECT 1 FROM "users" WHERE "uid" = NEW."user_id") THEN
		RETURN NEW;
	END IF;
	"day_start" := date_trunc('day', NEW."created_at" AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
	"day_end" := "day_start" + interval '1 day';
	"month_start" := date_trunc('month', NEW."created_at" AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
	"month_end" := "month_start" + interval '1 month';

	INSERT INTO "usage_quota_counters"
		("actor_user_id", "window_kind", "window_start", "window_end",
		 "used_tokens", "used_usd")
	VALUES
		(NEW."user_id", 'day', "day_start", "day_end",
		 NEW."input_tokens" + NEW."output_tokens", COALESCE(NEW."cost_usd", 0))
	ON CONFLICT ("actor_user_id", "window_kind", "window_start") DO UPDATE SET
		"used_tokens" = "usage_quota_counters"."used_tokens" + EXCLUDED."used_tokens",
		"used_usd" = "usage_quota_counters"."used_usd" + EXCLUDED."used_usd",
		"updated_at" = now();

	INSERT INTO "usage_quota_counters"
		("actor_user_id", "window_kind", "window_start", "window_end",
		 "used_tokens", "used_usd")
	VALUES
		(NEW."user_id", 'month', "month_start", "month_end",
		 NEW."input_tokens" + NEW."output_tokens", COALESCE(NEW."cost_usd", 0))
	ON CONFLICT ("actor_user_id", "window_kind", "window_start") DO UPDATE SET
		"used_tokens" = "usage_quota_counters"."used_tokens" + EXCLUDED."used_tokens",
		"used_usd" = "usage_quota_counters"."used_usd" + EXCLUDED."used_usd",
		"updated_at" = now();
	RETURN NEW;
END;
$$ LANGUAGE plpgsql;--> statement-breakpoint

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM "pg_trigger"
		WHERE "tgname" = 'run_usage_quota_counters_0038'
		  AND "tgrelid" = 'run_usage'::regclass
	) THEN
		CREATE TRIGGER "run_usage_quota_counters_0038"
		AFTER INSERT ON "run_usage"
		FOR EACH ROW EXECUTE FUNCTION "ovid_record_run_usage_quota_0038"();
	END IF;
END;
$$;
