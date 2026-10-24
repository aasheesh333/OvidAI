ALTER TABLE "attachments" ADD COLUMN IF NOT EXISTS "content_type_declared" boolean DEFAULT false NOT NULL;--> statement-breakpoint
UPDATE "attachments" SET "content_type_declared" = true WHERE "content_type" <> 'application/octet-stream';
