ALTER TABLE "schedule_runs" ADD COLUMN "session_id" char(36);--> statement-breakpoint
ALTER TABLE "schedule_runs" ADD COLUMN "trigger_kind" text;--> statement-breakpoint
UPDATE "schedule_runs" AS sr
SET "session_id" = s."session_id",
    "trigger_kind" = s."trigger"->>'kind'
FROM "schedules" AS s
WHERE s."id" = sr."schedule_id";--> statement-breakpoint
ALTER TABLE "schedule_runs" ALTER COLUMN "session_id" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "schedule_runs" ALTER COLUMN "trigger_kind" SET NOT NULL;
