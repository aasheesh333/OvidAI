export interface FetchSanitizedFixture {
  request: { url: string; max_length: number };
  successBody: string;
  expectedText: string;
  canary: string;
  failureStatus: number;
  failureBody: string;
}

const CANARY = "synthetic-fetch-fixture-canary";

/** Synthetic public-web data only; the canary is not a credential. */
export const FETCH_SANITIZED_FIXTURE = {
  request: { url: "https://example.com/", max_length: 24 },
  successBody:
    `<script>authorization: Bearer ${CANARY}</script>` +
    "<h1>Public fixture</h1><p>abcdefghijklmnopqrstuvwxyz</p>",
  expectedText: "# Publi\n\n... [truncated]",
  canary: CANARY,
  failureStatus: 503,
  failureBody: `upstream authorization: Bearer ${CANARY}`,
} satisfies FetchSanitizedFixture;
