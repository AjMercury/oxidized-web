## [P2] Manual backup progress: cover a text authentication-error response

**Source:** Test Audit, final release verification (`.cortex/reviews/release-test-audit.md`, P2-001)
**Severity:** P2
**Module:** `lib/oxidized/web/public/scripts/backups.js`

### Description

The progress request helper checks the response content type and displays refresh/sign-in guidance when authentication middleware returns text. No focused test currently exercises that branch. Successful JSON responses, service-restart unavailable state, and continued polling across a restored completed selection are covered.

### Context

This is optional follow-up coverage. Source inspection confirms the non-JSON branch produces actionable guidance and does not increment completion; no current blocking defect was found.

### Suggested approach

Extend `spec/js/backups.test.js` with a text 401 or 403 fetch response. Assert the summary instructs the administrator to refresh/sign in and does not display a JSON parsing exception or claim success. Assert that no queue mutation is retried automatically.

### Acceptance criteria

- A deterministic test returns a non-JSON 401/403 response and verifies the user-facing guidance.
- The assertion fails if content-type handling is removed or the response is treated as a successful backup.
- The JavaScript suite passes without timing sleeps or a live authentication service.
