import type { Db } from "@ovid/db";

export interface CollabAccountFence {
  fenceAccount(uid: string, connection?: Db): Promise<void>;
}

/** Account cleanup may call this at pending and again at every final retry. */
export class CollabLifecycle {
  constructor(private readonly membership: CollabAccountFence) {}

  async onDeletionPending(uid: string, connection?: Db): Promise<void> {
    await this.membership.fenceAccount(uid, connection);
  }
}
