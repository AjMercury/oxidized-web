# Ubuntu 24.04 upgrade and rollback

This procedure upgrades **Oxidized Web 0.24.0 to 0.24.1** using the existing RubyGems and `oxidized.service` installation. Core remains at 0.37.2. These commands are documentation only; no production host was accessed or changed.

## Build and verify the Gem

Build with the project's supported Ruby and bundler on a staging/build host:

```sh
bundle install
bundle exec rake test
npm test
gem build oxidized-web.gemspec
gem specification oxidized-web-0.24.1.gem name version dependencies
```

Install into an isolated gem home before preparing a production artifact:

```sh
VERIFY_GEM_HOME="$(mktemp -d)"
GEM_HOME="$VERIFY_GEM_HOME" GEM_PATH="$VERIFY_GEM_HOME" \
  gem install --local --no-document oxidized-web-0.24.1.gem
GEM_HOME="$VERIFY_GEM_HOME" GEM_PATH="$VERIFY_GEM_HOME" \
  ruby -e 'require "oxidized/web"; puts Oxidized::API::WEB_VERSION'
rm -rf "$VERIFY_GEM_HOME"
```

Do not publish the Gem to RubyGems.org as part of this procedure.

## Verify the running installation

Run these checks on the server before changing anything. The Ruby command prints versions and Gem paths only; it does not print the Oxidized config or credentials.

```sh
sudo systemctl show oxidized.service --property=ExecStart
sudo -u oxidized -H /usr/local/bin/oxidized --version
sudo -u oxidized -H /usr/local/bin/ruby -e '
  require "oxidized"
  require "oxidized/web"
  %w[oxidized oxidized-web].each do |name|
    spec = Gem.loaded_specs[name]
    puts "#{name}=#{spec&.version} path=#{spec&.full_gem_path}"
  end
  puts "routeros_model_candidates=#{Gem.find_files("oxidized/model/routeros.rb").join(",")}"
'
```

Use the config path from `ExecStart` and inspect only the following non-secret keys. Do not `cat` or paste the full configuration, environment, or service logs when they may contain credentials.

```sh
CONFIG=/home/oxidized/.config/oxidized/config
sudo -u oxidized awk -F: '
  /^[[:space:]]*model_dir:/ { print }
  /^[[:space:]]*default:/ { print }
  /^[[:space:]]*map:/ { print }
  /^[[:space:]]*(name|model|ip):/ { print }
' "$CONFIG"
```

Check the configured CSV path and delimiter locally without displaying row contents or credentials. Confirm the mapping positions match the existing file's real column order. For the usual `name:model:ip` layout, an example is:

```yaml
source:
  default: csv
  csv:
    map:
      name: 0
      model: 1
      ip: 2
```

Only use those positions if they match the actual CSV. Device Management stays read-only until `name`, `model`, and `ip` are explicitly mapped and the service restarts with the corrected configuration. Do not let Web infer or rewrite the production file schema.

For the RouterOS diff, verify all three: Core version/path, the model value in the configured inventory, and whether `model_dir` selects a custom `routeros.rb`. A custom model or another loaded Gem path can bypass the checked-out default model fix.

## Pre-deployment backup

Set the paths to the real installation after checking the service configuration. Include the Oxidized config, CSV inventory, Web SQLite user database, and Git output repository. Keep the archive readable only by root and retain it outside the source inventory/repository directories.

```sh
CONFIG=/home/oxidized/.config/oxidized/config
INVENTORY=/home/oxidized/.config/oxidized/router.db
USER_DB=/home/oxidized/.config/oxidized/web-users.sqlite3
GIT_OUTPUT=/home/oxidized/.config/oxidized/configs.git
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/var/backups/oxidized-pre-web-0.24.1-${STAMP}.tar.gz"
sudo install -d -m 0700 /var/backups
sudo tar --acls --xattrs -czf "$BACKUP" \
  "$CONFIG" "$INVENTORY" "$USER_DB" "$GIT_OUTPUT" \
  /etc/systemd/system/oxidized.service
sudo chmod 0600 "$BACKUP"
sudo tar -tzf "$BACKUP" >/dev/null
```

Adjust `USER_DB` and other paths to the actual installation; do not create an empty placeholder file if a component is not used. Record the currently installed Web Gem:

```sh
sudo -u oxidized -H /usr/local/bin/gem list --local '^oxidized-web$'
```

Copy `oxidized-web-0.24.1.gem` to a root-owned staging path on the server and verify its checksum through your normal artifact process.

## Upgrade

Core does not need an upgrade for this Web release.

```sh
sudo systemctl stop oxidized.service
sudo /usr/local/bin/gem install --local --no-document /tmp/oxidized-web-0.24.1.gem
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
sudo journalctl -u oxidized.service --since '5 minutes ago' --no-pager
```

Check the logs locally and do not share unredacted output. Then:

1. Visit `https://oxidized.newshanik.ir/login` and sign in with an existing account.
2. Confirm `/nodes` loads and that the authenticated `/nodes.json` response is available.
3. Confirm the footer reports Web 0.24.1 and the runtime command reports Core 0.37.2.
4. Confirm a device with Git history but no current-session attempt says “Not checked this session,” never 1970.
5. Open Device Management. If it reports missing CSV mappings, keep writes disabled until the existing CSV schema is mapped correctly and service is restarted.
6. Inspect an existing RouterOS history diff. A timestamp-only revision already stored in history is not rewritten by this release; verify subsequent backups after confirming the active RouterOS model and Gem path.

Do not run a production device backup solely as a deployment probe. Let the configured schedule or an authorized operational procedure handle that.

## Rollback

The Web release does not change Core, the CSV, or historical Git revisions. If the new Web service fails, roll back the Gem and keep the existing configuration and history intact.

```sh
sudo systemctl stop oxidized.service
sudo /usr/local/bin/gem uninstall oxidized-web --version 0.24.1 --executables
sudo systemctl start oxidized.service
sudo systemctl --no-pager --full status oxidized.service
```

RubyGems retains the previously installed 0.24.0 release unless it was separately removed. If that version is not installed, install the archived `oxidized-web-0.24.0.gem` before starting the service:

```sh
sudo /usr/local/bin/gem install --local --no-document /var/backups/oxidized-web-0.24.0.gem
sudo systemctl start oxidized.service
```

If inventory or application data was changed outside this Web upgrade, restore the matching pre-deployment archive only after stopping Oxidized and confirming the exact target paths. Do not restore Git history for a Web-only rollback unless the Git repository itself was separately damaged; this release does not rewrite it.
