CREATE TABLE "run_usage" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"session_id" char(36) NOT NULL,
	"run_id" char(36) NOT NULL,
	"model" text NOT NULL,
	"input_tokens" integer DEFAULT 0 NOT NULL,
	"output_tokens" integer DEFAULT 0 NOT NULL,
	"cache_read_tokens" integer DEFAULT 0 NOT NULL,
	"cache_write_tokens" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "run_usage_user_id_created_at_idx" ON "run_usage" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "run_usage_run_id_idx" ON "run_usage" USING btree ("run_id");