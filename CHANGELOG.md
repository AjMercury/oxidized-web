# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
## [0.23.0] - 2026-10-29

### Added
- Add Core-history-backed dashboard activity, revision timelines, and explicit last-attempt, last-stored-revision, and session-unchecked status fields that survive Core restarts.
- Parse reliable RouterOS, IOS, NX-OS, and Junos software version strings from the latest stored configuration without initiating SSH connections.
- Add compact overview charts, grouped/collapsible navigation, a saved desktop sidebar preference, and a mobile hamburger sidebar.
- Add a one-time migration command for configured legacy administrator environment credentials into the session-based SQLite account store without printing secrets.

### Changed
- Cache per-request Git history and bounded firmware metadata lookups to avoid repeated per-device history queries.
- Preserve existing `/node/show` JSON response fields while displaying durable backup metadata in the HTML detail view.
- Compact dashboard and management controls, make vendor/model form fields align consistently, and prevent mobile top-bar horizontal overflow.
- Show line numbers in both side-by-side and unified configuration diffs.
- Apply revalidation headers to local CSS, JavaScript, and other static assets so visual fixes are not hidden by stale browser caches.

### Fixed
- Distinguish “Not checked this session” from “Never backed up” when Git revisions exist after an Oxidized restart.
- Correct dashboard backup counts to derive “no saved revisions” from durable Git history instead of volatile Core runtime status.
- Count Core `fail` and `timelimit` backup outcomes as failures instead of hiding them in the dashboard's residual status segment.
- Include the device model in the bounded firmware metadata cache key so model changes cannot reuse a parser result from a prior model.
- Fix the 390px viewport horizontal overflow caused by the responsive header.
- Keep existing node-show API serialization compatible while computing additional HTML dashboard metadata.

### Compatibility and verification
- Compatible target: Oxidized Core 0.37.2 and Oxidized Web 0.23.0. Core is unchanged in this release.
- Windows Ruby 3.2.3: Web Minitest 120 runs / 584 assertions, 0 failures/errors, 4 platform skips; RuboCop 23 files with no offenses; JavaScript 12/12.
- Real Chrome smoke checks against synthetic local data verified login, dashboard, device management, add/edit/delete, details, history, diff, user management, dark mode, collapsed navigation, and viewport sizes 1920×1080, 1440×900, 1366×768, 1024×768, 768×1024, and 390×844. No page-level overflow was observed at 390px.
- Windows-only execution; Ubuntu 24.04/Linux checks and production deployment have not been performed.

## [0.19.0] - 2026-10-29

### Added
- Authenticated device management for mapped plaintext CSV inventories, including atomic writes, locking, rollback, and a read-only mode for unsupported sources.
- Bulk backup, bulk deletion, CSV inventory export, and bulk group assignment for selected devices, with per-device audit records.
- Dynamic model discovery from the installed Core and natural numeric ordering for software version strings; unavailable versions display as Unknown.
- Administrator authorization and same-origin checks for inventory writes, source reload, and manual backup actions.
- Core compatibility matrix and Ubuntu 24.04 build, deployment, health-check, and rollback guidance.
- Security regression tests for XSS prevention in node name, version, diff, stats views and HTMLEntities encoding of device config content (@mattimustang, @robertcheramy)

### Changed
- Change source reload and manual backup browser actions to POST and require administrator authentication.
- Redact credential-like node variables from inventory and detail responses by default.
- Preserve configured CSV comments and unrelated fields during updates, and preserve Git configuration history during Web-triggered inventory reloads.
- Remove the no longer needed escape_once helper call in node.haml, relying on HAML's global escape_html instead (@robertcheramy)
- Update web libraries to the latest versions (@robertcheramy)
- Encode JSON output with the standard library instead of Sinatra's json helper (@robertcheramy)
- Set HAML's `attr_quote` explicitly to `"` for stable output across HAML versions (@robertcheramy)

### Fixed
- Protect format-suffixed reload routes, enforce HTTPS origins for admin writes, and reject updates that clear required model or address fields.
- Preserve CSV owner/group/mode during atomic replacement, and expose bulk group assignment only when Core's node group field is mapped.
- Redact API, access, secret, and credential key variables from public inventory and device responses.
- Reject duplicate rename and stale bulk selections; roll back inventory changes when Core fails to refresh the expected node set.
- Fix `NoMethodError` when `group=` param is absent from `/node/version/view` and `/node/version/diffs` requests. `params[:group]` was assigned directly to `@info[:group]`; `params[:group]` is now normalized to '' so the HAML templates render the no-group branch instead of crashing with a 500 (@makaiver)
- Fix `NoMethodError` and `RegexpError` crashes on `/node/version`, `/nodes/conf_search` and in `route_parse` when params are missing or contain a malformed regex; return empty results instead of a 500 (@makaiver)
- Fix XSS vulnerability (CWE-79) by enabling HAML's escape_html globally; user-controlled values in node names, group names, model names, and URL parameters are now HTML-escaped in all templates (@mattimustang)


## [Unreleased]

## [0.22.0] - 2026-10-29

### Added
- Add a responsive session login page, SQLite-backed account management, administrator/viewer roles, password changes, and a secure first-administrator bootstrap command.
- Protect dashboard pages, configuration/history views, downloads, and REST endpoints behind server-side sessions; add CSRF checks, secure cookie attributes, HTTPS enforcement, trusted-proxy handling, persistent login throttling, and authentication audit events.

### Changed
- Replace environment-based HTTP Basic management authentication with local user accounts; all dashboard and API access now requires login, and Basic credentials are ignored.
- Rate-limit failed sign-ins by resolved client address and username without a proxy-wide lockout bucket; the Nginx example overwrites forwarded client addresses.
- Add SQLite as a runtime dependency and document authentication setup, roles, reverse proxy configuration, and rollback.

### Fixed
- Close unauthenticated access to configuration and inventory APIs, including direct URL access.
- Prevent malformed forwarded-address headers from creating a shared reverse-proxy lockout across different users.
- Add regression coverage for login/logout, session rotation/expiry, role checks, CSRF, HTTPS proxy validation, Basic-auth rejection, brute-force limits, disabled accounts, password changes, and secret redaction.
- Fix the JavaScript test DOM fixture so application-shell tests can run with the counter initializer.

### Compatibility
- Compatibility target: Oxidized Core 0.37.2 and Oxidized Web 0.22.0. Core remains unchanged in this release.
- Web suite against the local Core 0.37.2 checkout: 116 runs, 559 assertions, 0 failures/errors, 4 Windows-only skips. JavaScript suite: 11/11. Full Web RuboCop: 23 files, no offenses. Linux and browser E2E validation were not available in this environment.

## [0.21.0] - 2026-10-29

### Added
- Add local vendor SVG marks for Cisco, MikroTik, Juniper, Fortinet, Palo Alto Networks, Huawei, Ubiquiti, and Dell, with generic icon fallbacks and vendor previews in add/edit forms.
- Add configurable inventory auto-refresh, animated data-backed counters, and polished responsive dashboard, device details, and diff controls.
- Add an explicit administration-disabled page that explains missing credentials, unsupported inventory sources, and history-safe reload requirements.

### Fixed
- Fix bulk device controls rendering inside the model `<select>`, which prevented reliable selection and submission in browsers.
- Fix backup history failure-rate rendering when a device has no recorded runs.
- Fix diff unified/full-screen toggles using CSS class names that did not match the stylesheet.
- Fix device detail links for group-qualified names by resolving the full inventory identity through the existing Core node list without altering the Web JSON payload.
- Preserve RouterOS 6 and 7 generated export timestamp comments from Git configuration output via compatible Core 0.37.2.

### Compatibility
- Compatible release target: Oxidized Core 0.37.2 and Oxidized Web 0.21.0. Both upgrades are required for history-safe inventory management and RouterOS timestamp normalization.
- Web Ruby suite: 94 runs, 415 assertions, 0 failures/errors, 2 Windows-only skips; changed-file RuboCop clean; Web gem built successfully. Core RouterOS regression: 3 runs, 24 assertions, 0 failures/errors; changed-file RuboCop clean; Core gem built successfully.
- Full Core suite is not green on Windows (453 runs, 17 failures, 9 errors), due Windows path normalization, unsupported POSIX signals, and Git path assumptions; full Ubuntu 24.04 validation remains required before merge/deployment.

## [0.20.0] - 2026-10-29

### Added
- Add vendor and Core-model selectors, vendor/model/status filters, revision counts from stored Git history, and sortable inventory fields.
- Add read-only viewer credentials alongside the administrator role, plus selected-device CSV export without credential fields.
- Improve configuration history search and date sorting; add numeric version-sort regression coverage.

### Changed
- Continue using the configured Core model directory for model discovery; vendor labels are best-effort classifications and do not claim retrieval support.
- Keep Core at 0.37.1; this release contains Web-only changes.

### Known limitations
- Local authentic vendor logo assets are not included. The UI retains a generic device glyph and vendor text because the build environment could not reach the public asset package source.
- Ruby, Haml, gem build, and Linux validation could not be run in this Windows environment; see the compatibility matrix.


## [0.18.1 – 2026-01-19]
Maintenance release to update dependencies.

### Changed
- Reintroduce support for ruby 3.0 / see Oxidized Issue #3688 (@robertcheramy)
- Update web libraries to the latest versions (@robertcheramy)
- Fix Gem policy to automatic update minor versions (@robertcheramy)


## [0.18.0 – 2025-12-03]
It's finally here - dark mode. Enjoy!

### Added
- Support for dark mode (@robertcheramy)

### Changed
- Dependency on Oxidized => 0.34.1 to support future Oxidized releases (@robertcheramy)
- Update web libraries to the latest versions (@robertcheramy)
- Allow latest gems versions (@robertcheramy)
- Limit Haml gem to < 7.0.0, as it doesn't support Ruby 3.1 (@robertcheramy)
- Allow enumeration of nodes contained in the `default` group (@oogali)

### Fixed
- Remove redundant dependency on bundler producing a CI failure on ruby-head (@robertcheramy)


## [0.17.1 – 2025-08-01]
### Changed
- Dependency on Oxidized 0.34.1 (@robertcheramy)

### Fixed
- Hide node vars works with Oxidized > 0.34.1 (@robertcheramy)


## [0.17.0 – 2025-07-18]
### Added
- Documentation of the configuration (@robertcheramy)

### Changed
- Update weblibs to the latest versions (@robertcheramy)
- Depend on oxidized 0.34.0 (configuration of oxidized web as an extension) (@robertcheramy)
- Use JSON to format the node metadata in /node/show (@robertcheramy)

### Fixed
- Run puma directly, so that it does not rename the oxidized process. Fixes: 349 (@robertcheramy)
- Display local time correctly and use epoch as timestamps in the URLs. Fixes: #258 and #356 (@robertcheramy)
- Hide node vars when listed in the configuration entry hide_node_vars. Fixes: #344 (@robertcheramy)
- /node/next/: Prefer JSON.parse over JSON.load (@robertcheramy)


## [0.16.0 - 2025-03-25]
This release introduces the possibility for an extended configuration of
oxidized-web in the oxidized configuration file. Oxidized versions after 0.32.2
will only work with oxidized-web version 0.16.0 or later.

### Changed
- Allow connection to any virtual hosts + prepare extended configuration to specify which vhosts to accept. Fixes #298 (@robertcheramy)

### Fixed
- the table preferences (pagelength, column visibility, search) are stored in the local browser cache. Fixes #315 #314 #265 #211 (@robertcheramy)
- Update "refresh" and "Update node list" to more meaningful texts (@robertcheramy)

## [0.15.1 – 2025-02-20]
This patch release fixes javascript errors.

### Fixed
- Fix javascript not working (@robertcheramy)

## [0.15.0 – 2025-02-17]
This release fixes a security issue on the RANCID migration page.
A non-authenticated user could gain control over the Linux user running
oxidized-web. The RANCID migration page was already deprecated in version
0.14.0, so it has been completely removed in this new version.
Thank you to Jon O'Reilly and Jamie Riden from NetSPI for discovering and
reporting this security issue!

### Changed
- Update datatables.net to 2.2.2 and datatables.net-buttons to 3.2.2 (@robertcheramy)
- remove the RANCID migration page (@robertchreamy)
- dependency on oxidized 0.31  (@robertchreamy)
- Update datatables.net to 2.2.1 and datatables.net-buttons to 3.2.1 (@robertcheramy)

### Fixed
- #302: group name containing a '/' produced a Sinatra error (@robertcheramy)


## [0.14.0 - 2024-06-28]

### Added
- CHANGELOG.md created (@robertchreamy)
- First minitest: get / (@robertchreamy)
- docs/development.md created (@robertchreamy)
- weblibs are maintained with npm (@robertchreamy)
- display Oxidized-web version in the footer (@robertcheramy)

### Changed
- gem dependencies updated (@robertchreamy)
- support for ruby 3.0 dropped (@robertchreamy)
- #215: weblibs (jQuery, bootstrap, datatables.net) updated (@robertchreamy)
- the web design follows where possible bootstrap without specific css (@robertchreamy)
- deprecating the RANCID migration page (@robertchreamy)

### Fixed
- #232: escape_once not supported in haml 6.0 (@robertchreamy)
- #253: deprecated sass dependency dropped (@robertchreamy)
- rubocop warnings fixed (@robertchreamy)
- #234: removed link to not working live demo (@robertchreamy)
- group name containing a '/' producing a Sinatra error (@robertcheramy)
