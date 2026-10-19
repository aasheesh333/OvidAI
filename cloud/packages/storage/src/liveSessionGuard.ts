/**
 * Cross-session liveness guard for the PER-USER agent workspace (P0
 * data-loss fix).
 *
 * workspacePaths.ts pins the model: the agent workspace is
 * `{workspacesRoot}/{numericUid}/workspace` — ONE directory shared by EVERY
 * session of the user (P2's landed model). The primary engines both destroy
 * that dir keyed by a per-session job — hydrate's wipe-before-extract and
 * hibernate's pack-then-evict — while file_manifests rows and runs are
 * per-SESSION, so before this guard neither engine ever asked whether
 * ANOTHER session of the same user was live on the dir it was about to
 * `rm -rf`. warmLru.reclaimColdResidue has refused exactly this destroy with
 * its own comment ("P2's agent workspace is PER-USER … another session of
 * the same user may still be warm and using that dir. In that case the dir
 * is NOT residue — removing it would destroy a live workspace"); this module
 * gives the primary engines the same rule, and the warmLru guard stays in
 * place as defense in depth.
 *
 * "Live" is deliberately conservative and DB-only (no disk probing, no
 * activity reads — those are policy, not liveness):
 *  (a) a file_manifests row in state 'warm' for any OTHER session of the
 *      user: a warm row means a sibling session holds the dir as its data;
 *  (b) a run in queued|running status on any OTHER session of the user: the
 *      run's tools read and write the dir, so it is live even when no row
 *      is registered (a never-hibernated session has no row at all).
 *
 * Like the engines themselves, @ovid/db is consumed ONLY through the
 * structural mirrors below — @ovid/storage has no package edge on it (the
 * parallel-wave NO-lockfile rule). The real `fileManifests` /
 * `runs` repo namespaces satisfy `LiveSessionGuardDeps` structurally once
 * wired: `fileManifests.hasOtherWarmSession` and `runs.activeForUserExcept`
 * exist in @ovid/db for exactly this guard. Method syntax keeps the mirrors
 * bivariant-assignable (the same discipline as hibernate.ts's mirrors).
 */

/**
 * Opaque stand-in for @ovid/db's `Db` — threaded through to the repos, never
 * touched directly (same pattern as hibernate.ts's `DbLike`).
 */
export type GuardDbLike = unknown;

/**
 * The two repo reads the guard needs. `HydrateDeps` and `HibernateDeps`
 * satisfy this structurally: both carry a `fileManifests` mirror with
 * `hasOtherWarmSession` and a `runs` mirror with `activeForUserExcept`, so
 * callers pass their whole deps object.
 */
export interface LiveSessionGuardDeps {
  /** True iff another session of the user holds a WARM file_manifests row. */
  fileManifests: {
    hasOtherWarmSession(
      db: GuardDbLike,
      userId: string,
      exceptSessionId: string,
    ): Promise<boolean>;
  };
  /** Oldest queued|running run on any OTHER session of the user, or null. */
  runs: {
    activeForUserExcept(
      db: GuardDbLike,
      userId: string,
      exceptSessionId: string,
    ): Promise<unknown>;
  };
}

/**
 * True iff any OTHER session of `userId` is live on the shared per-user
 * workspace: a WARM file_manifests row OR a queued|running run. `deps` is
 * the caller's engine deps (see LiveSessionGuardDeps); `exceptSessionId` is
 * the session the caller is hydrating/hibernating — its own row/run is
 * never counted.
 */
export async function anotherLiveSessionOfUser(
  db: GuardDbLike,
  deps: LiveSessionGuardDeps,
  userId: string,
  exceptSessionId: string,
): Promise<boolean> {
  if (await deps.fileManifests.hasOtherWarmSession(db, userId, exceptSessionId)) {
    return true;
  }
  return (await deps.runs.activeForUserExcept(db, userId, exceptSessionId)) !== null;
}
