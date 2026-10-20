ALTER TABLE "attachments" ADD COLUMN "project_id" char(36);--> statement-breakpoint
ALTER TABLE "workspace_objects" ADD COLUMN "project_id" char(36);--> statement-breakpoint
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "workspace_objects" ADD CONSTRAINT "workspace_objects_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "attachments_project_id_idx" ON "attachments" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "workspace_objects_project_id_idx" ON "workspace_objects" USING btree ("project_id");--> statement-breakpoint
-- Backfill: existing rows predate project attribution. Derive it from the
-- owning session ONCE; new writes stamp at creation (and moveSession restamps
-- a chat's files when it changes projects). Reads additionally fall back to
-- the session join for any legacy/raw-inserted NULL, so no file is lost.
UPDATE "attachments" a SET "project_id" = s."project_id" FROM "sessions" s WHERE a."session_id" = s."id" AND a."project_id" IS NULL AND s."project_id" IS NOT NULL;--> statement-breakpoint
UPDATE "workspace_objects" w SET "project_id" = s."project_id" FROM "sessions" s WHERE w."session_id" = s."id" AND w."project_id" IS NULL AND s."project_id" IS NOT NULL;
