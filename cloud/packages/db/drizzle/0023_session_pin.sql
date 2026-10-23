ALTER TABLE "sessions" ADD COLUMN "pinned_at" timestamp with time zone;--> statement-breakpoint
CREATE INDEX "sessions_pinned_idx" ON "sessions" USING btree ("user_id","pinned_at");
