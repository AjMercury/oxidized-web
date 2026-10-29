# Ubuntu 24.04: Enterprise upgrade to Core 0.37.3 + Web 0.25.0

This release pairs the manual backup queue in [Core PR #1](https://github.com/AjMercury/oxidized/pull/1) with the interface in [Web PR #1](https://github.com/AjMercury/oxidized-web/pull/1). Merge both into their respective `master` branches before using the commands below. These are the AjMercury forks; do not substitute the upstream repositories or RubyGems releases.

The procedure assumes the existing `oxidized.service` and its `/usr/local/bin` RubyGems installation. Check `systemctl show oxidized.service --property=ExecStart` and use the same Ruby/Gem environment if your service differs. Keep the current SQLite authentication database, CSV source, configuration and Git repository paths. A routine update does not need administrator bootstrapping.

## Build from the merged main branches

Run as your normal Ubuntu user. The temporary build directory avoids changing an existing source checkout.

```sh
set -eu
OX_BUILD="$(mktemp -d -t oxidized-enterprise.XXXXXX)"
git clone --branch master --single-branch https://github.com/AjMercury/oxidized.git "$OX_BUILD/oxidized"
git clone --branch master --single-branch https://github.com/AjMercury/oxidized-web.git "$OX_BUILD/oxidized-web"
(cd "$OX_BUILD/oxidized" && gem build oxidized.gemspec)
(cd "$OX_BUILD/oxidized-web" && gem build oxidized-web.gemspec)
test -f "$OX_BUILD/oxidized/oxidized-0.37.3.gem"
test -f "$OX_BUILD/oxidized-web/oxidized-web-0.25.0.gem"
sha256sum "$OX_BUILD/oxidized/oxidized-0.37.3.gem" "$OX_BUILD/oxidized-web/oxidized-web-0.25.0.gem"
```

If either filename check fails, the required PR has not been merged or the wrong branch was used. Stop before installing. To test the PRs before merging, replace `master` with `codex/enterprise-integration` in both clone commands and use an isolated staging service.

## Back up and install

Stop the service before copying SQLite and Git data so the backup is consistent. Use the real local paths from your installation for configuration, CSV, `OXIDIZED_WEB_AUTH_DB`, and output Git repositories; the example directory covers the common installation only. Add any configured paths outside this directory to the archive.

```sh
sudo systemctl stop oxidized.service
sudo install -d -m 0700 /var/backups/oxidized
OX_SNAPSHOT="/var/backups/oxidized/pre-0.25.0-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
sudo tar -czf "$OX_SNAPSHOT" -C /home/oxidized/.config oxidized
sudo chmod 0600 "$OX_SNAPSHOT"
sudo tar -tzf "$OX_SNAPSHOT" >/dev/null
sudo /usr/local/bin/gem install --local --no-document "$OX_BUILD/oxidized/oxidized-0.37.3.gem"
sudo /usr/local/bin/gem install --local --no-document "$OX_BUILD/oxidized-web/oxidized-web-0.25.0.gem"
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
sudo -u oxidized -H /usr/local/bin/ruby -e 'require "oxidized"; require "oxidized/web"; puts "Core #{Oxidized::VERSION}; Web #{Oxidized::API::WEB_VERSION}"'
```

Install Core first because Web 0.25.0 declares Core >= 0.37.3. `--local` uses the built packages and already installed dependencies; it does not publish either Gem. If dependency installation fails, resolve it in the service's existing Ruby environment before starting the update again.

## Verify

- Sign in through the existing HTTPS address and confirm Core 0.37.3 / Web 0.25.0.
- As Administrator, confirm Dashboard and Device Management show **Backup All Now** and every device has **Backup Now**. Viewer accounts must not expose those actions and the server must reject their POST requests.
- Use an authorized device or a synthetic staging inventory to test one/all/selected requests. Counts must include every configured device and show actual queued/running/terminal state. Duplicate active requests must preserve the original request.
- A successful unchanged collection updates execution metadata while retaining its Git revision count and Last Changed time. Real changes produce the actual Git diff. Core retains scheduling, concurrency and retry handling.
- After service restart, in-memory queued/running tracking is unavailable. The UI explicitly reports unavailable tracking instead of inventing a successful result; saved Git history remains available.
- Hard refresh the browser and inspect light/dark desktop and mobile views. Configuration, user database and inventory are preserved; do not recreate them during this upgrade.

The local release checks use synthetic collection with the real Core worker and Git output. They do not connect to production devices. Ubuntu CI is the authoritative check for POSIX behavior; Windows cannot run the signal/path tests reliably.

## Rollback

Retain the previously installed Core 0.37.2 and Web 0.24.1 Gems until acceptance is complete. To return to those existing installed versions:

```sh
sudo systemctl stop oxidized.service
sudo /usr/local/bin/gem uninstall oxidized-web --version 0.25.0 --executables
sudo /usr/local/bin/gem uninstall oxidized --version 0.37.3 --executables
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
```

If the older packages were removed, reinstall your archived exact Gem files before starting the service. A package rollback does not require restoring or rewriting the CSV, SQLite users, or historical Git repository. Restore the protected archive only when those data files were separately damaged.
