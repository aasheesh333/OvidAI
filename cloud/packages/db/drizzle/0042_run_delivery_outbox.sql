-- Crash-safe final-response delivery (root runs).
--
-- One row per root run, committed in the SAME transaction as the final
-- assistant message. The row is the durable delivery intent: after the commit
-- the answer exists and its message_completed / run_completed / completion
-- push are replayed until confirmed; before the commit neither the answer nor
-- the intent exists (no phantom answer). `run_id` is the stable identity, so
-- replay can never append a second assistant row or a second notification.
CREATE TABLE IF NOT EXISTS "run_delivery_outbox" (
	"outbox_id" char(36) PRIMARY KEY NOT NULL,
	"run_id" char(36) NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"message_id" char(36) NOT NULL,
	"scheduled" boolean DEFAULT false NOT NULL,
	"completion_payload" jsonb NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_attempt_at" timestamp (3) with time zone,
	"delivered_at" timestamp (3) with time zone,
	"last_error" text,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "run_delivery_outbox_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "run_delivery_outbox_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "run_delivery_outbox_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "run_delivery_outbox_message_id_messages_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "run_delivery_outbox_status_check" CHECK ("run_delivery_outbox"."status" IN ('pending','delivering','delivered','failed')),
	CONSTRAINT "run_delivery_outbox_attempts_check" CHECK ("run_delivery_outbox"."attempts" >= 0)
);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_delivery_outbox_run_uq" ON "run_delivery_outbox" USING btree ("run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_delivery_outbox_status_idx" ON "run_delivery_outbox" USING btree ("status","last_attempt_at","created_at");--> statement-breakpoint
-- A dead worker must not hold a completion claim forever: the lease makes an
-- abandoned in-progress fan-out reclaimable (the claim itself still prevents a
-- live duplicate send).
ALTER TABLE "notification_delivery_claims" ADD COLUMN IF NOT EXISTS "claimed_at" timestamp (3) with time zone;
