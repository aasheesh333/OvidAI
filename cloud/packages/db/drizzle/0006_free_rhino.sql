CREATE TABLE "mcp_oauth_flows" (
	"state" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"server_id" char(36) NOT NULL,
	"verifier_sealed" jsonb,
	"config" jsonb,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"used" boolean DEFAULT false NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mcp_oauth_tokens" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"server_id" char(36) NOT NULL,
	"tokens_sealed" jsonb NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mcp_servers" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"transport" text NOT NULL,
	"curated_id" text,
	"config" jsonb,
	"secrets_sealed" jsonb,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "plugin_grants" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"plugin_id" text NOT NULL,
	"capabilities" jsonb NOT NULL,
	"env_names" jsonb NOT NULL,
	"manifest_digest" text NOT NULL,
	"allow_dependency_scripts" boolean DEFAULT false NOT NULL,
	"granted_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "plugins" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"plugin_id" text NOT NULL,
	"version" text NOT NULL,
	"source" jsonb NOT NULL,
	"status" text NOT NULL,
	"content_dir" text,
	"manifest" jsonb,
	"probe_failures" jsonb,
	"config_sealed" jsonb,
	"installed_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "mcp_oauth_tokens" ADD CONSTRAINT "mcp_oauth_tokens_server_id_mcp_servers_id_fk" FOREIGN KEY ("server_id") REFERENCES "public"."mcp_servers"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mcp_servers" ADD CONSTRAINT "mcp_servers_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "mcp_oauth_flows_expires_at_idx" ON "mcp_oauth_flows" USING btree ("expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "mcp_oauth_tokens_server_id_idx" ON "mcp_oauth_tokens" USING btree ("server_id");--> statement-breakpoint
CREATE UNIQUE INDEX "mcp_servers_user_name_idx" ON "mcp_servers" USING btree ("user_id","name");--> statement-breakpoint
CREATE INDEX "mcp_servers_user_id_idx" ON "mcp_servers" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "plugin_grants_user_plugin_id_idx" ON "plugin_grants" USING btree ("user_id","plugin_id");--> statement-breakpoint
CREATE UNIQUE INDEX "plugins_user_plugin_id_idx" ON "plugins" USING btree ("user_id","plugin_id");--> statement-breakpoint
CREATE INDEX "plugins_user_id_idx" ON "plugins" USING btree ("user_id");