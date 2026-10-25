CREATE TABLE IF NOT EXISTS "subagent_attempts" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"logical_worker_id" char(36) NOT NULL,
	"session_id" char(36) NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"execution_epoch" integer NOT NULL,
	"attempt_number" integer NOT NULL,
	"child_session_id" char(36) NOT NULL,
	"child_run_id" char(36) NOT NULL,
	"prompt_message_id" char(36) NOT NULL,
	"status" text NOT NULL,
	"admitted_at" timestamp (3) with time zone NOT NULL,
	"started_at" timestamp (3) with time zone NOT NULL,
	"ended_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_attempts_child_run_id_unique" UNIQUE("child_run_id"),
	CONSTRAINT "subagent_attempts_status_check" CHECK ("subagent_attempts"."status" IN ('running','completed','failed','cancelled','timeout')),
	CONSTRAINT "subagent_attempts_number_check" CHECK ("subagent_attempts"."attempt_number" > 0 AND "subagent_attempts"."execution_epoch" > 0),
	CONSTRAINT "subagent_attempts_times_check" CHECK ("subagent_attempts"."started_at" >= "subagent_attempts"."admitted_at" AND ("subagent_attempts"."ended_at" IS NULL OR "subagent_attempts"."ended_at" >= "subagent_attempts"."started_at"))
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_batches" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"parent_run_id" char(36) NOT NULL,
	"requested_at" timestamp (3) with time zone NOT NULL,
	"request_count" integer NOT NULL,
	"admitted_count" integer DEFAULT 0 NOT NULL,
	"deferred_count" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_batches_counts_check" CHECK ("subagent_batches"."request_count" >= 0 AND "subagent_batches"."admitted_count" >= 0 AND "subagent_batches"."deferred_count" >= 0 AND "subagent_batches"."admitted_count" + "subagent_batches"."deferred_count" <= "subagent_batches"."request_count")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_checkpoints" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"logical_worker_id" char(36) NOT NULL,
	"attempt_id" char(36) NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"hash" text NOT NULL,
	"object_ref" text,
	"provenance" jsonb,
	"verified_at" timestamp (3) with time zone NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_control_audit" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"actor_run_id" char(36) NOT NULL,
	"root_task_run_id" char(36),
	"logical_worker_id" char(36),
	"source_attempt_id" char(36),
	"target_logical_worker_id" char(36),
	"checkpoint_id" char(36),
	"deferred_request_id" char(36),
	"action" text NOT NULL,
	"user_instruction" text,
	"decision" text NOT NULL,
	"reason" text,
	"requested_transition" text,
	"performed_transition" text,
	"outcome" text,
	"checkpoint_freshness" text,
	"metadata" jsonb,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_dispatches" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"batch_id" char(36) NOT NULL,
	"request_index" integer NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"admitted_root_task_run_id" char(36),
	"parent_run_id" char(36) NOT NULL,
	"decision_actor_run_id" char(36),
	"prompt" text,
	"first_message_id" char(36),
	"agent_type" text DEFAULT 'general-purpose' NOT NULL,
	"tools" jsonb,
	"disallowed_tools" jsonb,
	"provenance" text NOT NULL,
	"requested_at" timestamp (3) with time zone NOT NULL,
	"user_priority_hint" integer,
	"requested_model" text,
	"byok_key_id" text,
	"byok_model" text,
	"temperature" double precision,
	"actor_user_id" text NOT NULL,
	"state" text NOT NULL,
	"defer_reason" text,
	"scheduling_reason" text,
	"requested_sequence" bigint,
	"deferred_at" timestamp (3) with time zone,
	"admitted_at" timestamp (3) with time zone,
	"cancelled_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_dispatches_provenance_check" CHECK ("subagent_dispatches"."provenance" IN ('web','android','server')),
	CONSTRAINT "subagent_dispatches_state_check" CHECK ("subagent_dispatches"."state" IN ('awaiting_next_user_task','admitted','cancelled')),
	CONSTRAINT "subagent_dispatches_index_check" CHECK ("subagent_dispatches"."request_index" >= 0)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_logical_workers" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"request_id" char(36) NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"current_root_task_run_id" char(36) NOT NULL,
	"child_session_id" char(36) NOT NULL,
	"agent_type" text NOT NULL,
	"status" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_logical_workers_request_id_unique" UNIQUE("request_id"),
	CONSTRAINT "subagent_logical_workers_child_session_id_unique" UNIQUE("child_session_id"),
	CONSTRAINT "subagent_workers_status_check" CHECK ("subagent_logical_workers"."status" IN ('running','completed','failed','cancelled','timeout'))
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_reports" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"logical_worker_id" char(36) NOT NULL,
	"attempt_id" char(36) NOT NULL,
	"child_session_id" char(36) NOT NULL,
	"child_run_id" char(36) NOT NULL,
	"agent_type" text NOT NULL,
	"status" text NOT NULL,
	"summary" text NOT NULL,
	"structured_report" jsonb,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_reports_attempt_id_unique" UNIQUE("attempt_id"),
	CONSTRAINT "subagent_reports_status_check" CHECK ("subagent_reports"."status" IN ('completed','failed','cancelled','timeout')),
	CONSTRAINT "subagent_reports_summary_bound_check" CHECK (length("subagent_reports"."summary") <= 4000)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_root_finalizations" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"session_id" char(36) NOT NULL,
	"execution_epoch" integer NOT NULL,
	"active_attempt_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"wake_requested_at" timestamp (3) with time zone,
	"finalized_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_root_finalizations_epoch_check" CHECK ("subagent_root_finalizations"."execution_epoch" > 0)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_roots" (
	"root_task_run_id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"execution_epoch" integer DEFAULT 1 NOT NULL,
	"active_worker_count" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "subagent_roots_state_check" CHECK ("subagent_roots"."execution_epoch" > 0 AND "subagent_roots"."active_worker_count" >= 0)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "subagent_session_admission" (
	"session_id" char(36) PRIMARY KEY NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
-- Evidence-based backfill: an existing session proves only its admission-lock
-- scope. No legacy request, worker, attempt, report, checkpoint, or finalization
-- is inferred from previews, in-memory state, or missing timestamps.
INSERT INTO "subagent_session_admission" ("session_id")
SELECT "id" FROM "sessions"
ON CONFLICT ("session_id") DO NOTHING;
--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_logical_worker_id_subagent_logical_workers_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "public"."subagent_logical_workers"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_session_id_sessions_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_child_session_id_sessions_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_child_session_id_sessions_id_fk" FOREIGN KEY ("child_session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_child_run_id_runs_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_child_run_id_runs_id_fk" FOREIGN KEY ("child_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_attempts_prompt_message_id_messages_id_fk' AND conrelid = 'subagent_attempts'::regclass
  ) THEN
    ALTER TABLE "subagent_attempts" ADD CONSTRAINT "subagent_attempts_prompt_message_id_messages_id_fk" FOREIGN KEY ("prompt_message_id") REFERENCES "public"."messages"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_batches_session_id_sessions_id_fk' AND conrelid = 'subagent_batches'::regclass
  ) THEN
    ALTER TABLE "subagent_batches" ADD CONSTRAINT "subagent_batches_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_batches_user_id_users_uid_fk' AND conrelid = 'subagent_batches'::regclass
  ) THEN
    ALTER TABLE "subagent_batches" ADD CONSTRAINT "subagent_batches_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_batches_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_batches'::regclass
  ) THEN
    ALTER TABLE "subagent_batches" ADD CONSTRAINT "subagent_batches_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_batches_parent_run_id_runs_id_fk' AND conrelid = 'subagent_batches'::regclass
  ) THEN
    ALTER TABLE "subagent_batches" ADD CONSTRAINT "subagent_batches_parent_run_id_runs_id_fk" FOREIGN KEY ("parent_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_checkpoints_session_id_sessions_id_fk' AND conrelid = 'subagent_checkpoints'::regclass
  ) THEN
    ALTER TABLE "subagent_checkpoints" ADD CONSTRAINT "subagent_checkpoints_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_checkpoints_logical_worker_id_subagent_logical_workers_id_fk' AND conrelid = 'subagent_checkpoints'::regclass
  ) THEN
    ALTER TABLE "subagent_checkpoints" ADD CONSTRAINT "subagent_checkpoints_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "public"."subagent_logical_workers"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_checkpoints_attempt_id_subagent_attempts_id_fk' AND conrelid = 'subagent_checkpoints'::regclass
  ) THEN
    ALTER TABLE "subagent_checkpoints" ADD CONSTRAINT "subagent_checkpoints_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("attempt_id") REFERENCES "public"."subagent_attempts"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_checkpoints_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_checkpoints'::regclass
  ) THEN
    ALTER TABLE "subagent_checkpoints" ADD CONSTRAINT "subagent_checkpoints_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_session_id_sessions_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_actor_run_id_runs_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_actor_run_id_runs_id_fk" FOREIGN KEY ("actor_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_logical_worker_id_subagent_logical_workers_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "public"."subagent_logical_workers"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_source_attempt_id_subagent_attempts_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_source_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("source_attempt_id") REFERENCES "public"."subagent_attempts"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_target_logical_worker_id_subagent_logical_workers_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_target_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("target_logical_worker_id") REFERENCES "public"."subagent_logical_workers"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_checkpoint_id_subagent_checkpoints_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_checkpoint_id_subagent_checkpoints_id_fk" FOREIGN KEY ("checkpoint_id") REFERENCES "public"."subagent_checkpoints"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_control_audit_deferred_request_id_subagent_dispatches_id_fk' AND conrelid = 'subagent_control_audit'::regclass
  ) THEN
    ALTER TABLE "subagent_control_audit" ADD CONSTRAINT "subagent_control_audit_deferred_request_id_subagent_dispatches_id_fk" FOREIGN KEY ("deferred_request_id") REFERENCES "public"."subagent_dispatches"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_batch_id_subagent_batches_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_batch_id_subagent_batches_id_fk" FOREIGN KEY ("batch_id") REFERENCES "public"."subagent_batches"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_session_id_sessions_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_user_id_users_uid_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_admitted_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_admitted_root_task_run_id_runs_id_fk" FOREIGN KEY ("admitted_root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_parent_run_id_runs_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_parent_run_id_runs_id_fk" FOREIGN KEY ("parent_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_decision_actor_run_id_runs_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_decision_actor_run_id_runs_id_fk" FOREIGN KEY ("decision_actor_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_first_message_id_messages_id_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_first_message_id_messages_id_fk" FOREIGN KEY ("first_message_id") REFERENCES "public"."messages"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_dispatches_actor_user_id_users_uid_fk' AND conrelid = 'subagent_dispatches'::regclass
  ) THEN
    ALTER TABLE "subagent_dispatches" ADD CONSTRAINT "subagent_dispatches_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_logical_workers_request_id_subagent_dispatches_id_fk' AND conrelid = 'subagent_logical_workers'::regclass
  ) THEN
    ALTER TABLE "subagent_logical_workers" ADD CONSTRAINT "subagent_logical_workers_request_id_subagent_dispatches_id_fk" FOREIGN KEY ("request_id") REFERENCES "public"."subagent_dispatches"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_logical_workers_session_id_sessions_id_fk' AND conrelid = 'subagent_logical_workers'::regclass
  ) THEN
    ALTER TABLE "subagent_logical_workers" ADD CONSTRAINT "subagent_logical_workers_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_logical_workers_user_id_users_uid_fk' AND conrelid = 'subagent_logical_workers'::regclass
  ) THEN
    ALTER TABLE "subagent_logical_workers" ADD CONSTRAINT "subagent_logical_workers_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_logical_workers_current_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_logical_workers'::regclass
  ) THEN
    ALTER TABLE "subagent_logical_workers" ADD CONSTRAINT "subagent_logical_workers_current_root_task_run_id_runs_id_fk" FOREIGN KEY ("current_root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_logical_workers_child_session_id_sessions_id_fk' AND conrelid = 'subagent_logical_workers'::regclass
  ) THEN
    ALTER TABLE "subagent_logical_workers" ADD CONSTRAINT "subagent_logical_workers_child_session_id_sessions_id_fk" FOREIGN KEY ("child_session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_reports_session_id_sessions_id_fk' AND conrelid = 'subagent_reports'::regclass
  ) THEN
    ALTER TABLE "subagent_reports" ADD CONSTRAINT "subagent_reports_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_reports_logical_worker_id_subagent_logical_workers_id_fk' AND conrelid = 'subagent_reports'::regclass
  ) THEN
    ALTER TABLE "subagent_reports" ADD CONSTRAINT "subagent_reports_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "public"."subagent_logical_workers"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_reports_attempt_id_subagent_attempts_id_fk' AND conrelid = 'subagent_reports'::regclass
  ) THEN
    ALTER TABLE "subagent_reports" ADD CONSTRAINT "subagent_reports_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("attempt_id") REFERENCES "public"."subagent_attempts"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_reports_child_session_id_sessions_id_fk' AND conrelid = 'subagent_reports'::regclass
  ) THEN
    ALTER TABLE "subagent_reports" ADD CONSTRAINT "subagent_reports_child_session_id_sessions_id_fk" FOREIGN KEY ("child_session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_reports_child_run_id_runs_id_fk' AND conrelid = 'subagent_reports'::regclass
  ) THEN
    ALTER TABLE "subagent_reports" ADD CONSTRAINT "subagent_reports_child_run_id_runs_id_fk" FOREIGN KEY ("child_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_root_finalizations_root_task_run_id_subagent_roots_root_task_run_id_fk' AND conrelid = 'subagent_root_finalizations'::regclass
  ) THEN
    ALTER TABLE "subagent_root_finalizations" ADD CONSTRAINT "subagent_root_finalizations_root_task_run_id_subagent_roots_root_task_run_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."subagent_roots"("root_task_run_id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_root_finalizations_session_id_sessions_id_fk' AND conrelid = 'subagent_root_finalizations'::regclass
  ) THEN
    ALTER TABLE "subagent_root_finalizations" ADD CONSTRAINT "subagent_root_finalizations_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_roots_root_task_run_id_runs_id_fk' AND conrelid = 'subagent_roots'::regclass
  ) THEN
    ALTER TABLE "subagent_roots" ADD CONSTRAINT "subagent_roots_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "public"."runs"("id") ON DELETE no action ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_roots_session_id_sessions_id_fk' AND conrelid = 'subagent_roots'::regclass
  ) THEN
    ALTER TABLE "subagent_roots" ADD CONSTRAINT "subagent_roots_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subagent_session_admission_session_id_sessions_id_fk' AND conrelid = 'subagent_session_admission'::regclass
  ) THEN
    ALTER TABLE "subagent_session_admission" ADD CONSTRAINT "subagent_session_admission_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;
  END IF;
END
$$;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "subagent_attempts_worker_number_uq" ON "subagent_attempts" USING btree ("logical_worker_id","attempt_number");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "subagent_attempts_one_active_worker_uq" ON "subagent_attempts" USING btree ("logical_worker_id") WHERE "subagent_attempts"."status" = 'running';--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_attempts_session_active_idx" ON "subagent_attempts" USING btree ("session_id","root_task_run_id","id") WHERE "subagent_attempts"."status" = 'running';--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_attempts_root_epoch_idx" ON "subagent_attempts" USING btree ("root_task_run_id","execution_epoch","status");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_batches_session_id_idx" ON "subagent_batches" USING btree ("session_id","id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_batches_root_idx" ON "subagent_batches" USING btree ("root_task_run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_checkpoints_worker_created_idx" ON "subagent_checkpoints" USING btree ("logical_worker_id","created_at","id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_checkpoints_attempt_idx" ON "subagent_checkpoints" USING btree ("attempt_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_control_audit_session_created_idx" ON "subagent_control_audit" USING btree ("session_id","created_at","id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_control_audit_worker_idx" ON "subagent_control_audit" USING btree ("logical_worker_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "subagent_dispatches_batch_index_uq" ON "subagent_dispatches" USING btree ("batch_id","request_index");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_dispatches_session_state_idx" ON "subagent_dispatches" USING btree ("session_id","state","requested_at","id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_dispatches_root_idx" ON "subagent_dispatches" USING btree ("root_task_run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_dispatches_parent_child_idx" ON "subagent_dispatches" USING btree ("parent_run_id","first_message_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_workers_session_status_idx" ON "subagent_logical_workers" USING btree ("session_id","status");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_workers_root_idx" ON "subagent_logical_workers" USING btree ("current_root_task_run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_reports_session_cursor_idx" ON "subagent_reports" USING btree ("session_id","id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "subagent_root_finalizations_epoch_uq" ON "subagent_root_finalizations" USING btree ("root_task_run_id","execution_epoch");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_root_finalizations_session_idx" ON "subagent_root_finalizations" USING btree ("session_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "subagent_roots_session_idx" ON "subagent_roots" USING btree ("session_id");--> statement-breakpoint
ALTER TABLE "subagent_dispatches" ADD COLUMN IF NOT EXISTS "temperature" double precision;
