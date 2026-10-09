# Private account activity sync — SUPERSEDED

**Status:** Superseded. This draft is non-normative. Use the two normative
specifications dated 2026-10-08:

- [Private account sync](2026-10-08-private-account-sync-design.md) — typed
  records, storage, identity, quotas, and deletion.
- [Device activity feed](2026-10-08-device-activity-feed-design.md) — inert
  activity records, ordering, and foreground delivery.

Usage identity mapping: for usage records, `recordId = attemptId`;
`logicalRequestId` groups attempts. An activity record's `usageRecordId`
references the usage record's `recordId`. Delivery retries reuse that identity;
a new outbound provider attempt has a new `attemptId`.

This pointer authorizes no production implementation or endpoint activation.
