# Ubuntu 24.04 Build, Deployment, and Rollback

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
5. Configure `OXIDIZED_WEB_ADMIN_USERNAME` and
   `OXIDIZED_WEB_ADMIN_PASSWORD` through a root-owned mode-0600 systemd
   environment file. Systemd reads it before starting the service account. Put
   the Web endpoint behind HTTPS and set `vhosts` to the expected host.
   For inventory read-only access, optionally configure
   `OXIDIZED_WEB_VIEWER_USERNAME` and `OXIDIZED_WEB_VIEWER_PASSWORD` in the
   same protected file. Viewer credentials cannot mutate inventory or queue
   backups; administrator credentials are still required for all writes.

## Back up before installation

Stop writes through the maintenance window. As the operator, copy the current
Web gem, Core gem if it is being upgraded, Oxidized YAML/systemd configuration,
CSV source, and Git output repository to a protected backup location. Preserve
owner, group, mode, and timestamps. Do not back up credentials into an
unprotected directory.

After scheduling an approved maintenance window, stop Oxidized before taking a
consistent copy. Example (replace paths with the locally verified values):

```sh
sudo systemctl stop oxidized.service
sudo install -d -m 0700 /var/backups/oxidized-pre-enterprise
sudo cp -a /etc/oxidized/config /etc/oxidized/router.db /var/backups/oxidized-pre-enterprise/
sudo cp -a /var/lib/oxidized/oxidized.git /var/backups/oxidized-pre-enterprise/
sudo systemctl cat oxidized.service | sudo tee /var/backups/oxidized-pre-enterprise/oxidized.service.txt >/dev/null
```

## Install and restart

After approval, install the exact reviewed gem artifacts and dependencies using
the same RubyGems environment as `/usr/local/bin/oxidized`:

```sh
sudo gem install --local ./oxidized-0.37.1.gem
sudo gem install --local ./oxidized-web-0.20.0.gem
sudo systemctl daemon-reload
sudo systemctl restart oxidized.service
```

If an updated Core gem is not approved or installed, keep administrator
operations disabled. The existing UI read APIs continue to use the configured
Core installation.

## Health and post-deployment verification

```sh
sudo systemctl is-active oxidized.service
sudo systemctl status oxidized.service --no-pager
sudo journalctl -u oxidized.service -n 100 --no-pager
curl --fail --silent --show-error http://127.0.0.1:8888/nodes.json
```

Through the HTTPS reverse proxy, verify unauthenticated admin access is
rejected, configured admin access can open Device Management, and a synthetic
isolated inventory can be created, reloaded, and removed. Verify credentials
are absent from browser/API responses and logs. Confirm the device status after
Core processes a manual backup. Do not use a production network device for the
acceptance test.

## Rollback

If the service fails health checks, restore the previously installed gem
versions and saved files from the protected backup, then restart:

```sh
sudo gem uninstall oxidized-web --version 0.20.0 --ignore-dependencies
sudo gem install --local ./oxidized-web-0.19.0.gem
sudo systemctl daemon-reload
sudo systemctl restart oxidized.service
sudo systemctl is-active oxidized.service
```

Keep Core at 0.37.1 for this Web-only rollback. If Core itself must be rolled
back to 0.37.0, install that exact gem separately and remove the Web
administrator credentials from the service environment because the earlier
Core does not provide the history-preserving inventory reload API.

Restore application files only if they were changed, and restore the CSV and
Git output repository only after quiescing Oxidized:

```sh
sudo systemctl stop oxidized.service
sudo cp -a /var/backups/oxidized-pre-enterprise/config /etc/oxidized/config
sudo cp -a /var/backups/oxidized-pre-enterprise/router.db /etc/oxidized/router.db
sudo cp -a /var/backups/oxidized-pre-enterprise/oxidized.git /var/lib/oxidized/
sudo systemctl restart oxidized.service
```

The history-preserving reload does not delete historical configs. Keep the new
Web gem's administrator and viewer environment variables unset or remove them
during rollback if the previous Web version has no administrator authorization.
