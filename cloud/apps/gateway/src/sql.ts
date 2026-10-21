/**
 * SQL literal escaping for the few places a route must run a raw statement
 * through drizzle's `execute()` (which takes no bind parameters).
 *
 * PostgreSQL (with the default `standard_conforming_strings = on`) needs only
 * doubled single quotes inside a standard '…' literal. Callers must use this
 * for EVERY interpolated value — never template a raw value into SQL.
 *
 * These statements exist because the quota checks (shares, reports) must run
 * in the SAME transaction as the insert, and the db package's repos take a
 * `Db`, not a transaction handle. Prefer a repo method whenever one exists.
 */
export function sqlText(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}
