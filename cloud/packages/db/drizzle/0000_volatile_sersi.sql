CREATE TABLE "messages" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"role" text NOT NULL,
	"content" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "runs" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"status" text NOT NULL,
	"prompt_message_id" char(36),
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_error" text,
	"started_at" timestamp (3) with time zone,
	"finished_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "session_event_mirror" (
	"session_id" text NOT NULL,
	"seq" text NOT NULL,
	"type" text NOT NULL,
	"payload" jsonb NOT NULL,
	"ts" timestamp (3) with time zone NOT NULL,
	CONSTRAINT "session_event_mirror_session_id_seq_pk" PRIMARY KEY("session_id","seq")
);
--> statement-breakpoint
CREATE TABLE "sessions" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"title" text,
	"mode" text DEFAULT 'auto' NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"archived_at" timestamp (3) with time zone
);
--> statement-breakpoint
CREATE TABLE "users" (
	"uid" text PRIMARY KEY NOT NULL,
	"email" text,
	"tier" text DEFAULT 'free' NOT NULL,
	"banned_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "runs" ADD CONSTRAINT "runs_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_session_id_id_idx" ON "messages" USING btree ("session_id","id");--> statement-breakpoint
CREATE INDEX "runs_session_id_idx" ON "runs" USING btree ("session_id");--> statement-breakpoint
CREATE INDEX "sessions_user_id_idx" ON "sessions" USING btree ("user_id");