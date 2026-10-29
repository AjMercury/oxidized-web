# Core and Web compatibility

## Release pair

| Component | Version | Status |
| --- | --- | --- |
| Oxidized Core | 0.37.2 | RouterOS model regression suite passes on the local Windows Ruby 3.2.11 runner. Core runtime source is unchanged by this release. |
| Oxidized Web | 0.24.1 | Web unit, API, security, Haml rendering, and JavaScript suites pass on the local Windows Ruby 3.2.11 runner. |
| Ruby | 3.2.3 target | The Ubuntu 24.04 production target was not available for execution in this task. |

Web declares Oxidized `>= 0.34.1`; CSV write operations additionally require a Core `Nodes#load` implementation that preserves per-device output history during inventory reload. Web checks that capability and leaves administration read-only if it is absent. Non-CSV and encrypted CSV inventories are read-only in Device Management.

## Verified behavior

- Existing Web REST route shapes and legacy `status` / `time` fields remain intact.
- Dashboard session status is separate from stored Git revisions and survives Core restarts through revision history.
- RouterOS 6/7 export timestamps and line-ending changes normalize in the Core 0.37.2 model test path before Git comparison; real interface, firewall, address, and firmware changes remain visible.
- Device writes target the configured CSV only when `name`, `model`, and `ip` are explicitly mapped. Atomic replacement, locking, runtime reload, and rollback are covered by Web tests.
- Local Chrome validated authentication, device workflows, supported UI pages, vendor asset rendering, dark mode, and six required viewport sizes. This is not an Ubuntu or production validation.

## Runtime mismatch investigation

The production screenshot shows the RouterOS-generated date line in a diff although the checked-out Core 0.37.2 model removes that exact header and the isolated model-to-Git tests pass. Production was not accessed, so the actual loaded Gem, selected node model, and custom model directory remain unverified. A stale process, a different installed Gem path, or a custom model are possibilities, not established causes. Use the secret-safe checks in [Ubuntu upgrade and rollback](ubuntu-24.04-upgrade.md#verify-the-running-installation) on the host before attributing the production behavior to a specific cause.

The screenshot's CSV warning identifies a concrete configuration limitation: the loaded CSV map was missing at least one required field. Web cannot safely infer or rewrite column positions without the actual CSV schema. It now names the missing fields, supplies a mapping template, and keeps writes disabled until the operator maps the existing file correctly.

## Platform test limitations

The full Core suite was run on Windows and reported 17 failures and 9 errors, predominantly Unix path expectations (`/cfg_path`, `/home`, `/fakefs`) and POSIX signal behavior unsupported by this runner. The focused RouterOS suite passed. Ubuntu 24.04 / Ruby 3.2.3 tests were not run; no Linux result is claimed.
