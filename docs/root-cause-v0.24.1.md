# Root cause notes for Web 0.24.1

## False 1970 backup time

The device table rendered an empty `epoch` attribute when Core had no last-attempt time. `oxidized.js` passed that empty string to `Number`, which becomes `0`, then formatted Unix epoch as local time. Separately, the server timestamp parser accepted zero as a valid timestamp.

The Web now treats zero and pre-epoch timestamps as unavailable, omits usable time values from the rendered attribute when missing, and the browser skips empty, non-finite, and non-positive epochs. Regression coverage includes nil, empty, numeric zero, `Time.at(0)`, pre-epoch time, and positive history values; browser verification confirmed “Not checked this session” remains visible and no 1970 date appears.

## Empty Add Device form

`DeviceInventory` already failed closed when the configured CSV mapping omitted Core's required node keys. The `/admin/devices` route caught that error and set the field list to empty; the Haml template conditionally rendered every form field from that list, leaving an empty card and an unclear generic warning.

The server now reports the exact missing keys and explains that `source.csv.map` must use the actual zero-based positions from the existing inventory. The page replaces the empty form with a read-only explanation and an example mapping. No automatic migration is attempted because neither the production CSV schema nor its comments and extra columns were available for validation. With a complete mapped CSV fixture, Chrome verified add, edit, credential persistence, manual backup submission, reload into a fresh process, and deletion without removing version history.

## RouterOS timestamp-only revisions

The checked-out Core 0.37.2 source already defines `ROUTEROS_EXPORT_TIMESTAMP` and filters generated RouterOS 6 month-name and RouterOS 7 ISO export headers in the `/export` command processor. It retains separately captured firmware information and only matches the generated `# date time by RouterOS ...` line. Existing and expanded tests exercise the real model run and compare normalized output in an isolated Rugged Git repository.

The expanded tests pass for repeated identical backups, timestamp-only RouterOS 6/7 changes, CRLF/LF-only output, real firewall changes, real interface changes, and firmware-version changes. The exact production cause cannot be proven from the screenshot: no production host was accessed, and the loaded Core Gem path, active model value, and custom model override were not observable. Do not treat source-level success as proof that the production service has loaded this Core code. The runtime verification procedure is documented in [Ubuntu upgrade and rollback](ubuntu-24.04-upgrade.md#verify-the-running-installation).

## Sidebar Configuration Search

The layout included a redundant sidebar shortcut to the configuration search already available in the top bar. The sidebar item and its JavaScript click handler are removed. The protected search route and top-bar form remain, preserving the search API and history links.
