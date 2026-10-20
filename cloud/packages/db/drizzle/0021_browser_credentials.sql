CREATE TABLE "browser_credentials" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"label" text NOT NULL,
	"site" text NOT NULL,
	"username" text DEFAULT '' NOT NULL,
	"secret_kind" text DEFAULT 'password' NOT NULL,
	"secret_sealed" jsonb NOT NULL,
	"notes_sealed" jsonb,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "browser_credentials_label_len_check" CHECK (length("browser_credentials"."label") BETWEEN 1 AND 120),
	CONSTRAINT "browser_credentials_site_len_check" CHECK (length("browser_credentials"."site") BETWEEN 1 AND 2048),
	CONSTRAINT "browser_credentials_kind_check" CHECK ("browser_credentials"."secret_kind" IN ('password','token'))
);
--> statement-breakpoint
ALTER TABLE "browser_credentials" ADD CONSTRAINT "browser_credentials_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "browser_credentials_user_label_idx" ON "browser_credentials" USING btree ("user_id","label");--> statement-breakpoint
CREATE INDEX "browser_credentials_user_id_idx" ON "browser_credentials" USING btree ("user_id");