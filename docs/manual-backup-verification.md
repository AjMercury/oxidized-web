# Reproduce manual backup and theme verification on Ubuntu

Run this against the isolated fixture, never against production inventory. The fixture replaces device collection with synthetic text but uses the real Core scheduler, Git output, authentication, server routes and Chrome UI.

```sh
export BUNDLE_GEMFILE=.github/Gemfile.ci
bundle install
npm install --no-save --package-lock=false playwright@1.62.1
npx playwright install --with-deps chrome
mkdir -p tmp/backup-fixture tmp/backup-screenshots
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -keyout tmp/fixture-key.pem -out tmp/fixture-cert.pem
export CORE_LIB="$(bundle show oxidized)/lib"
export BACKUP_FIXTURE_DIR="$PWD/tmp/backup-fixture"
export BACKUP_TLS_KEY="$PWD/tmp/fixture-key.pem"
export BACKUP_TLS_CERT="$PWD/tmp/fixture-cert.pem"
export BACKUP_ORIGIN=https://127.0.0.1:45529
bundle exec ruby spec/support/manual_backup_server.rb >tmp/fixture.log 2>&1 &
FIXTURE_PID=$!
node spec/support/manual_backup_proxy.cjs >tmp/proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$FIXTURE_PID" "$PROXY_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 30); do
  curl -ksf "$BACKUP_ORIGIN/login" >/dev/null && break
  sleep 1
done
node spec/browser/manual-backups.cjs
kill "$FIXTURE_PID"
wait "$FIXTURE_PID" 2>/dev/null || true
bundle exec ruby spec/support/manual_backup_server.rb >tmp/fixture-restarted.log 2>&1 &
FIXTURE_PID=$!
for attempt in $(seq 1 30); do
  curl -ksf "$BACKUP_ORIGIN/login" >/dev/null && break
  sleep 1
done
node spec/browser/backup-restart.cjs
node spec/browser/theme-screenshots.cjs
```

Use a new empty `BACKUP_FIXTURE_DIR` for each independent run. The first browser scenario collects one device, all 23 devices (including off-page rows), and selected devices, verifies duplicate handling and real failure state, and checks Viewer/mobile behavior. It verifies that the repeated unchanged configuration keeps revision count 1.

The restart scenario verifies explicit unavailable transient tracking with preserved Git history and authentication. The theme scenario changes one synthetic description, queues a real Core job, verifies exactly one new revision and the actual diff, and captures 84 screenshots: seven pages, two themes, six viewport sizes. It also checks page overflow and computed contrast for filled/outline-hover/pagination controls.

Screenshots and synthetic cookies/data remain under ignored `tmp/`. HTTPS validation is bypassed only for this loopback test certificate; product authentication/TLS policy remains enabled.

## Release verification recorded on Windows

- Web: 133 Ruby tests / 636 assertions passed, four platform-specific skips; 25 Ruby files lint clean.
- JavaScript: 15 tests passed.
- Core manual queue: seven tests / 32 assertions passed, including retry/storage barrier and replaced-node protection.
- RouterOS model and production Git output: six tests / 45 assertions passed.
- Full Core on Windows: 463 tests / 1,640 assertions, 17 failures and nine errors from the existing path and POSIX-signal assumptions. Full Ubuntu CI remains required; these failures are not reported as a passing suite.
- Internal independent source review: CLEAN. One optional text-authentication-response unit coverage follow-up is recorded in `.cortex/fixes/release-test-followups.md`.
