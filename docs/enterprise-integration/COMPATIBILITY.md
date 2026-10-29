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
| 0.37.0 | 0.18.1.1 | Existing Web test suite resolved against Core gem 0.37.0; mocked Core API tests and HTTP contract tests | Read/history/backup calls covered; new management feature requires the Core fork branch that adds `clean_obsolete:` |
| 0.37.1 | 0.19.0 | Core focused `spec/nodes_spec.rb` (14/30); Web Minitest (91/385, 2 Windows skips); JavaScript (8/8); changed-file RuboCop | Core safe reload API and Web management routes verified; Web uses a synthetic Core-compatible node source |
| 0.34.1 | 0.18.1.1 | Gem lower bound only | Not certified; dependency compatibility is not proof of runtime compatibility |

The repository's full Core suite was also attempted on Windows Ruby 3.2.11:
450 runs, 1,578 assertions, 16 failures, 9 errors. The observed failures involve
POSIX signals, Windows path normalization, and Git repository paths. The Core
default `rake` also reports five existing `Lint/RedundantCopDisableDirective`
offenses outside the changed files. Run the full Core suite on Ubuntu 24.04
before merging. No Core/Web version-number equality is assumed.

## Known limits

- Device create/edit/delete are writable only for plaintext CSV with `name`,
  `model`, and `ip` mappings to non-negative integer columns and a safely
  serializable delimiter.
- SQL, HTTP, NetBox, GPG-encrypted CSV, and unknown source types remain
  read-only. The Web layer never creates a second inventory.
- `enabled` is not a Core node-source field and is not represented as a toggle.
- Inventory export deliberately excludes username and credential fields. Bulk actions cover backup, CSV delete, and group assignment where mapped.
- POSIX file owner/mode and multi-process lock tests are skipped on Windows; run the Web suite on Ubuntu 24.04 to execute them.
- Vendor logo files are not included; the UI uses the existing generic icon set and model names. Brand assets require an approved local asset source.
- SSH and Telnet ports are supported only when the CSV maps Core's `ssh_port`
  or `telnet_port` node variables.
- A colon-delimited source cannot represent an IPv6 address containing colons;
  use a delimiter that supports it or a hostname/FQDN.
- Connection results appear after Core processes the queued job; the HTTP
  enqueue response is not a synchronous backup result.
- The reverse proxy must preserve the public Host header and terminate HTTPS.
