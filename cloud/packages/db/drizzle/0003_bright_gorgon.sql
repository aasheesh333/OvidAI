CREATE TABLE "attachments" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"size" integer NOT NULL,
	"r2_key" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "attachments_session_id_idx" ON "attachments" USING btree ("session_id");