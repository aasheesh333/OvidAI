CREATE TABLE "grants" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"session_id" char(36) NOT NULL,
	"kind" text NOT NULL,
	"pattern" text NOT NULL,
	"decision" text NOT NULL,
	"mode" text,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "grants" ADD CONSTRAINT "grants_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "grants" ADD CONSTRAINT "grants_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "grants_user_id_session_id_idx" ON "grants" USING btree ("user_id","session_id");