# Ubuntu 24.04: Enterprise upgrade to Core 0.37.3 + Web 0.25.1

This release pairs the manual backup queue in [Core PR #1](https://github.com/AjMercury/oxidized/pull/1) with the interface in [Web PR #1](https://github.com/AjMercury/oxidized-web/pull/1). The main-branch procedure requires both PRs to be merged; the open-PR procedure below builds the reviewed branch directly. These are the AjMercury forks; do not substitute the upstream repositories or RubyGems releases.

The reported service runs `/usr/bin/ruby3.2 /usr/local/bin/oxidized`. The executable location of Oxidized does not establish the location of the `gem` command: `/usr/local/bin/gem` may not exist. Invoke RubyGems through the service's Ruby interpreter instead. Check `systemctl show oxidized.service --property=ExecStart` and retain any configured `GEM_HOME`/`GEM_PATH` if your service uses a custom gem environment. Keep the current SQLite authentication database, CSV source, configuration and Git repository paths. A routine update does not need administrator bootstrapping.

Define these helpers in the same shell used for the following commands. If your service uses another Ruby interpreter, change `OX_RUBY` to that exact path before proceeding.

```sh
OX_RUBY=/usr/bin/ruby3.2
oxgem() {
  "$OX_RUBY" -r rubygems/gem_runner -e 'Gem::GemRunner.new.run(ARGV)' -- "$@"
}
oxgem_root() {
  sudo "$OX_RUBY" -r rubygems/gem_runner -e 'Gem::GemRunner.new.run(ARGV)' -- "$@"
}
oxgem --version
```

## Build and install the open PRs without uploaded Gem files

Run this complete block as root on the reported Ubuntu installation. It builds the two Gems on the server, so nothing needs to exist in `/tmp` beforehand. It restarts the currently running service only after both installations and the version check succeed. Keep the existing configuration/data backup as described below.

```sh
(
set -e
oxgem() {
  /usr/bin/ruby3.2 -r rubygems/gem_runner -e 'Gem::GemRunner.new.run(ARGV)' -- "$@"
}
oxgem --version
if ! command -v git >/dev/null; then
  apt-get update
  apt-get install -y git
fi
OX_BUILD="$(mktemp -d /tmp/oxidized-update.XXXXXX)"
git clone --depth 1 --branch codex/enterprise-integration https://github.com/AjMercury/oxidized.git "$OX_BUILD/core"
git clone --depth 1 --branch codex/enterprise-integration https://github.com/AjMercury/oxidized-web.git "$OX_BUILD/web"
(cd "$OX_BUILD/core" && oxgem build oxidized.gemspec)
(cd "$OX_BUILD/web" && oxgem build oxidized-web.gemspec)
oxgem install --local --no-document "$OX_BUILD/core/oxidized-0.37.3.gem"
oxgem install --local --no-document "$OX_BUILD/web/oxidized-web-0.25.1.gem"
/usr/bin/ruby3.2 -e '
require "oxidized"
require "oxidized/web"
%w[oxidized oxidized-web].each do |name|
  spec = Gem.loaded_specs.fetch(name)
  puts "#{name}: #{spec.version}"
end
abort "Unexpected loaded versions" unless Gem.loaded_specs.fetch("oxidized").version.to_s == "0.37.3" && Gem.loaded_specs.fetch("oxidized-web").version.to_s == "0.25.1"
'
systemctl restart oxidized.service
sleep 3
systemctl --no-pager --full status oxidized.service
)
```

Version reporting uses the activated Gem specifications. Merely requiring `oxidized/web` does not load its version constant until WebApp is initialized, so reading `Oxidized::API::WEB_VERSION` at that point can raise NameError even when the Gem is installed correctly.

## Build from the merged main branches

Run as your normal Ubuntu user. The temporary build directory avoids changing an existing source checkout.

```sh
set -eu
OX_BUILD="$(mktemp -d -t oxidized-enterprise.XXXXXX)"
git clone --branch master --single-branch https://github.com/AjMercury/oxidized.git "$OX_BUILD/oxidized"
git clone --branch master --single-branch https://github.com/AjMercury/oxidized-web.git "$OX_BUILD/oxidized-web"
(cd "$OX_BUILD/oxidized" && oxgem build oxidized.gemspec)
(cd "$OX_BUILD/oxidized-web" && oxgem build oxidized-web.gemspec)
test -f "$OX_BUILD/oxidized/oxidized-0.37.3.gem"
test -f "$OX_BUILD/oxidized-web/oxidized-web-0.25.1.gem"
sha256sum "$OX_BUILD/oxidized/oxidized-0.37.3.gem" "$OX_BUILD/oxidized-web/oxidized-web-0.25.1.gem"
```

If either filename check fails, the required PR has not been merged or the wrong branch was used. Stop before installing. To test the PRs before merging, replace `master` with `codex/enterprise-integration` in both clone commands and use an isolated staging service.

## Back up and install

Stop the service before copying SQLite and Git data so the backup is consistent. Use the real local paths from your installation for configuration, CSV, `OXIDIZED_WEB_AUTH_DB`, and output Git repositories; the example directory covers the common installation only. Add any configured paths outside this directory to the archive.

```sh
test -f "$OX_BUILD/oxidized/oxidized-0.37.3.gem"
test -f "$OX_BUILD/oxidized-web/oxidized-web-0.25.1.gem"
oxgem --version
sudo systemctl stop oxidized.service
sudo install -d -m 0700 /var/backups/oxidized
OX_SNAPSHOT="/var/backups/oxidized/pre-0.25.1-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
sudo tar -czf "$OX_SNAPSHOT" -C /home/oxidized/.config oxidized
sudo chmod 0600 "$OX_SNAPSHOT"
sudo tar -tzf "$OX_SNAPSHOT" >/dev/null
oxgem_root install --local --no-document "$OX_BUILD/oxidized/oxidized-0.37.3.gem"
oxgem_root install --local --no-document "$OX_BUILD/oxidized-web/oxidized-web-0.25.1.gem"
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
sudo -u oxidized -H "$OX_RUBY" -e 'require "oxidized"; require "oxidized/web"; %w[oxidized oxidized-web].each { |name| puts "#{name}: #{Gem.loaded_specs.fetch(name).version}" }'
```

Install Core first because Web 0.25.1 declares Core >= 0.37.3. `--local` uses the built packages and already installed dependencies; it does not publish either Gem. If dependency installation fails, resolve it in the service's existing Ruby environment before starting the update again.

## Verify

- Sign in through the existing HTTPS address and confirm Core 0.37.3 / Web 0.25.1.
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
oxgem_root uninstall oxidized-web --version 0.25.1 --executables
oxgem_root uninstall oxidized --version 0.37.3 --executables
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
```

If the older packages were removed, reinstall your archived exact Gem files before starting the service. A package rollback does not require restoring or rewriting the CSV, SQLite users, or historical Git repository. Restore the protected archive only when those data files were separately damaged.
