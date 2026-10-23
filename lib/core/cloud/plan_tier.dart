/// The plan table's manual-model rule, in one place on the client.
///
/// The server is the enforcement point: `routes/messages.ts` refuses a named
/// model on an Auto-only tier with a 402, using
/// `manualModelsAllowed(user.tier)` from `cloud/packages/shared/src/plans.ts`.
/// This file is the client's copy of that resolution so the picker greys out
/// exactly the rows the send route would refuse.
///
/// The gateway's `GET /models` also reports the flag
/// (`manualModelsAllowed`). When that field is present it wins; this local
/// table is the fallback for a gateway that predates the field. Keep the two
/// in step — [ovidManualModelsAllowed] is the single entry point callers use.
library;

/// The four canonical plans, cheapest first.
enum OvidPlanId { free, go, plus, pro }

/// Every spelling the server resolves, and the plan it means.
///
/// `3x` / `7x` / `15x` are the values real `users.tier` rows hold (the mint
/// stored a plan's first alias). `starter` and `max` are older plan ids. The
/// canonical ids (`free|go|plus|pro`) are what the shared table stores now.
const Map<String, OvidPlanId> _plansByTier = <String, OvidPlanId>{
  'free': OvidPlanId.free,
  'go': OvidPlanId.go,
  'plus': OvidPlanId.plus,
  'pro': OvidPlanId.pro,
  'starter': OvidPlanId.go,
  '3x': OvidPlanId.go,
  '7x': OvidPlanId.plus,
  '15x': OvidPlanId.pro,
  'max': OvidPlanId.pro,
};

/// The plan a stored tier string means.
///
/// An unknown or missing tier is Free, matching `planFor` on the server: it
/// grants the least, so a typo can never hand out a paid allowance.
OvidPlanId ovidPlanIdFor(String? tier) =>
    _plansByTier[(tier ?? '').trim().toLowerCase()] ?? OvidPlanId.free;

/// The local table's answer: Free and Go are Auto-only; Plus and Pro may pin
/// a model. Use [ovidManualModelsAllowed] in UI code so the server's own
/// answer wins when it is available.
bool ovidManualModelsAllowedForTier(String? tier) =>
    switch (ovidPlanIdFor(tier)) {
      OvidPlanId.free || OvidPlanId.go => false,
      OvidPlanId.plus || OvidPlanId.pro => true,
    };

/// Whether this account may pick a named model.
///
/// [serverValue] is `manualModelsAllowed` from `GET /models`. It is computed
/// server-side from the same table the send route enforces, so it wins
/// whenever it is present — including when it disagrees with [tier] because
/// the local cache is stale. Null means the gateway predates the field (or we
/// have not heard from it yet); only then does the local table decide.
bool ovidManualModelsAllowed({
  required bool? serverValue,
  required String? tier,
}) => serverValue ?? ovidManualModelsAllowedForTier(tier);

/// The legacy spelling the rest of the app is keyed on (`free`, `3x`, `7x`,
/// `15x`).
///
/// `AppState.ovidCloudTier` predates canonical ids: every screen, product map
/// and storage table switches on the legacy values. Normalising whatever
/// `/usage.tier` reports into that vocabulary keeps a canonical `plus` from
/// being cached as Free, while the gate still resolves both spellings.
String ovidStoredTier(String? tier) => switch (ovidPlanIdFor(tier)) {
  OvidPlanId.free => 'free',
  OvidPlanId.go => '3x',
  OvidPlanId.plus => '7x',
  OvidPlanId.pro => '15x',
};
