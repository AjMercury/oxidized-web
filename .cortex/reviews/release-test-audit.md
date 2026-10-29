## Test Gap Report: Manual backup release

**Module:** `lib/oxidized/web` and related Core manual queue/worker integration
**Tests:** `spec/web/manual_backups_spec.rb`, `spec/web/node_spec.rb`, `spec/web/admin_devices_spec.rb`, `spec/js/backups.test.js`, `spec/browser/manual-backups.cjs`, `spec/browser/backup-restart.cjs`, `spec/browser/theme-screenshots.cjs`, `spec/support/manual_backup_server.rb`, `D:/Projects/oxidized-core/spec/manual_backups_spec.rb`, `D:/Projects/oxidized-core/spec/model/routeros_spec.rb`
**Mode:** diff

### Behavior Inventory

Behaviors introduced or modified by this diff:

| Behavior | Coverage | Evidence |
|----------|----------|----------|
| Queue all configured devices independently of visible table rows | Covered | API sends nil selection to Core; browser expects all 23 devices from a paginated table. |
| Deduplicate selected names and include off-page selections | Covered | API asserts unique one/two names; browser selects device-2 and device-22 through the full DataTables collection. |
| Repeated active requests retain one manual request | Covered | Core spec compares repeated queue responses and suppresses redispatch of a running node; browser compares requested_at values. |
| Forward Core status and finish only after actual retries and output handling | Covered | Added Core test calls real Worker#process for failure/retry then success, blocks output.store with Queue barriers, and asserts active before storage returns and succeeded afterward. Implementer reports this test passed. Browser covers exhausted failure with retries=0. |
| Ignore completion from an object removed or replaced in the current inventory | Covered | Core regression test replaces the node object and expects unknown after old-node completion. This caught the stale-inventory bug; final identity guard was inspected and implementer reports all 7 queue tests/32 assertions passed. |
| Deny viewer mutations and invalid CSRF before queueing | Covered | API forbids queue_backups calls; browser checks viewer 403 and absence of global action. Shared authentication specs cover missing-token behavior. |
| Return actionable unsupported-Core status | Covered | New API spec checks POST and GET 409 when queue/status methods are absent. |
| Preserve grouped legacy action identity with modern Core | Covered | New grouped legacy POST test expects queue_backups(['one']). |
| Preserve metadata through modern Core delegation for legacy PUT | Covered | Added grouped PUT spec expects queue_backups(['one'], parsed metadata) and HTTP 200, exercising the modern delegation branch. |
| Delegate no-JS bulk POST to the shared queue | Covered | Added administrator-device spec expects one queue_backups call and asserts the legacy backup_requests collection remains empty. |
| Avoid extra Git revisions for identical successful collections | Covered | Browser repeats device-1 through the real worker/Git fixture and checks one revision; RouterOS tests use the production Git output path for timestamp normalization. |
| Resume tracking and keep all device buttons synchronized after navigation | Covered | New backups.js regression test restores a completed selection, returns another running node, verifies a subsequent poll, then verifies that node's button is enabled at completion. Reviewer ran the test successfully as part of 15 passing JS tests. |
| Handle unavailable tracking after a service restart without losing history/authentication | Covered | backup-restart.cjs restores saved authentication and a tracked device, asserts not_requested for all devices, unavailable summary/results, and unchanged revision count 1 after the externally orchestrated restart. |
| Handle non-JSON polling authentication errors | Missing | No focused test exercises a text authentication-error response in the new progress flow. |
| Apply theme contrast tokens to representative filled, outline-hover, and active pagination controls | Covered | theme-screenshots.cjs computes actual rendered foreground/background contrast >=4.5 in both themes, captures 84 screenshots across 7 pages/6 sizes/2 themes, and checks page overflow on the six authenticated pages. |

### Prioritized Gaps

#### P2-001: Test non-JSON authentication error state
**Behavior:** Progress handles a text authentication-error response with actionable reload/sign-in guidance.
**Status:** Missing
**Why it matters:** Restart handling is now covered, but middleware can still return non-JSON 401/403 responses and the content-type branch has no direct regression assertion.
**Suggested test approach:** Return a text 401/403 and assert refresh/sign-in guidance rather than success or a JSON parse error. Follow-up: `.cortex/fixes/release-test-followups.md`.

### Summary
- Covered: 14
- Shallow: 0
- Missing: 1
- P0: 0
- P1: 0
- P2: 1
