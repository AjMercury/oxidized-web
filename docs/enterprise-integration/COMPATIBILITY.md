# Core and Web Compatibility

## API contract used by Web

The Web extension shares Core's `Oxidized::Nodes` instance and uses these
interfaces:

| Core method | Web behavior | Compatibility note |
|---|---|---|
| `list` | Inventory and device status | Core serializes node vars; Web redacts configured and credential-like vars before returning JSON or HTML. |
| `show` | Device details | Web deep-copies the serialized node and applies the same redaction. |
| `fetch` | Current config and search | Core owns output-backend behavior and errors. |
| `version`, `get_version`, `get_diff` | History and diff views | History remains in Core's output repository. |
| `next` | Manual backup enqueue | Returns when enqueued; collection and connection status remain asynchronous in Core. |
| `load` | Source reload and post-write inventory refresh | Enterprise integration requires `load(nil, clean_obsolete: false)` to keep deleted-device Git history. |

Core's CSV source reads the configured file, applies `source.csv.map` and
`vars_map`, maps model/group names, and skips lines beginning with `#`. It has no
write API. Web writes use the same configured file and mapping; comments and
unmapped fields are retained. Encrypted CSV cannot safely be round-tripped and
is read-only in Web.

Full Core reloads may run `Output.clean_obsolete_nodes` when configured. Git
output cleanup can create a commit deleting configs for devices absent from the
inventory. The new opt-out is limited to Web-triggered inventory updates so
these changes preserve configuration history; scheduled Core behavior is
unchanged.

## Version matrix

| Core | Web | Verification | Result |
|---|---|---|---|
| 0.37.2 | 0.24.0 | Web Minitest 120 runs / 584 assertions (4 Windows skips); Node 12/12; RuboCop 23 files clean; actual Chrome screenshots for 6 pages across 5 viewports; synthetic login and device CRUD smoke checks | Core unchanged. Windows Ruby 3.2.11 only; Ubuntu/Linux checks remain required |
| 0.37.0 | 0.18.1.1 | Existing Web test suite resolved against Core gem 0.37.0; mocked Core API tests and HTTP contract tests | Read/history/backup calls covered; new management feature requires the Core fork branch that adds `clean_obsolete:` |
| 0.37.1 | 0.19.0 | Core focused `spec/nodes_spec.rb` (14/30); Web Minitest (91/385, 2 Windows skips); JavaScript (8/8); changed-file RuboCop | Core safe reload API and Web management routes verified; Web uses a synthetic Core-compatible node source |
| 0.37.1 | 0.20.0 | JavaScript (9/9); Ruby/Haml, gem build, and Linux checks unavailable in current Windows runtime | Not fully certified; run the documented Ruby suite and gem build on Ubuntu 24.04 before merge |
| 0.37.2 | 0.21.0 | Web Minitest 94 runs / 415 assertions (2 Windows-only skips); Web changed-file RuboCop clean; Core RouterOS test 3 / 24; Core changed-file RuboCop clean; both gems built; natural-version and IP-sort Node test passed | Windows full Core suite: 453 runs, 17 failures, 9 errors from POSIX signal handling, Windows path normalization, and Git path assumptions. Not Linux-certified; require Ubuntu 24.04 full-suite and browser checks before merge/deployment |
| 0.37.2 | 0.22.0 | Web Minitest 116 runs / 559 assertions (4 Windows-only skips) against the local Core 0.37.2 checkout; Node tests 11/11; full Web RuboCop clean (23 files); authentication, role, CSRF, trusted proxy, rate-limit, absolute session expiry, audit, and SQLite file/directory permissions | Core unchanged. Windows runtime only; Linux and browser E2E are not certified |
| 0.37.2 | 0.23.0 | Web Minitest 120 runs / 584 assertions (4 Windows-only skips); Node tests 12/12; RuboCop 23 files clean; real Chrome smoke checks with synthetic local fixtures across six viewports, including authenticated CRUD and 390px overflow check | Core unchanged. Windows Ruby 3.2.3 only; Ubuntu/Linux validation remains required |
| 0.34.1 | 0.18.1.1 | Gem lower bound only | Not certified; dependency compatibility is not proof of runtime compatibility |

The repository's full Core suite was attempted on the bundled Windows Ruby:
453 runs, 1,587 assertions, 17 failures, 9 errors. Failures include POSIX
signal support (`SIGUSR2`, `SIGTTIN`), Windows path normalization, and Git
repository paths. The Core default task also reports pre-existing
`Lint/RedundantCopDisableDirective` offenses outside the changed files. The
changed Core files pass RuboCop. Run the full Core suite on Ubuntu 24.04 before
merging. No Core/Web version-number equality is assumed.

## Known limits

- Device create/edit/delete are writable only for plaintext CSV with `name`,
  `model`, and `ip` mappings to non-negative integer columns and a safely
  serializable delimiter.
- SQL, HTTP, NetBox, GPG-encrypted CSV, and unknown source types remain
  read-only. The Web layer never creates a second inventory.
- `enabled` is not a Core node-source field and is not represented as a toggle.
- Inventory export deliberately excludes username and credential fields. Bulk actions cover backup, CSV delete, and group assignment where mapped.
- POSIX file owner/mode and multi-process lock tests are skipped on Windows; run the Web suite on Ubuntu 24.04 to execute them.
- Local Simple Icons SVG marks are provided for Cisco, MikroTik, Juniper, Fortinet, Palo Alto Networks, Huawei, Ubiquiti, and Dell; other vendors use the generic network-device icon. The individual icon entries did not include per-icon license metadata, so the bundled upstream disclaimer and vendor source links are retained. Review each vendor's current logo terms before redistribution or public marketing use.
- Vendor labels are best-effort guesses based on model names and must not be interpreted as backup support. The installed Core model list remains the create/edit allowlist.
- All dashboard and API routes require a local SQLite-backed session. Create the first administrator with `oxidized-web-user bootstrap-admin`; administrators manage viewer and administrator accounts in the UI. HTTP Basic credentials and the legacy `OXIDIZED_WEB_ADMIN_*` / `OXIDIZED_WEB_VIEWER_*` settings are not accepted.
- A one-time `oxidized-web-user migrate-legacy-admin` command imports an existing `OXIDIZED_WEB_ADMIN_USERNAME` / `OXIDIZED_WEB_ADMIN_PASSWORD` pair into the SQLite account store without printing values; remove the old environment variables after migration.
- SSH and Telnet ports are supported only when the CSV maps Core's `ssh_port`
  or `telnet_port` node variables.
- A colon-delimited source cannot represent an IPv6 address containing colons;
  use a delimiter that supports it or a hostname/FQDN.
- Connection results appear after Core processes the queued job; the HTTP
  enqueue response is not a synchronous backup result.
- The reverse proxy must preserve the public Host header and terminate HTTPS.
