CREATE TABLE IF NOT EXISTS "billing_entitlement_events" (
	"event_id" text PRIMARY KEY NOT NULL,
	"user_id" text,
	"product_id" text,
	"tier" text,
	"period" text,
	"purchase_state" text NOT NULL,
	"event_type" text NOT NULL,
	"expires_at" timestamp (3) with time zone,
	"occurred_at" timestamp (3) with time zone,
	"received_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "billing_entitlement_events_period_check" CHECK ("billing_entitlement_events"."period" IN ('monthly','yearly'))
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "run_outbox" (
	"outbox_id" char(36) PRIMARY KEY NOT NULL,
	"actor_user_id" text NOT NULL,
	"session_id" char(36) NOT NULL,
	"run_id" char(36) NOT NULL,
	"user_message_id" char(36) NOT NULL,
	"idempotency_key" text NOT NULL,
	"status" text DEFAULT 'queued' NOT NULL,
	"request_payload" jsonb NOT NULL,
	"body_payload" jsonb NOT NULL,
	"job_id" text NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"published_at" timestamp (3) with time zone,
	"last_attempt_at" timestamp (3) with time zone,
	"settled_at" timestamp (3) with time zone,
	"last_error" text,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "run_outbox_status_check" CHECK ("run_outbox"."status" IN ('queued','published','settled','failed')),
	CONSTRAINT "run_outbox_attempts_check" CHECK ("run_outbox"."attempts" >= 0)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "system_request_responses" (
	"response_id" char(36) PRIMARY KEY NOT NULL,
	"request_id" text NOT NULL,
	"user_id" text NOT NULL,
	"request_version" integer NOT NULL,
	"client_response_id" text NOT NULL,
	"response" jsonb,
	"response_digest" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "system_request_responses_version_check" CHECK ("system_request_responses"."request_version" > 0),
	CONSTRAINT "system_request_responses_digest_check" CHECK ("system_request_responses"."response_digest" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "system_requests" (
	"request_id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"session_id" char(36) NOT NULL,
	"run_id" char(36) NOT NULL,
	"kind" text NOT NULL,
	"safe_payload" jsonb NOT NULL,
	"sensitive" boolean NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "system_requests_kind_check" CHECK ("system_requests"."kind" IN ('approval','sampling','elicitation')),
	CONSTRAINT "system_requests_status_check" CHECK ("system_requests"."status" IN ('pending','resolved','expired','cancelled')),
	CONSTRAINT "system_requests_version_check" CHECK ("system_requests"."version" > 0)
);
--> statement-breakpoint
ALTER TABLE "billing_purchases" ADD COLUMN IF NOT EXISTS "period" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "response_wait_seconds" integer DEFAULT 45 NOT NULL;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'run_outbox_actor_user_id_users_uid_fk' AND conrelid = 'run_outbox'::regclass) THEN
    ALTER TABLE "run_outbox" ADD CONSTRAINT "run_outbox_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'run_outbox_session_id_sessions_id_fk' AND conrelid = 'run_outbox'::regclass) THEN
    ALTER TABLE "run_outbox" ADD CONSTRAINT "run_outbox_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'run_outbox_run_id_runs_id_fk' AND conrelid = 'run_outbox'::regclass) THEN
    ALTER TABLE "run_outbox" ADD CONSTRAINT "run_outbox_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'run_outbox_user_message_id_messages_id_fk' AND conrelid = 'run_outbox'::regclass) THEN
    ALTER TABLE "run_outbox" ADD CONSTRAINT "run_outbox_user_message_id_messages_id_fk" FOREIGN KEY ("user_message_id") REFERENCES "public"."messages"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_request_responses_request_id_system_requests_request_id_fk' AND conrelid = 'system_request_responses'::regclass) THEN
    ALTER TABLE "system_request_responses" ADD CONSTRAINT "system_request_responses_request_id_system_requests_request_id_fk" FOREIGN KEY ("request_id") REFERENCES "public"."system_requests"("request_id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_request_responses_user_id_users_uid_fk' AND conrelid = 'system_request_responses'::regclass) THEN
    ALTER TABLE "system_request_responses" ADD CONSTRAINT "system_request_responses_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_requests_user_id_users_uid_fk' AND conrelid = 'system_requests'::regclass) THEN
    ALTER TABLE "system_requests" ADD CONSTRAINT "system_requests_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_requests_session_id_sessions_id_fk' AND conrelid = 'system_requests'::regclass) THEN
    ALTER TABLE "system_requests" ADD CONSTRAINT "system_requests_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'system_requests_run_id_runs_id_fk' AND conrelid = 'system_requests'::regclass) THEN
    ALTER TABLE "system_requests" ADD CONSTRAINT "system_requests_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "billing_entitlement_events_user_received_idx" ON "billing_entitlement_events" USING btree ("user_id","received_at","event_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_outbox_actor_idempotency_uq" ON "run_outbox" USING btree ("actor_user_id","idempotency_key");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_outbox_job_uq" ON "run_outbox" USING btree ("job_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_outbox_run_uq" ON "run_outbox" USING btree ("run_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_outbox_message_uq" ON "run_outbox" USING btree ("user_message_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_outbox_status_idx" ON "run_outbox" USING btree ("status","created_at","outbox_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_outbox_status_attempt_idx" ON "run_outbox" USING btree ("status","last_attempt_at","created_at","outbox_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "system_request_responses_request_version_uq" ON "system_request_responses" USING btree ("request_id","request_version");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "system_request_responses_client_response_uq" ON "system_request_responses" USING btree ("user_id","client_response_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "system_requests_user_status_idx" ON "system_requests" USING btree ("user_id","status","expires_at","created_at","request_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "system_requests_session_status_idx" ON "system_requests" USING btree ("session_id","status","expires_at","created_at","request_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "system_requests_run_idx" ON "system_requests" USING btree ("run_id");--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_purchases_period_check' AND conrelid = 'billing_purchases'::regclass) THEN
    ALTER TABLE "billing_purchases" ADD CONSTRAINT "billing_purchases_period_check" CHECK ("billing_purchases"."period" IN ('monthly','yearly'));
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_response_wait_seconds_check' AND conrelid = 'users'::regclass) THEN
    ALTER TABLE "users" ADD CONSTRAINT "users_response_wait_seconds_check" CHECK ("users"."response_wait_seconds" BETWEEN 15 AND 600);
  END IF;
END
$$;
