-- Legacy PostgreSQL collaboration used the same collab_invites name with an
-- incompatible shape. Legacy writers must already be disabled. Existing tables
-- are accepted only when the COMPLETE canonical table/constraint/index contract
-- matches; IF NOT EXISTS must never hide an incompatible lookalike or index.
-- An empty exact legacy table is archived. Populated/unknown shapes block the
-- whole migration before canonical DDL, preserving every row for explicit review.
DO $collab_0040_preflight$
DECLARE
  canonical_ok boolean := true;
  legacy_ok boolean := true;
  column_ok boolean;
  constraint_ok boolean;
  index_ok boolean;
  actual_count integer;
  expected record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('ovid:collab:0040', 714031));
  IF to_regclass('collab_invites') IS NULL THEN
    RETURN;
  END IF;

  EXECUTE 'LOCK TABLE collab_invites IN ACCESS EXCLUSIVE MODE';

  -- Complete relation shape: permanent ordinary table, no RLS/policies.
  SELECT c.relkind = 'r' AND c.relpersistence = 'p' AND NOT c.relrowsecurity
    AND c.reloptions IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
    AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal)
    AND NOT EXISTS (SELECT 1 FROM pg_rewrite r WHERE r.ev_class = c.oid AND r.rulename <> '_RETURN')
  INTO canonical_ok
  FROM pg_class c
  WHERE c.oid = to_regclass('collab_invites');

  -- Exact columns, types, nullability, defaults, collation and non-generated
  -- storage. Extra columns are rejected rather than skipped by CREATE IF NOT EXISTS.
  FOR expected IN
    SELECT * FROM (VALUES
      ('id', 'text', true, NULL),
      ('room_id', 'character(36)', true, NULL),
      ('code_hash', 'character(64)', true, NULL),
      ('issued_by_user_id', 'text', true, NULL),
      ('idempotency_key', 'text', true, NULL),
      ('issued_generation', 'bigint', true, '1'),
      ('max_uses', 'integer', true, NULL),
      ('uses', 'integer', true, '0'),
      ('expires_at', 'timestamp(3) with time zone', true, NULL),
      ('revoked_at', 'timestamp(3) with time zone', false, NULL),
      ('created_at', 'timestamp(3) with time zone', true, 'now()')
    ) AS required(column_name, type_name, not_null, default_expression)
  LOOP
    SELECT a.attnotnull = expected.not_null
      AND format_type(a.atttypid, a.atttypmod) = expected.type_name
      AND a.attcollation = t.typcollation
      AND a.attidentity = '' AND a.attgenerated = '' AND a.attinhcount = 0
      AND (
        (expected.default_expression IS NULL AND NOT a.atthasdef)
        OR
        (expected.default_expression IS NOT NULL AND a.atthasdef
          AND pg_get_expr(d.adbin, d.adrelid) = expected.default_expression)
      )
    INTO column_ok
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = to_regclass('collab_invites')
      AND a.attname = expected.column_name
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF column_ok IS NOT TRUE THEN
      canonical_ok := false;
    END IF;
  END LOOP;
  SELECT count(*)::int INTO actual_count
  FROM pg_attribute a
  WHERE a.attrelid = to_regclass('collab_invites')
    AND a.attnum > 0 AND NOT a.attisdropped;
  IF actual_count <> 11 THEN
    canonical_ok := false;
  END IF;

  -- Exact PK, both FKs and all three checks, with no additional constraints.
  FOR expected IN
    SELECT * FROM (VALUES
      ('collab_invites_pkey', 'PRIMARY KEY (id)'),
      ('collab_invites_room_id_collab_rooms_id_fk',
       'FOREIGN KEY (room_id) REFERENCES collab_rooms(id) ON DELETE CASCADE'),
      ('collab_invites_issued_by_user_id_users_uid_fk',
       'FOREIGN KEY (issued_by_user_id) REFERENCES users(uid) ON DELETE CASCADE'),
      ('collab_invites_code_hash_check',
       'CHECK ((code_hash ~ ''^[0-9a-f]{64}$''::text))'),
      ('collab_invites_uses_check',
       'CHECK ((max_uses >= 1) AND (max_uses <= 50) AND (uses >= 0) AND (uses <= max_uses))'),
      ('collab_invites_generation_check', 'CHECK ((issued_generation >= 1))')
    ) AS required(constraint_name, definition)
  LOOP
    SELECT c.convalidated AND NOT c.condeferrable AND NOT c.condeferred
      AND pg_get_constraintdef(c.oid) = expected.definition
    INTO constraint_ok
    FROM pg_constraint c
    WHERE c.conrelid = to_regclass('collab_invites')
      AND c.conname = expected.constraint_name;
    IF constraint_ok IS NOT TRUE THEN
      canonical_ok := false;
    END IF;
  END LOOP;
  SELECT count(*)::int INTO actual_count
  FROM pg_constraint c
  WHERE c.conrelid = to_regclass('collab_invites');
  IF actual_count <> 6 THEN
    canonical_ok := false;
  END IF;

  -- Exact index ownership and full server definitions, including the PK index.
  -- Searching by both table and expected name catches a same-named index owned
  -- by another relation (index names share the schema namespace).
  SELECT count(*)::int INTO actual_count
  FROM pg_indexes i
  WHERE i.schemaname = current_schema()
    AND (
      i.tablename = 'collab_invites'
      OR i.indexname IN (
        'collab_invites_pkey', 'collab_invites_code_hash_uq',
        'collab_invites_room_request_uq', 'collab_invites_room_active_idx',
        'collab_invites_issuer_idx'
      )
    );
  IF actual_count <> 5 THEN
    canonical_ok := false;
  END IF;
  FOR expected IN
    SELECT index_name, format(index_definition, current_schema())
    FROM (VALUES
      ('collab_invites_pkey',
       'CREATE UNIQUE INDEX collab_invites_pkey ON %s.collab_invites USING btree (id)'),
      ('collab_invites_code_hash_uq',
       'CREATE UNIQUE INDEX collab_invites_code_hash_uq ON %s.collab_invites USING btree (code_hash)'),
      ('collab_invites_room_request_uq',
       'CREATE UNIQUE INDEX collab_invites_room_request_uq ON %s.collab_invites USING btree (room_id, issued_by_user_id, idempotency_key)'),
      ('collab_invites_room_active_idx',
       'CREATE INDEX collab_invites_room_active_idx ON %s.collab_invites USING btree (room_id, revoked_at, expires_at)'),
      ('collab_invites_issuer_idx',
       'CREATE INDEX collab_invites_issuer_idx ON %s.collab_invites USING btree (issued_by_user_id, revoked_at)')
    ) AS required(index_name, index_definition)
  LOOP
    SELECT x.indisvalid AND x.indisready
      AND i.indexdef = expected.index_definition
    INTO index_ok
    FROM pg_class ic
    JOIN pg_namespace n ON n.oid = ic.relnamespace
    JOIN pg_index x ON x.indexrelid = ic.oid
    JOIN pg_indexes i ON i.schemaname = n.nspname AND i.indexname = ic.relname
    WHERE n.nspname = current_schema()
      AND ic.relname = expected.index_name;
    IF index_ok IS NOT TRUE THEN
      canonical_ok := false;
    END IF;
  END LOOP;

  IF canonical_ok THEN
    RETURN;
  END IF;

  -- The legacy fallback is exact too. Nine columns, five constraints and three
  -- indexes must match server/account/schema_collaboration.sql. Column-name
  -- supersets, wrong/missing definitions and empty lookalikes never reach ALTER.
  SELECT c.relkind = 'r' AND c.relpersistence = 'p' AND NOT c.relrowsecurity
    AND c.reloptions IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
    AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal)
    AND NOT EXISTS (SELECT 1 FROM pg_rewrite r WHERE r.ev_class = c.oid AND r.rulename <> '_RETURN')
  INTO legacy_ok
  FROM pg_class c
  WHERE c.oid = to_regclass('collab_invites');

  FOR expected IN
    SELECT * FROM (VALUES
      ('invite_id', 'text', true, NULL),
      ('session_id', 'text', true, NULL),
      ('code_hash', 'text', true, NULL),
      ('issued_generation', 'bigint', true, NULL),
      ('max_uses', 'integer', true, NULL),
      ('uses', 'integer', true, '0'),
      ('revoked', 'integer', true, '0'),
      ('created_at', 'double precision', true, NULL),
      ('expires_at', 'double precision', true, NULL)
    ) AS required(column_name, type_name, not_null, default_expression)
  LOOP
    SELECT a.attnotnull = expected.not_null
      AND format_type(a.atttypid, a.atttypmod) = expected.type_name
      AND a.attcollation = t.typcollation
      AND a.attidentity = '' AND a.attgenerated = '' AND a.attinhcount = 0
      AND (
        (expected.default_expression IS NULL AND NOT a.atthasdef)
        OR
        (expected.default_expression IS NOT NULL AND a.atthasdef
          AND pg_get_expr(d.adbin, d.adrelid) = expected.default_expression)
      )
    INTO column_ok
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = to_regclass('collab_invites')
      AND a.attname = expected.column_name
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF column_ok IS NOT TRUE THEN
      legacy_ok := false;
    END IF;
  END LOOP;
  SELECT count(*)::int INTO actual_count
  FROM pg_attribute a
  WHERE a.attrelid = to_regclass('collab_invites')
    AND a.attnum > 0 AND NOT a.attisdropped;
  IF actual_count <> 9 THEN
    legacy_ok := false;
  END IF;

  FOR expected IN
    SELECT * FROM (VALUES
      ('collab_invites_pkey', 'PRIMARY KEY (invite_id)'),
      ('collab_invites_code_hash_key', 'UNIQUE (code_hash)'),
      ('collab_invites_max_uses_check',
       'CHECK ((max_uses >= 1) AND (max_uses <= 9))'),
      ('collab_invites_uses_check',
       'CHECK ((uses >= 0) AND (uses <= max_uses))'),
      ('collab_invites_revoked_check', 'CHECK ((revoked = ANY (ARRAY[0, 1])))')
    ) AS required(constraint_name, definition)
  LOOP
    SELECT c.convalidated AND NOT c.condeferrable AND NOT c.condeferred
      AND pg_get_constraintdef(c.oid) = expected.definition
    INTO constraint_ok
    FROM pg_constraint c
    WHERE c.conrelid = to_regclass('collab_invites')
      AND c.conname = expected.constraint_name;
    IF constraint_ok IS NOT TRUE THEN
      legacy_ok := false;
    END IF;
  END LOOP;
  SELECT count(*)::int INTO actual_count
  FROM pg_constraint c
  WHERE c.conrelid = to_regclass('collab_invites');
  IF actual_count <> 5 THEN
    legacy_ok := false;
  END IF;

  SELECT count(*)::int INTO actual_count
  FROM pg_indexes i
  WHERE i.schemaname = current_schema() AND i.tablename = 'collab_invites';
  IF actual_count <> 3 THEN
    legacy_ok := false;
  END IF;
  FOR expected IN
    SELECT index_name, format(index_definition, current_schema())
    FROM (VALUES
      ('collab_invites_pkey',
       'CREATE UNIQUE INDEX collab_invites_pkey ON %s.collab_invites USING btree (invite_id)'),
      ('collab_invites_code_hash_key',
       'CREATE UNIQUE INDEX collab_invites_code_hash_key ON %s.collab_invites USING btree (code_hash)'),
      ('collab_invites_session',
       'CREATE INDEX collab_invites_session ON %s.collab_invites USING btree (session_id)')
    ) AS required(index_name, index_definition)
  LOOP
    SELECT x.indisvalid AND x.indisready
      AND i.indexdef = expected.index_definition
    INTO index_ok
    FROM pg_class ic
    JOIN pg_namespace n ON n.oid = ic.relnamespace
    JOIN pg_index x ON x.indexrelid = ic.oid
    JOIN pg_indexes i ON i.schemaname = n.nspname AND i.indexname = ic.relname
    WHERE n.nspname = current_schema()
      AND ic.relname = expected.index_name;
    IF index_ok IS NOT TRUE THEN
      legacy_ok := false;
    END IF;
  END LOOP;

  IF legacy_ok THEN
    -- The exact legacy PK owns collab_invites_pkey in this schema. Renaming
    -- its constraint also renames the backing index, freeing the canonical PK.
    IF to_regclass('legacy_collab_invites_0040') IS NOT NULL
      OR to_regclass('legacy_collab_invites_0040_pkey') IS NOT NULL THEN
      RAISE EXCEPTION 'collab_legacy_archive_exists'
        USING HINT = 'Review the existing legacy archive/PK explicitly; no rows were changed.';
    END IF;
    IF EXISTS (SELECT 1 FROM collab_invites) THEN
      RAISE EXCEPTION 'collab_legacy_invites_require_cutover'
        USING HINT = 'Non-empty legacy invites require an explicit data-mapping cutover with all legacy writers disabled; rows were left unchanged.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_indexes i
      WHERE i.schemaname = current_schema()
        AND i.tablename <> 'collab_invites'
        AND i.indexname IN (
          'collab_invites_code_hash_uq', 'collab_invites_room_request_uq',
          'collab_invites_room_active_idx', 'collab_invites_issuer_idx'
        )
    ) THEN
      RAISE EXCEPTION 'collab_invites_incompatible'
        USING HINT = 'Canonical index names conflict with another relation; no rows were changed.';
    END IF;
    ALTER TABLE "collab_invites" RENAME TO "legacy_collab_invites_0040";
    ALTER TABLE "legacy_collab_invites_0040"
      RENAME CONSTRAINT "collab_invites_pkey" TO "legacy_collab_invites_0040_pkey";
    RETURN;
  END IF;

  RAISE EXCEPTION 'collab_invites_incompatible'
    USING HINT = 'Existing collab_invites does not exactly match the canonical or recognized legacy table/constraint/index contract; no rows were changed.';
END
$collab_0040_preflight$;--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "collab_rooms" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"token_hash" char(64) NOT NULL,
	"session_id" char(36) NOT NULL,
	"owner_user_id" text NOT NULL,
	"request_id" text NOT NULL,
	"lifecycle" text DEFAULT 'active' NOT NULL,
	"generation" bigint DEFAULT 1 NOT NULL,
	"close_request_id" text,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "collab_rooms_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_rooms_owner_user_id_users_uid_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_rooms_token_hash_check" CHECK ("collab_rooms"."token_hash" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "collab_rooms_lifecycle_check" CHECK ("collab_rooms"."lifecycle" IN ('active','closing','closed')),
	CONSTRAINT "collab_rooms_generation_check" CHECK ("collab_rooms"."generation" >= 1)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "collab_members" (
	"room_id" char(36) NOT NULL,
	"user_id" text NOT NULL,
	"participant_id" text NOT NULL,
	"role" text NOT NULL,
	"status" text DEFAULT 'active' NOT NULL,
	"display_name" text,
	"generation" bigint DEFAULT 1 NOT NULL,
	"join_request_id" text,
	"join_invite_hash" char(64),
	"joined_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"revoked_at" timestamp (3) with time zone,
	CONSTRAINT "collab_members_room_id_user_id_pk" PRIMARY KEY("room_id","user_id"),
	CONSTRAINT "collab_members_room_id_collab_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."collab_rooms"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_members_user_id_users_uid_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_members_role_check" CHECK ("collab_members"."role" IN ('owner','participant')),
	CONSTRAINT "collab_members_status_check" CHECK ("collab_members"."status" IN ('active','left','revoked')),
	CONSTRAINT "collab_members_generation_check" CHECK ("collab_members"."generation" >= 1),
	CONSTRAINT "collab_members_join_invite_hash_check" CHECK ("collab_members"."join_invite_hash" IS NULL OR "collab_members"."join_invite_hash" ~ '^[0-9a-f]{64}$')
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "collab_invites" (
	"id" text PRIMARY KEY NOT NULL,
	"room_id" char(36) NOT NULL,
	"code_hash" char(64) NOT NULL,
	"issued_by_user_id" text NOT NULL,
	"idempotency_key" text NOT NULL,
	"issued_generation" bigint DEFAULT 1 NOT NULL,
	"max_uses" integer NOT NULL,
	"uses" integer DEFAULT 0 NOT NULL,
	"expires_at" timestamp (3) with time zone NOT NULL,
	"revoked_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "collab_invites_room_id_collab_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."collab_rooms"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_invites_issued_by_user_id_users_uid_fk" FOREIGN KEY ("issued_by_user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_invites_code_hash_check" CHECK ("collab_invites"."code_hash" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "collab_invites_uses_check" CHECK ("collab_invites"."max_uses" BETWEEN 1 AND 50 AND "collab_invites"."uses" >= 0 AND "collab_invites"."uses" <= "collab_invites"."max_uses"),
	CONSTRAINT "collab_invites_generation_check" CHECK ("collab_invites"."issued_generation" >= 1)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "collab_turns" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"room_id" char(36) NOT NULL,
	"participant_id" text NOT NULL,
	"actor_user_id" text NOT NULL,
	"run_id" char(36) NOT NULL,
	"user_message_id" char(36) NOT NULL,
	"idempotency_key" text NOT NULL,
	"model" text,
	"status" text DEFAULT 'queued' NOT NULL,
	"cancel_requested_at" timestamp (3) with time zone,
	"created_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "collab_turns_room_id_collab_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."collab_rooms"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_turns_actor_user_id_users_uid_fk" FOREIGN KEY ("actor_user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_turns_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_turns_user_message_id_messages_id_fk" FOREIGN KEY ("user_message_id") REFERENCES "public"."messages"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_turns_status_check" CHECK ("collab_turns"."status" IN ('queued','running','completed','failed','cancelled','interrupted'))
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "collab_sender_leases" (
	"id" char(36) PRIMARY KEY NOT NULL,
	"room_id" char(36) NOT NULL,
	"holder_participant_id" text NOT NULL,
	"holder_user_id" text NOT NULL,
	"run_id" char(36) NOT NULL,
	"generation" bigint DEFAULT 1 NOT NULL,
	"room_generation" bigint DEFAULT 1 NOT NULL,
	"membership_generation" bigint DEFAULT 1 NOT NULL,
	"started_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"heartbeat_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	"released_at" timestamp (3) with time zone,
	"cancel_requested_at" timestamp (3) with time zone,
	CONSTRAINT "collab_sender_leases_room_id_collab_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."collab_rooms"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_sender_leases_holder_user_id_users_uid_fk" FOREIGN KEY ("holder_user_id") REFERENCES "public"."users"("uid") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_sender_leases_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE cascade ON UPDATE no action,
	CONSTRAINT "collab_sender_leases_generations_check" CHECK ("collab_sender_leases"."generation" >= 1 AND "collab_sender_leases"."room_generation" >= 1 AND "collab_sender_leases"."membership_generation" >= 1)
);--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "collab_rooms_token_hash_uq" ON "collab_rooms" USING btree ("token_hash");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_rooms_session_uq" ON "collab_rooms" USING btree ("session_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_rooms_owner_request_uq" ON "collab_rooms" USING btree ("owner_user_id","request_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_rooms_owner_lifecycle_idx" ON "collab_rooms" USING btree ("owner_user_id","lifecycle");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_members_room_participant_uq" ON "collab_members" USING btree ("room_id","participant_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_members_room_active_owner_uq" ON "collab_members" USING btree ("room_id") WHERE "collab_members"."role" = 'owner' AND "collab_members"."status" = 'active';--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_members_room_status_idx" ON "collab_members" USING btree ("room_id","status","joined_at","participant_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_members_user_status_idx" ON "collab_members" USING btree ("user_id","status");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_invites_code_hash_uq" ON "collab_invites" USING btree ("code_hash");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_invites_room_request_uq" ON "collab_invites" USING btree ("room_id","issued_by_user_id","idempotency_key");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_invites_room_active_idx" ON "collab_invites" USING btree ("room_id","revoked_at","expires_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_invites_issuer_idx" ON "collab_invites" USING btree ("issued_by_user_id","revoked_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_turns_room_idempotency_uq" ON "collab_turns" USING btree ("room_id","idempotency_key");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_turns_run_uq" ON "collab_turns" USING btree ("run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_turns_actor_status_idx" ON "collab_turns" USING btree ("actor_user_id","status");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_turns_room_participant_idx" ON "collab_turns" USING btree ("room_id","participant_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_sender_leases_run_uq" ON "collab_sender_leases" USING btree ("run_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "collab_sender_leases_room_active_uq" ON "collab_sender_leases" USING btree ("room_id") WHERE "collab_sender_leases"."released_at" IS NULL;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_sender_leases_heartbeat_idx" ON "collab_sender_leases" USING btree ("heartbeat_at") WHERE "collab_sender_leases"."released_at" IS NULL;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "collab_sender_leases_holder_idx" ON "collab_sender_leases" USING btree ("holder_user_id","released_at");--> statement-breakpoint
