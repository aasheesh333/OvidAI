ALTER TABLE "attachments" ADD COLUMN "message_id" char(36);--> statement-breakpoint
CREATE INDEX "attachments_message_id_idx" ON "attachments" USING btree ("message_id");