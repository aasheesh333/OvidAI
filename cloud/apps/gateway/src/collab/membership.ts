import {
  CollabError,
  CollabRepos,
  type CollabAuthorization,
  type CollabInviteResult,
  type CollabJoinResult,
  type CollabRoomResult,
  type CollabSessionDto,
  type Db,
} from "@ovid/db";
import type { DeletionSession } from "@ovid/account";
import type { AuthPrincipal } from "../auth.js";

export { CollabError as CollabMembershipError } from "@ovid/db";
export type { CollabAuthorization, CollabInviteResult, CollabJoinResult, CollabRoomResult } from "@ovid/db";

export type AccountAdmission = <T>(
  principal: AuthPrincipal,
  fn: (uid: string, session?: DeletionSession) => Promise<T>,
) => Promise<T>;

export interface CollabMembershipOptions {
  authoritySecret: string;
  admission?: AccountAdmission;
}

/** All authority comes from the verified principal and opaque server tokens. */
export class CollabMembership {
  private readonly repos: CollabRepos;
  private readonly admission?: AccountAdmission;

  constructor(db: Db, options: CollabMembershipOptions) {
    this.repos = new CollabRepos(db, { authoritySecret: options.authoritySecret });
    this.admission = options.admission;
  }

  private displayName(principal: AuthPrincipal): string | null {
    const local = principal.email?.split("@", 1)[0]?.trim() ?? "";
    return local === "" ? null : local.slice(0, 80);
  }

  private async run<T>(
    principal: AuthPrincipal,
    fn: (repos: CollabRepos, uid: string) => Promise<T>,
  ): Promise<T> {
    if (this.admission !== undefined) {
      return this.admission(principal, (uid, session) => {
        if (session?.db === undefined) {
          throw new Error("collaboration admission did not provide its reserved DB session");
        }
        return fn(this.repos.admitted(session.db), uid);
      });
    }
    return fn(this.repos, principal.uid);
  }

  async createRoom(input: {
    principal: AuthPrincipal;
    requestId: string;
    sessionId?: string;
  }): Promise<CollabRoomResult> {
    return this.run(input.principal, (repos, uid) => repos.createRoom({
      uid,
      requestId: input.requestId,
      sessionId: input.sessionId,
      email: input.principal.email,
      displayName: this.displayName(input.principal),
    }));
  }

  async createInvite(input: {
    principal: AuthPrincipal;
    token: string;
    idempotencyKey: string;
    maxUses: number;
    ttlSeconds: number;
  }): Promise<CollabInviteResult> {
    return this.run(input.principal, (repos, uid) => repos.createInvite({
      uid,
      token: input.token,
      idempotencyKey: input.idempotencyKey,
      maxUses: input.maxUses,
      ttlSeconds: input.ttlSeconds,
    }));
  }

  async revokeInvite(input: { principal: AuthPrincipal; token: string; inviteId: string }): Promise<void> {
    return this.run(input.principal, (repos, uid) => repos.revokeInvite({
      uid, token: input.token, inviteId: input.inviteId,
    }));
  }

  async join(input: {
    principal: AuthPrincipal;
    token: string;
    inviteCode: string;
    idempotencyKey: string;
  }): Promise<CollabJoinResult> {
    return this.run(input.principal, (repos, uid) => repos.join({
      uid,
      token: input.token,
      inviteCode: input.inviteCode,
      idempotencyKey: input.idempotencyKey,
      displayName: this.displayName(input.principal),
      email: input.principal.email,
    }));
  }

  async leave(input: { principal: AuthPrincipal; token: string }): Promise<CollabJoinResult> {
    return this.run(input.principal, (repos, uid) => repos.leave({ uid, token: input.token }));
  }

  async remove(input: {
    principal: AuthPrincipal;
    token: string;
    participantId: string;
  }): Promise<CollabJoinResult> {
    return this.run(input.principal, (repos, uid) => repos.remove({
      uid, token: input.token, participantId: input.participantId,
    }));
  }

  async close(input: {
    principal: AuthPrincipal;
    token: string;
    idempotencyKey: string;
  }): Promise<{ session: CollabSessionDto }> {
    return this.run(input.principal, (repos, uid) => repos.close({
      uid, token: input.token, idempotencyKey: input.idempotencyKey,
    }));
  }

  async authorize(input: { principal: AuthPrincipal; token: string }): Promise<CollabAuthorization> {
    return this.run(input.principal, (repos, uid) => repos.authorize({ uid, token: input.token }));
  }

  /** Administrative cleanup is idempotent and may run inside the account UID lock. */
  async fenceAccount(uid: string, connection?: Db): Promise<void> {
    await this.repos.admitted(connection).fenceAccount(uid);
  }
}

export { CollabError };
