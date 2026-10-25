CREATE TABLE IF NOT EXISTS "compaction_checkpoints" (
	"checkpoint_id" char(36) PRIMARY KEY NOT NULL,
	"compaction_id" char(36) NOT NULL,
	"session_id" char(36) NOT NULL,
	"root_task_run_id" char(36),
	"logical_worker_id" char(36),
	"attempt_id" char(36),
	"actor_id" text,
	"actor_kind" text,
	"previous_checkpoint_id" char(36),
	"request_digest" char(64),
	"model" text,
	"context_limit" bigint,
	"output_reserve_tokens" bigint,
	"provider_reserve_tokens" bigint,
	"before_tokens" bigint,
	"after_tokens" bigint,
	"usage_source" text,
	"cutoff_cursor" text,
	"cutoff_message_id" char(36),
	"ledger_version" integer,
	"ledger" jsonb,
	"summary" text,
	"active_state" jsonb NOT NULL,
	"continuation" text,
	"created_at" timestamp (3) with time zone,
	"recorded_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "compaction_checkpoints_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "sessions"("id") ON DELETE cascade,
	CONSTRAINT "compaction_checkpoints_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "runs"("id"),
	CONSTRAINT "compaction_checkpoints_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "subagent_logical_workers"("id"),
	CONSTRAINT "compaction_checkpoints_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("attempt_id") REFERENCES "subagent_attempts"("id"),
	CONSTRAINT "compaction_checkpoints_actor_kind_check" CHECK ("actor_kind" IS NULL OR "actor_kind" IN ('main','worker')),
	CONSTRAINT "compaction_checkpoints_usage_source_check" CHECK ("usage_source" IS NULL OR "usage_source" IN ('measured','deterministic_fallback')),
	CONSTRAINT "compaction_checkpoints_tokens_check" CHECK (("context_limit" IS NULL OR "context_limit" > 0) AND ("output_reserve_tokens" IS NULL OR "output_reserve_tokens" >= 0) AND ("provider_reserve_tokens" IS NULL OR "provider_reserve_tokens" >= 0) AND ("before_tokens" IS NULL OR "before_tokens" >= 0) AND ("after_tokens" IS NULL OR "after_tokens" >= 0)),
	CONSTRAINT "compaction_checkpoints_ledger_check" CHECK ("ledger_version" IS NULL OR "ledger_version" > 0),
	CONSTRAINT "compaction_checkpoints_digest_check" CHECK ("request_digest" IS NULL OR "request_digest" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "compaction_checkpoints_continuation_check" CHECK ("continuation" IS NULL OR "continuation" = 'continuing_existing_task'),
	CONSTRAINT "compaction_checkpoints_shape_check" CHECK (
		("actor_kind" IS NULL AND "actor_id" IS NULL AND "root_task_run_id" IS NULL AND "logical_worker_id" IS NULL AND "attempt_id" IS NULL AND "request_digest" IS NULL AND "model" IS NULL AND "context_limit" IS NULL AND "output_reserve_tokens" IS NULL AND "provider_reserve_tokens" IS NULL AND "before_tokens" IS NULL AND "after_tokens" IS NULL AND "usage_source" IS NULL AND "ledger_version" IS NULL AND "ledger" IS NULL AND "summary" IS NULL AND "continuation" IS NULL AND "created_at" IS NULL)
		OR
		("root_task_run_id" IS NOT NULL AND "actor_id" IS NOT NULL AND "request_digest" IS NOT NULL AND "model" IS NOT NULL AND "context_limit" IS NOT NULL AND "output_reserve_tokens" IS NOT NULL AND "provider_reserve_tokens" IS NOT NULL AND "before_tokens" IS NOT NULL AND "after_tokens" IS NOT NULL AND "usage_source" IS NOT NULL AND "ledger_version" IS NOT NULL AND "ledger" IS NOT NULL AND "summary" IS NOT NULL AND "continuation" IS NOT NULL AND "created_at" IS NOT NULL AND
			(("actor_kind" = 'main' AND "actor_id" = 'main' AND "logical_worker_id" IS NULL AND "attempt_id" IS NULL) OR
			 ("actor_kind" = 'worker' AND "logical_worker_id" IS NOT NULL AND "attempt_id" IS NOT NULL AND "actor_id" = "logical_worker_id"::text)))
	)
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "compaction_cursors" (
	"session_id" char(36) NOT NULL,
	"root_task_run_id" char(36) NOT NULL,
	"actor_kind" text NOT NULL,
	"actor_id" text NOT NULL,
	"logical_worker_id" char(36),
	"attempt_id" char(36),
	"checkpoint_id" char(36),
	"compaction_id" char(36),
	"cutoff_cursor" text,
	"cutoff_message_id" char(36),
	"ledger_version" integer DEFAULT 0 NOT NULL,
	"pending_recall_cursor" text,
	"continuation" text DEFAULT 'continuing_existing_task' NOT NULL,
	"updated_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "compaction_cursors_session_id_root_task_run_id_actor_kind_actor_id_pk" PRIMARY KEY("session_id","root_task_run_id","actor_kind","actor_id"),
	CONSTRAINT "compaction_cursors_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "sessions"("id") ON DELETE cascade,
	CONSTRAINT "compaction_cursors_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "runs"("id"),
	CONSTRAINT "compaction_cursors_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "subagent_logical_workers"("id"),
	CONSTRAINT "compaction_cursors_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("attempt_id") REFERENCES "subagent_attempts"("id"),
	CONSTRAINT "compaction_cursors_checkpoint_id_compaction_checkpoints_checkpoint_id_fk" FOREIGN KEY ("checkpoint_id") REFERENCES "compaction_checkpoints"("checkpoint_id"),
	CONSTRAINT "compaction_cursors_actor_check" CHECK (("actor_kind" = 'main' AND "actor_id" = 'main' AND "logical_worker_id" IS NULL AND "attempt_id" IS NULL) OR ("actor_kind" = 'worker' AND "logical_worker_id" IS NOT NULL AND "attempt_id" IS NOT NULL AND "actor_id" = "logical_worker_id"::text)),
	CONSTRAINT "compaction_cursors_ledger_check" CHECK ("ledger_version" >= 0),
	CONSTRAINT "compaction_cursors_continuation_check" CHECK ("continuation" = 'continuing_existing_task')
);--> statement-breakpoint

CREATE TABLE IF NOT EXISTS "compaction_history_items" (
	"position" bigserial PRIMARY KEY NOT NULL,
	"session_id" char(36) NOT NULL,
	"root_task_run_id" char(36),
	"logical_worker_id" char(36),
	"attempt_id" char(36),
	"kind" text NOT NULL,
	"stable_id" text NOT NULL,
	"event_cursor" text NOT NULL,
	"inline_payload" jsonb,
	"object_ref" text,
	"byte_length" bigint NOT NULL,
	"occurred_at" timestamp (3) with time zone,
	"recorded_at" timestamp (3) with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "compaction_history_items_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "sessions"("id") ON DELETE cascade,
	CONSTRAINT "compaction_history_items_root_task_run_id_runs_id_fk" FOREIGN KEY ("root_task_run_id") REFERENCES "runs"("id"),
	CONSTRAINT "compaction_history_items_logical_worker_id_subagent_logical_workers_id_fk" FOREIGN KEY ("logical_worker_id") REFERENCES "subagent_logical_workers"("id"),
	CONSTRAINT "compaction_history_items_attempt_id_subagent_attempts_id_fk" FOREIGN KEY ("attempt_id") REFERENCES "subagent_attempts"("id"),
	CONSTRAINT "compaction_history_kind_check" CHECK ("kind" IN ('message','tool_call','approval','artifact','file','logical_worker','attempt','checkpoint','compaction','event','control')),
	CONSTRAINT "compaction_history_payload_check" CHECK (("inline_payload" IS NOT NULL AND "object_ref" IS NULL) OR ("inline_payload" IS NULL AND "object_ref" IS NOT NULL)),
	CONSTRAINT "compaction_history_bytes_check" CHECK ("byte_length" >= 0),
	CONSTRAINT "compaction_history_lineage_check" CHECK ("attempt_id" IS NULL OR "logical_worker_id" IS NOT NULL)
);--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "compaction_checkpoints_compaction_uq" ON "compaction_checkpoints" ("compaction_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "compaction_checkpoints_request_uq" ON "compaction_checkpoints" ("session_id","root_task_run_id","actor_kind","actor_id","request_digest");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_checkpoints_scope_idx" ON "compaction_checkpoints" ("session_id","root_task_run_id","actor_kind","actor_id","created_at","checkpoint_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_cursors_worker_idx" ON "compaction_cursors" ("session_id","logical_worker_id","root_task_run_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_cursors_checkpoint_idx" ON "compaction_cursors" ("checkpoint_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "compaction_history_identity_uq" ON "compaction_history_items" ("session_id","kind","stable_id","event_cursor");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_history_scope_position_idx" ON "compaction_history_items" ("session_id","root_task_run_id","logical_worker_id","attempt_id","position");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_history_reference_idx" ON "compaction_history_items" ("session_id","kind","stable_id","position");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "compaction_history_event_cursor_idx" ON "compaction_history_items" ("session_id","event_cursor","position");--> statement-breakpoint

-- Existing compaction state remains canonical. The additive row records only a
-- reference and deliberately leaves unevidenced lineage, timing, model, ledger
-- version and all usage measurements NULL. Legacy summary text is not copied.
WITH "legacy" AS (
	SELECT "session_id", "state"->'compaction' AS "compaction"
	FROM "session_agent_state"
	WHERE "state"->'compaction' IS NOT NULL
	  AND "state"->'compaction' <> 'null'::jsonb
), "identified" AS (
	SELECT
		"session_id", "compaction",
		(substr(md5('0039-checkpoint:' || "session_id"),1,8) || '-' || substr(md5('0039-checkpoint:' || "session_id"),9,4) || '-' || substr(md5('0039-checkpoint:' || "session_id"),13,4) || '-' || substr(md5('0039-checkpoint:' || "session_id"),17,4) || '-' || substr(md5('0039-checkpoint:' || "session_id"),21,12))::char(36) AS "checkpoint_id",
		(substr(md5('0039-compaction:' || "session_id"),1,8) || '-' || substr(md5('0039-compaction:' || "session_id"),9,4) || '-' || substr(md5('0039-compaction:' || "session_id"),13,4) || '-' || substr(md5('0039-compaction:' || "session_id"),17,4) || '-' || substr(md5('0039-compaction:' || "session_id"),21,12))::char(36) AS "compaction_id"
	FROM "legacy"
)
INSERT INTO "compaction_checkpoints"
	("checkpoint_id", "compaction_id", "session_id", "cutoff_cursor", "cutoff_message_id", "active_state", "created_at")
SELECT
	"checkpoint_id", "compaction_id", "session_id",
	CASE WHEN jsonb_typeof("compaction"->'cutoffMessageId') = 'string' AND EXISTS (
		SELECT 1 FROM "messages" m WHERE m."id" = "compaction"->>'cutoffMessageId' AND m."session_id" = "identified"."session_id"
	) THEN "compaction"->>'cutoffMessageId' ELSE NULL END,
	CASE WHEN jsonb_typeof("compaction"->'cutoffMessageId') = 'string' AND EXISTS (
		SELECT 1 FROM "messages" m WHERE m."id" = "compaction"->>'cutoffMessageId' AND m."session_id" = "identified"."session_id"
	) THEN "compaction"->>'cutoffMessageId' ELSE NULL END,
	jsonb_build_object(
		'legacyStateRef', 'postgres:session_agent_state/' || "session_id" || '#compaction',
		'compactedAtCount', COALESCE("compaction"->'compactedAtCount', 'null'::jsonb)
	),
	NULL
FROM "identified"
ON CONFLICT ("checkpoint_id") DO NOTHING;--> statement-breakpoint

-- One ordered UNION preserves stable legacy chronology. Every payload is a
-- reference to an existing canonical row; no message, tool result, approval,
-- artifact, deferred prompt, control instruction or legacy summary is copied
-- into the new store. Root/worker/attempt lineage is filled only from exact IDs.
WITH "source" AS (
	SELECT
		m."session_id",
		COALESCE("attempt"."root_task_run_id", "prompt_root"."root_task_run_id") AS "root_task_run_id",
		"attempt"."logical_worker_id", "attempt"."attempt_id",
		'message'::text AS "kind", m."id"::text AS "stable_id", m."id"::text AS "event_cursor",
		'postgres:messages/' || m."id" AS "object_ref",
		octet_length(jsonb_build_object('id',m.id,'sessionId',m.session_id,'role',m.role,'content',m.content,'reasoning',m.reasoning,'clientMsgId',m.client_msg_id,'createdAt',m.created_at)::text)::bigint AS "byte_length",
		m."created_at" AS "occurred_at"
	FROM "messages" m
	LEFT JOIN LATERAL (
		SELECT
			CASE WHEN count(*) = 1 THEN min(a."root_task_run_id") ELSE NULL END AS "root_task_run_id",
			CASE WHEN count(*) = 1 THEN min(a."logical_worker_id") ELSE NULL END AS "logical_worker_id",
			CASE WHEN count(*) = 1 THEN min(a."id") ELSE NULL END AS "attempt_id"
		FROM "subagent_attempts" a
		WHERE a."prompt_message_id" = m."id" AND a."child_session_id" = m."session_id"
	) "attempt" ON true
	LEFT JOIN LATERAL (
		SELECT CASE WHEN count(*) = 1 AND bool_and("candidate"."is_main_run")
			THEN min("candidate"."root_task_run_id") ELSE NULL END AS "root_task_run_id"
		FROM (
			SELECT r."id" AS "root_task_run_id",
				NOT EXISTS (
					SELECT 1 FROM "subagent_attempts" child_attempt
					WHERE child_attempt."child_run_id" = r."id"
				) AS "is_main_run"
			FROM "runs" r
			WHERE r."prompt_message_id" = m."id" AND r."session_id" = m."session_id"
		) "candidate"
	) "prompt_root" ON true

	UNION ALL
	SELECT
		COALESCE("run_attempt"."child_session_id", "payload_attempt"."child_session_id", e."session_id"),
		COALESCE(
			"run_attempt"."root_task_run_id", "payload_attempt"."root_task_run_id",
			CASE WHEN r."session_id" = e."session_id" AND "run_attempt"."id" IS NULL
				AND "payload_attempt"."id" IS NULL AND e."payload"->>'attemptId' IS NULL
				THEN r."id" ELSE NULL END
		),
		COALESCE("run_attempt"."logical_worker_id", "payload_attempt"."logical_worker_id"),
		COALESCE("run_attempt"."id", "payload_attempt"."id"),
		'event', e."seq", e."seq",
		'postgres:session_event_mirror/' || e."session_id" || '/' || e."seq",
		octet_length(e."payload"::text)::bigint, e."ts"
	FROM "session_event_mirror" e
	LEFT JOIN "runs" r ON r."id" = e."payload"->>'runId'
	LEFT JOIN "subagent_attempts" "run_attempt" ON "run_attempt"."child_run_id" = r."id"
		AND "run_attempt"."session_id" = e."session_id"
	LEFT JOIN "subagent_attempts" "payload_attempt" ON "payload_attempt"."id" = e."payload"->>'attemptId'
		AND "payload_attempt"."session_id" = e."session_id"
		AND (r."id" IS NULL OR "payload_attempt"."child_run_id" = r."id")

	UNION ALL
	SELECT
		COALESCE(a."child_session_id", q."session_id"),
		COALESCE(a."root_task_run_id", CASE WHEN r."session_id" = q."session_id" AND a."id" IS NULL THEN q."run_id" ELSE NULL END),
		a."logical_worker_id", a."id", 'approval', q."request_id", q."request_id",
		'postgres:system_requests/' || q."request_id", octet_length(q."safe_payload"::text)::bigint, q."created_at"
	FROM "system_requests" q
	LEFT JOIN "runs" r ON r."id" = q."run_id"
	LEFT JOIN "subagent_attempts" a ON a."child_run_id" = q."run_id" AND a."session_id" = q."session_id"

	UNION ALL
	SELECT
		COALESCE("attempt"."child_session_id", q."session_id"),
		COALESCE("attempt"."root_task_run_id", CASE WHEN "approval_run"."session_id" = q."session_id" AND "attempt"."id" IS NULL THEN q."run_id" ELSE NULL END),
		"attempt"."logical_worker_id", "attempt"."id", 'approval', "response"."response_id", "response"."response_id",
		'postgres:system_request_responses/' || "response"."response_id",
		octet_length(COALESCE("response"."response"::text, "response"."response_digest"))::bigint, "response"."created_at"
	FROM "system_request_responses" "response"
	INNER JOIN "system_requests" q ON q."request_id" = "response"."request_id"
	LEFT JOIN "runs" "approval_run" ON "approval_run"."id" = q."run_id"
	LEFT JOIN "subagent_attempts" "attempt" ON "attempt"."child_run_id" = q."run_id" AND "attempt"."session_id" = q."session_id"

	UNION ALL
	SELECT
		w."session_id", NULL, NULL, NULL,
		CASE WHEN w."kind" = 'artifact' THEN 'artifact' ELSE 'file' END,
		w."id", w."id", 'postgres:workspace_objects/' || w."id", w."bytes", w."created_at"
	FROM "workspace_objects" w
	WHERE w."session_id" IS NOT NULL

	UNION ALL
	SELECT
		COALESCE("run_attempt"."child_session_id", f."session_id"),
		COALESCE("run_attempt"."root_task_run_id", CASE WHEN r."session_id" = f."session_id" AND "run_attempt"."id" IS NULL THEN "prompt_root"."root_task_run_id" ELSE NULL END),
		"run_attempt"."logical_worker_id", "run_attempt"."id", 'file', f."id", f."id",
		'postgres:attachments/' || f."id", COALESCE(f."actual_bytes", f."size")::bigint, f."created_at"
	FROM "attachments" f
	LEFT JOIN LATERAL (
		SELECT CASE WHEN count(*) = 1 THEN min(r."id"::text)::char(36) ELSE NULL END AS "root_task_run_id"
		FROM "runs" r WHERE r."prompt_message_id" = f."message_id" AND r."session_id" = f."session_id"
	) "prompt_root" ON true
	LEFT JOIN "runs" r ON r."id" = "prompt_root"."root_task_run_id"
	LEFT JOIN "subagent_attempts" "run_attempt" ON "run_attempt"."child_run_id" = r."id"

	UNION ALL
	SELECT
		w."session_id", w."current_root_task_run_id", w."id", NULL, 'logical_worker', w."id", w."id",
		'postgres:subagent_logical_workers/' || w."id", 0::bigint, w."created_at"
	FROM "subagent_logical_workers" w

	UNION ALL
	SELECT
		a."session_id", a."root_task_run_id", a."logical_worker_id", a."id", 'attempt', a."id", a."id",
		'postgres:subagent_attempts/' || a."id", 0::bigint, a."created_at"
	FROM "subagent_attempts" a

	UNION ALL
	SELECT
		c."session_id", c."root_task_run_id", c."logical_worker_id", c."attempt_id", 'checkpoint', c."id", c."id",
		'postgres:subagent_checkpoints/' || c."id", octet_length(c."hash")::bigint, c."verified_at"
	FROM "subagent_checkpoints" c

	UNION ALL
	SELECT
		c."session_id", c."root_task_run_id", c."logical_worker_id", c."source_attempt_id", 'control', c."id", c."id",
		'postgres:subagent_control_audit/' || c."id",
		COALESCE(octet_length(c."metadata"::text), 0)::bigint, c."created_at"
	FROM "subagent_control_audit" c

	UNION ALL
	SELECT
		d."session_id", d."root_task_run_id", NULL, NULL, 'control', d."id", d."id",
		'postgres:subagent_dispatches/' || d."id", 0::bigint, d."created_at"
	FROM "subagent_dispatches" d

	UNION ALL
	SELECT
		l."session_id", NULL, NULL, NULL, 'checkpoint', c."checkpoint_id", c."checkpoint_id",
		'postgres:session_agent_state/' || l."session_id" || '#compaction',
		octet_length((l."state"->'compaction')::text)::bigint, NULL
	FROM "session_agent_state" l
	INNER JOIN "compaction_checkpoints" c ON c."session_id" = l."session_id" AND c."actor_kind" IS NULL
	WHERE l."state"->'compaction' IS NOT NULL AND l."state"->'compaction' <> 'null'::jsonb

	UNION ALL
	SELECT
		l."session_id", NULL, NULL, NULL, 'compaction', c."compaction_id", c."compaction_id",
		'postgres:session_agent_state/' || l."session_id" || '#compaction',
		octet_length((l."state"->'compaction')::text)::bigint, NULL
	FROM "session_agent_state" l
	INNER JOIN "compaction_checkpoints" c ON c."session_id" = l."session_id" AND c."actor_kind" IS NULL
	WHERE l."state"->'compaction' IS NOT NULL AND l."state"->'compaction' <> 'null'::jsonb
)
INSERT INTO "compaction_history_items"
	("session_id", "root_task_run_id", "logical_worker_id", "attempt_id", "kind", "stable_id", "event_cursor", "object_ref", "byte_length", "occurred_at")
SELECT "session_id", "root_task_run_id", "logical_worker_id", "attempt_id", "kind", "stable_id", "event_cursor", "object_ref", "byte_length", "occurred_at"
FROM "source"
ORDER BY "occurred_at" NULLS LAST, "kind", "stable_id", "event_cursor"
ON CONFLICT ("session_id", "kind", "stable_id", "event_cursor") DO NOTHING;
