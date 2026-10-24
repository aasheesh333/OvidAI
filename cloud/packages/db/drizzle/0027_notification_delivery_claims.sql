-- One terminal agent run produces at most one completion fan-out, even when
-- two workers or a restarted worker observe the same durable completion event.
-- This claim contains no prompt, answer, session title, or other private text.
CREATE TABLE "notification_delivery_claims" (
  "user_id" text NOT NULL,
  "kind" text NOT NULL,
  "run_id" char(36) NOT NULL,
  "state" text NOT NULL DEFAULT 'pending',
  "claimant" text,
  "created_at" timestamp(3) with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "notification_delivery_claims_pkey" PRIMARY KEY ("user_id", "kind", "run_id")
);
--> statement-breakpoint
ALTER TABLE "notification_delivery_claims" ADD CONSTRAINT "notification_delivery_claims_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;
