CREATE TABLE "file_manifests" (
	"session_id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"generation" integer DEFAULT 0 NOT NULL,
	"state" text NOT NULL,
	"ui_tree" jsonb NOT NULL,
	"archive_key" text,
	"archive_bytes" bigint,
	"archive_sha256" text,
	"entry_count" integer,
	"workspace_bytes" bigint,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "workspace_objects" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"session_id" char(36),
	"kind" text NOT NULL,
	"r2_key" text NOT NULL,
	"bytes" bigint NOT NULL,
	"sha256" text NOT NULL,
	"content_type" text,
	"generation" integer,
	"status" text DEFAULT 'active' NOT NULL,
	"meta" jsonb,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "workspace_objects_r2_key_unique" UNIQUE("r2_key")
);
--> statement-breakpoint
ALTER TABLE "file_manifests" ADD CONSTRAINT "file_manifests_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "file_manifests" ADD CONSTRAINT "file_manifests_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "workspace_objects" ADD CONSTRAINT "workspace_objects_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "workspace_objects" ADD CONSTRAINT "workspace_objects_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "file_manifests_user_id_idx" ON "file_manifests" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "file_manifests_state_idx" ON "file_manifests" USING btree ("state");--> statement-breakpoint
CREATE INDEX "workspace_objects_session_id_idx" ON "workspace_objects" USING btree ("session_id");--> statement-breakpoint
CREATE INDEX "workspace_objects_user_id_kind_idx" ON "workspace_objects" USING btree ("user_id","kind");