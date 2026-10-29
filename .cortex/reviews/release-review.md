## Code Review: Manual backups, Core queue integration, and Midnight Violet theme

**Files reviewed:** `lib/oxidized/web/webapp.rb`, `lib/oxidized/web/public/scripts/backups.js`, `lib/oxidized/web/public/scripts/app-shell.js`, `lib/oxidized/web/public/css/oxidized.css`, `lib/oxidized/web/views/backup_all.haml`, `lib/oxidized/web/views/layout.haml`, `lib/oxidized/web/views/nodes.haml`, `lib/oxidized/web/views/node.haml`, `lib/oxidized/web/views/devices.haml`, `lib/oxidized/web/version.rb`, `oxidized-web.gemspec`, `.github/Gemfile.ci`, `.github/workflows/ruby.yml`, `DESIGN.md`, `D:/Projects/oxidized-core/lib/oxidized/nodes.rb`, `D:/Projects/oxidized-core/lib/oxidized/nodes/manual_backup_queue.rb`, `D:/Projects/oxidized-core/lib/oxidized/worker.rb`, `D:/Projects/oxidized-core/lib/oxidized/jobs.rb`, `D:/Projects/oxidized-core/lib/oxidized/node.rb`
**Iteration:** 3 of 3 (final remediation verification; fresh-context Codex fallback, no external providers)

### Findings

_No findings._

### Summary
- P0: 0 findings (MUST fix)
- P1: 0 findings (MUST fix)
- P2: 0 findings (file issues)
- P3: 0 findings (file issues)
- The timestamp-based Web fallback has been removed. Unsupported Core versions receive a JSON 409, while the supported path obtains terminal results from Core after worker processing. Core queue dispatch and enqueue share the inventory mutex; manual requests do not increment its concurrency budget; retry and replaced-node guards were inspected. Grouped legacy POST requests now pass bare node names, and modern bulk/PUT paths delegate to the same queue API. Administrator and shared CSRF/origin checks precede queue mutations.
- Dark outline hover/active contrast and DataTables pagination now use the palette's accent/contrast tokens. The previous contrast finding is resolved.
- Final visual-validation changes were inspected: counters display their finite backend data-counter value immediately, login surfaces/labels/inputs and its eyebrow use the active theme's tokens, and primary/outline buttons switch foreground/background together without a background-color transition. The browser contrast check waits for remaining finite animations before reading computed colors. The light-login eyebrow oversight found during this pass was corrected and verified in source.
- CI uses the project gemspec through `.github/Gemfile.ci`, installs native build dependencies, and runs JavaScript tests with Node 24. The pinned companion SHA `bd03b9ba29c927af87e95ee9503088a7c3e4441d` was inspected locally and contains Core 0.37.3 plus the reviewed queue module and stale-inventory guard. Remote CI execution is still required.
- Polling now continues while any returned device is active, fixing stale completed selections that left another active device's button disabled. The new regression test verifies re-enabling after completion.
- `ManualBackupQueue` extraction preserves public queue/status methods and its private status helper, using Nodes' existing inventory mutex. `next_job` remains atomic in Nodes. Completion now checks both the record's node identity and the current inventory's object identity under the same lock, so removed/replaced worker objects cannot create a fresh terminal result.
- Tests were audited separately in `release-test-audit.md`. The new Worker retry/storage-barrier and current-inventory regression tests close the P1 lifecycle gap; implementer reports 7 queue tests/32 assertions and 6 RouterOS tests/45 assertions passed. This reviewer executed the JavaScript suite (15 passed) and syntax checks for the restart/theme browser additions. The final PUT/bulk route regressions, restart state assertions, real changed-config diff, and computed control-contrast assertions were inspected; no blocking test-quality issues were found.
- Implementer reports the main browser workflow and restart scenario passed, and a Web checkpoint passed 131 tests/630 assertions with 4 Windows-specific skips. This reviewer reran JavaScript tests after the counter/theme changes: 15 passed. The theme/screenshot browser rerun and final Web rerun were still pending when this artifact was updated. The full Core suite is not green (17 failures/9 errors reported by the implementer as baseline); CLEAN is the scoped source-review verdict, not a claim of full-suite success.
- **Verdict:** CLEAN
