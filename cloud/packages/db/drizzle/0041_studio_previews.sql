CREATE TABLE IF NOT EXISTS "studio_previews" (
	"id" uuid PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"generation" bigint DEFAULT 1 NOT NULL,
	"kind" text NOT NULL,
	"workspace_path" text NOT NULL,
	"project_dir" text,
	"start_script" text,
	"process_id" integer,
	"process_group_id" text,
	"worker_epoch" text,
	"bind_host" text,
	"port" integer,
	"status" text NOT NULL,
	"created_at" timestamp (3) with time zone NOT NULL,
	"last_access_at" timestamp (3) with time zone,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"ended_at" timestamp (3) with time zone,
	"exit_code" integer,
	"failure_code" text,
	"log_bytes" bigint,
	CONSTRAINT "studio_previews_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action,
	CONSTRAINT "studio_previews_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action,
	CONSTRAINT "studio_previews_kind_check" CHECK ("studio_previews"."kind" IN ('static','dev_server')),
	CONSTRAINT "studio_previews_script_check" CHECK ("studio_previews"."start_script" IS NULL OR "studio_previews"."start_script" IN ('dev','start','preview')),
	CONSTRAINT "studio_previews_status_check" CHECK ("studio_previews"."status" IN ('starting','running','stopping','stopped','failed','expired')),
	CONSTRAINT "studio_previews_generation_check" CHECK ("studio_previews"."generation" >= 1),
	CONSTRAINT "studio_previews_port_check" CHECK ("studio_previews"."port" IS NULL OR "studio_previews"."port" BETWEEN 20000 AND 29999),
	CONSTRAINT "studio_previews_log_bytes_check" CHECK ("studio_previews"."log_bytes" IS NULL OR "studio_previews"."log_bytes" >= 0),
	CONSTRAINT "studio_previews_launch_definition_check" CHECK (("studio_previews"."kind" = 'dev_server' AND "studio_previews"."project_dir" IS NOT NULL AND "studio_previews"."start_script" IS NOT NULL) OR ("studio_previews"."kind" = 'static' AND "studio_previews"."project_dir" IS NULL AND "studio_previews"."start_script" IS NULL))
);--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "studio_previews_id_generation_uq" ON "studio_previews" USING btree ("id","generation");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "studio_previews_user_status_idx" ON "studio_previews" USING btree ("user_id","status","kind");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "studio_previews_session_status_idx" ON "studio_previews" USING btree ("session_id","status");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "studio_previews_expiry_sweep_idx" ON "studio_previews" USING btree ("expires_at","id") WHERE "studio_previews"."status" IN ('starting','running','stopping');
