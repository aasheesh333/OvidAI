CREATE TABLE "projects" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "private_memory_files" DROP CONSTRAINT "private_memory_scope_check";--> statement-breakpoint
ALTER TABLE "private_memory_files" ADD COLUMN "project_id" char(36);--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "project_id" char(36);--> statement-breakpoint
ALTER TABLE "projects" ADD CONSTRAINT "projects_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "projects_user_id_name_idx" ON "projects" USING btree ("user_id","name");--> statement-breakpoint
CREATE INDEX "projects_user_id_idx" ON "projects" USING btree ("user_id");--> statement-breakpoint
ALTER TABLE "private_memory_files" ADD CONSTRAINT "private_memory_files_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "private_memory_project_id_idx" ON "private_memory_files" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "sessions_project_id_idx" ON "sessions" USING btree ("project_id");--> statement-breakpoint
ALTER TABLE "private_memory_files" ADD CONSTRAINT "private_memory_scope_check" CHECK (("private_memory_files"."scope" = 'shared' AND "private_memory_files"."session_id" IS NULL AND "private_memory_files"."project_id" IS NULL) OR ("private_memory_files"."session_id" IS NOT NULL AND "private_memory_files"."project_id" IS NULL AND "private_memory_files"."scope" = "private_memory_files"."session_id") OR ("private_memory_files"."project_id" IS NOT NULL AND "private_memory_files"."session_id" IS NULL AND "private_memory_files"."scope" = 'project:' || "private_memory_files"."project_id"::text));