CREATE TABLE "session_agent_state" (
	"session_id" char(36) PRIMARY KEY NOT NULL,
	"state" jsonb DEFAULT '{}'::jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "search_vector" "tsvector" GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED;--> statement-breakpoint
ALTER TABLE "session_agent_state" ADD CONSTRAINT "session_agent_state_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_search_gin" ON "messages" USING gin ("search_vector");