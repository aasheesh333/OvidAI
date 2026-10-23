CREATE TABLE "studio_repos" (
	"session_id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"repo" text NOT NULL,
	"repo_dir" text NOT NULL,
	"branch" text NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "studio_repos_repo_len_check" CHECK (length("studio_repos"."repo") BETWEEN 1 AND 2048),
	CONSTRAINT "studio_repos_dir_len_check" CHECK (length("studio_repos"."repo_dir") BETWEEN 1 AND 255),
	CONSTRAINT "studio_repos_branch_len_check" CHECK (length("studio_repos"."branch") BETWEEN 1 AND 255)
);
--> statement-breakpoint
ALTER TABLE "studio_repos" ADD CONSTRAINT "studio_repos_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "studio_repos" ADD CONSTRAINT "studio_repos_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "studio_repos_user_id_idx" ON "studio_repos" USING btree ("user_id");
