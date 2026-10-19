CREATE TABLE "private_memory_files" (
	"user_id" text NOT NULL,
	"scope" text NOT NULL,
	"session_id" char(36),
	"name" text NOT NULL,
	"content" text NOT NULL,
	"revision" char(64) NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "private_memory_files_user_id_scope_name_pk" PRIMARY KEY("user_id","scope","name"),
	CONSTRAINT "private_memory_scope_check" CHECK (("private_memory_files"."scope" = 'shared' AND "private_memory_files"."session_id" IS NULL) OR ("private_memory_files"."session_id" IS NOT NULL AND "private_memory_files"."scope" = "private_memory_files"."session_id")),
	CONSTRAINT "private_memory_content_size_check" CHECK (octet_length("private_memory_files"."content") <= 32768),
	CONSTRAINT "private_memory_name_check" CHECK (length("private_memory_files"."name") <= 80 AND "private_memory_files"."name" ~ '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*\.md$' AND (lower("private_memory_files"."name") <> 'memory.md' OR "private_memory_files"."name" = 'MEMORY.md'))
);
--> statement-breakpoint
ALTER TABLE "private_memory_files" ADD CONSTRAINT "private_memory_files_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "private_memory_files" ADD CONSTRAINT "private_memory_files_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "private_memory_session_id_idx" ON "private_memory_files" USING btree ("session_id");