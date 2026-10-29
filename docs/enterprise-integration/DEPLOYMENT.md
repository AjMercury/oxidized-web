# Ubuntu 24.04 Build, Deployment, and Rollback

> Superseded for Web 0.24.1 by [the current upgrade and rollback procedure](../ubuntu-24.04-upgrade.md). The commands below describe the earlier 0.24.0 release.

This guide prepares versioned gems for review and manual deployment. It does
not deploy or restart a production service. Device management requires both the
Web changes and the Core fork's history-preserving reload API; installing only
the Web gem leaves device writes safely disabled.

## Build and verify versions

Use Ruby 3.2.3 and Bundler on a clean build host. Check out the reviewed Core
and Web branches and record their commit IDs:

```sh
git -C oxidized rev-parse HEAD
git -C oxidized-web rev-parse HEAD
```

Build Core first, then Web against that Core checkout using the local path
dependency documented in `docs/development.md`:

```sh
cd oxidized
bundle config set --local path vendor/bundle
bundle install
bundle exec rake
gem build oxidized.gemspec

cd ../oxidized-web
bundle config set --local path vendor/bundle
bundle install
bundle exec rake
npm test
gem build oxidized-web.gemspec
```

Record the exact generated gem filenames and SHA-256 checksums. Confirm Web
resolves the intended Core version with `bundle exec ruby -e 'require "oxidized"; puts Oxidized::VERSION'`.

## Pre-deployment checks

1. Review both PRs and the compatibility matrix. Require the full Core suite
   and Web suite on Ubuntu 24.04; the Windows Core run is not sufficient.
2. Check Ruby 3.2.3, gem versions, executable path, systemd unit, listener
   address, reverse-proxy Host preservation, and current health at port 8888.
3. Confirm the actual `source.default` and CSV path, delimiter, `map`,
   `vars_map`, GPG setting, file owner, and mode. Device writes fail closed for
   unsupported layouts and encrypted files.
4. Confirm the Git output repository path and `output.clean_obsolete_nodes`
   configuration. The Web refresh opts out of cleanup; scheduled Core behavior
   remains unchanged.
5. Configure the SQLite database path and trusted local reverse proxy in a
   root-owned systemd environment file. Systemd reads it before switching to
   the service account. Preserve the public Host header, replace
   `X-Forwarded-Proto` at the proxy, and set `vhosts` to the expected host.
   See [AUTHENTICATION.md](AUTHENTICATION.md) for the Nginx/Caddy requirements.
6. Create the first administrator with the new `oxidized-web-user`
   executable. Do not put the administrator password in command arguments or
   systemd environment variables.

## Back up before installation

Stop writes through the maintenance window. As the operator, copy the current
Web gem, Core gem if it is being upgraded, Oxidized YAML/systemd configuration,
authentication SQLite database, CSV source, and Git output repository to a
protected backup location. Preserve owner, group, mode, and timestamps. Keep
the SQLite database mode at `0600` and do not copy it into an unprotected
directory.

After scheduling an approved maintenance window, stop Oxidized before taking a
consistent copy. Example (replace paths with the locally verified values):

```sh
sudo systemctl stop oxidized.service
sudo install -d -m 0700 /var/backups/oxidized-pre-enterprise
sudo cp -a /etc/oxidized/config /etc/oxidized/router.db /var/backups/oxidized-pre-enterprise/
sudo cp -a /var/lib/oxidized/oxidized.git /var/backups/oxidized-pre-enterprise/
if sudo test -f /var/lib/oxidized/web-auth.sqlite3; then
  sudo cp -a /var/lib/oxidized/web-auth.sqlite3 /var/backups/oxidized-pre-enterprise/
fi
sudo systemctl cat oxidized.service | sudo tee /var/backups/oxidized-pre-enterprise/oxidized.service.txt >/dev/null
```

## Install and restart

After approval, install the exact reviewed gem artifacts and dependencies using
the same RubyGems environment as `/usr/local/bin/oxidized`:

```sh
sudo gem install --local ./oxidized-web-0.24.0.gem
sudo systemctl daemon-reload
sudo systemctl restart oxidized.service
```

Core is unchanged by this Web-only release; omit the Core install command when
Core 0.37.2 is already installed. Keep the existing `OXIDIZED_WEB_AUTH_DB` path
and SQLite file in place so current accounts, sessions, and audit history are
preserved. Do not rerun `bootstrap-admin` during a routine upgrade. The
bootstrap command is only for a new database and prompts for a username and
password twice; it creates no default credentials. If the installed Core is
older than 0.37.2, the existing UI remains available while inventory writes
stay guarded by the history-preserving Core API check.

## Health and post-deployment verification

```sh
sudo systemctl is-active oxidized.service
sudo systemctl status oxidized.service --no-pager
sudo journalctl -u oxidized.service -n 100 --no-pager
curl --fail --silent --show-error https://oxidized.example.com/login
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  https://oxidized.example.com/nodes.json
```

Through the HTTPS reverse proxy, verify the login page returns `200`, the root
redirects to Login, an unauthenticated `/nodes.json` request returns `401`,
Basic Authorization does not grant access, and a configured administrator
can open Device Management. The direct local HTTP listener is not a valid
health endpoint when HTTPS enforcement is enabled.
Verify a viewer cannot write, CSRF-less requests fail, and logout invalidates
the session. Use an isolated synthetic inventory for any add/reload/remove
check. Verify credentials are absent from browser/API responses and logs. Do
not use a production network device for acceptance testing.

## Rollback

If the service fails health checks, restore the previously installed gem
versions and saved files from the protected backup, then restart:

```sh
sudo gem uninstall oxidized-web --version 0.24.0 --ignore-dependencies
sudo gem install --local ./oxidized-web-0.23.0.gem
sudo systemctl daemon-reload
sudo systemctl restart oxidized.service
sudo systemctl is-active oxidized.service
```

Core 0.37.2 is unchanged by this release and does not need to be reinstalled.
If Core is separately rolled back to a version without `clean_obsolete: false`,
keep Web inventory writes disabled. Restore a previously backed-up Core gem
only when Core itself was changed during the same approved maintenance window.

When the saved gems are available in the working directory, the exact package
rollback is:

```sh
sudo gem uninstall oxidized-web --version 0.24.0 --ignore-dependencies
sudo gem install --local ./oxidized-web-0.23.0.gem
sudo systemctl daemon-reload
sudo systemctl restart oxidized.service
sudo systemctl is-active oxidized.service
```

Restore application files only if they were changed, and restore the CSV and
Git output repository only after quiescing Oxidized:

```sh
sudo systemctl stop oxidized.service
sudo cp -a /var/backups/oxidized-pre-enterprise/config /etc/oxidized/config
sudo cp -a /var/backups/oxidized-pre-enterprise/router.db /etc/oxidized/router.db
sudo cp -a /var/backups/oxidized-pre-enterprise/oxidized.git /var/lib/oxidized/
sudo systemctl restart oxidized.service
```

The history-preserving reload does not delete historical configs. Keep the
SQLite authentication database backed up; do not delete it when rolling back,
because it contains the local users and audit history. Web 0.23.0 also uses
session authentication and remains compatible with Core 0.37.2.
