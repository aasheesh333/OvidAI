import {
  sessions,
  studioRepos,
  type Db,
  type StudioRepoBinding,
  type StudioRepoUpsert,
} from "@ovid/db";

export interface StudioRunBindingIdentity {
  userId: string;
  sessionId: string;
}

export interface StudioRunBindingPort {
  get(identity: StudioRunBindingIdentity): Promise<StudioRepoBinding | null>;
  upsert(identity: StudioRunBindingIdentity, input: StudioRepoUpsert): Promise<StudioRepoBinding | null>;
  compareAndSetBranch(
    identity: StudioRunBindingIdentity,
    expected: StudioRepoBinding,
    branch: string,
  ): Promise<StudioRepoBinding | null>;
}

/** Unknown and foreign sessions deliberately have the same public refusal. */
export class StudioRunBindingError extends Error {
  readonly name = "StudioRunBindingError";
  readonly code = "not_found" as const;

  constructor() {
    super("Session not found.");
  }
}

/**
 * The run-scoped view of the existing Studio binding table. There is no run
 * binding sidecar: every operation re-verifies session ownership and every
 * branch write is scoped to the exact repo/dir/branch that authorized Git.
 */
export class StudioRunBinding implements StudioRunBindingPort {
  constructor(private readonly db: Db) {}

  private async verify(identity: StudioRunBindingIdentity): Promise<void> {
    const session = await sessions.get(this.db, identity.sessionId, identity.userId);
    if (session === null) throw new StudioRunBindingError();
  }

  async get(identity: StudioRunBindingIdentity): Promise<StudioRepoBinding | null> {
    await this.verify(identity);
    return studioRepos.get(this.db, identity.userId, identity.sessionId);
  }

  async upsert(
    identity: StudioRunBindingIdentity,
    input: StudioRepoUpsert,
  ): Promise<StudioRepoBinding | null> {
    await this.verify(identity);
    return studioRepos.upsert(this.db, {
      ...input,
      userId: identity.userId,
      sessionId: identity.sessionId,
    });
  }

  async compareAndSetBranch(
    identity: StudioRunBindingIdentity,
    expected: StudioRepoBinding,
    branch: string,
  ): Promise<StudioRepoBinding | null> {
    await this.verify(identity);
    const rows = await this.db.$client`
      UPDATE studio_repos
         SET branch = ${branch}, updated_at = NOW()
       WHERE session_id = ${identity.sessionId}
         AND user_id = ${identity.userId}
         AND repo = ${expected.repo}
         AND repo_dir = ${expected.repoDir}
         AND branch = ${expected.branch}
      RETURNING session_id AS "sessionId",
                user_id AS "userId",
                repo,
                repo_dir AS "repoDir",
                branch,
                created_at AS "createdAt",
                updated_at AS "updatedAt"
    `;
    return (rows[0] as unknown as StudioRepoBinding | undefined) ?? null;
  }
}
