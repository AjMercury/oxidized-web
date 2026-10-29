# Oxidized Enterprise Core and Web Integration Plan

## Repository preparation

- Web checkout: `AjMercury/oxidized-web`, preserved on `codex/enterprise-integration`.
- Web remotes: `origin` is the customized fork; `upstream` is `ytti/oxidized-web`.
- Core checkout: `AjMercury/oxidized`, on `codex/enterprise-integration`.
- Core remotes: `origin` is the existing fork; `upstream` is `ytti/oxidized`.
- Core fork already exists, so no fork creation was needed.
- Public upstream heads observed during preparation: Core `3137b1710abda3731f3efdb2762eb3776adf98a2`; Web `83df31531c4a829164d12fc316381e534636f7df`.
- Local Core `master` starts at the observed Core upstream head. The Web checkout contains the custom Enterprise UI and is kept intact; its existing history begins with the custom UI commit `cc70b34` and release commit `d2b4a41`.

## Initial findings

1. Web is a Sinatra extension over Core's shared `Oxidized::Nodes` object. Its current routes call `list`, `fetch`, `load`, `next`, `show`, `version`, `get_version`, and `get_diff`.
2. Web 0.18.1.1 declares Ruby `>= 3.0` and Core `>= 0.34.1`; Core's current gemspec also declares Ruby `>= 3.0`. This is a dependency floor, not evidence that every Core/Web pair is behaviorally compatible.
3. The Core API inspected on the current upstream head has the required inventory and backup methods. `Nodes#load` reads from the configured source; `Worker#reload` invokes it. A full load retains run statistics and last-run status for matching node names. It calls `Output.clean_obsolete_nodes` after inventory replacement, but cleanup only runs when `output.clean_obsolete_nodes` is enabled and is output-backend-specific.
4. Core CSV source is read-only and supports a configurable file, delimiter, field map, vars map, model/group mapping, comments beginning with `#`, and optional GPG encryption. A Web writer must preserve original rows and comments and must refuse unsupported encrypted configurations unless it can safely round-trip them.
5. The current Web has no administrator authentication or authorization configuration. `GET /reload` and `GET /node/next/...` cause state changes; `PUT /node/next/...` triggers backup with metadata. Device management cannot be enabled safely before server-side administrator authentication, authorization, and CSRF protection are in place.
6. Inventory listing serializes node vars. Hidden variable filtering currently occurs on `/node/show`, so secret-bearing vars may be exposed by `/nodes` unless filtered consistently.
7. No production host was accessed. Ruby and Bundler are not installed in the current development environment; Node.js is present. Ruby tests and dependency resolution therefore cannot yet be executed here.

## Compatibility matrix (initial, pending executable verification)

| Oxidized Core | Oxidized Web | Evidence | Status |
|---|---|---|---|
| 0.37.0 | 0.18.1.1 | User-reported production versions; source-level API comparison against current Core upstream and checked-out Web | Expected compatible for existing read, history, reload, and next APIs; production pair not runtime-verified |
| Current upstream Core (`3137b17`) | Current customized Web (`0.18.1.1`) | Core API and Web call sites inspected; gemspec allows Core >= 0.34.1 | Candidate integration target; executable suite blocked by missing Ruby/Bundler |
| Core 0.34.1 | Current Web | Gem dependency lower bound only | Not yet verified; do not represent the lower bound as tested compatibility |

Record supported version ranges only after CI jobs exercise each pair. Core and Web version numbers remain independent.

## Implementation sequence

1. Add source-level compatibility tests for Core node APIs and preserve existing HTTP/JSON response contracts.
2. Fix demonstrated Web data leakage and error handling, including filtering hidden vars in inventory responses and mapping Core lookup failures to appropriate HTTP responses.
3. Add administrator authentication, server-side authorization, CSRF checks for state-changing requests, and audit events. All mutating operations must fail closed when authentication is not configured; retain read-only access according to documented policy.
4. Add explicit source capability detection. Implement CSV read/modify/write only for supported plaintext CSV layouts; preserve comments, mappings, delimiters, unrelated columns, and records. Reject GPG/encrypted CSV and non-CSV sources as read-only until a native safe writer exists.
5. Implement atomic CSV persistence with an inter-process lock, temp file in the same directory, fsync/rename, duplicate checks, and rollback/error reporting. Avoid logging or returning credential fields.
6. Refresh inventory after a successful write. Validate Core's reload/cleanup settings and report reload errors without claiming persistence failed if the file was successfully committed. Preserve output Git history; never clean obsolete output as a side effect of a UI edit/delete.
7. Add device management UI and use only Core-supported model names and fields. Trigger first backup through the existing Core `next` API and report asynchronous status from Core node state.
8. Add focused isolated tests for authentication, CSRF, CSV mutation, concurrent writers, reload, backup trigger, and API regressions; document deploy/rollback without deploying.
9. Run Ruby tests, JavaScript tests, and lint when a compatible Ruby toolchain is available. Publish separate Web/Core branches and draft PRs after verified changes; no automatic merge or production deployment.

## Plan status and constraints

This is the required implementation plan, not a claim that the acceptance criteria are complete. Begin implementation in Web first. Modify Core only if a verified missing Core capability prevents a safe Web-layer implementation. The local Core clone and branches are prepared, but the runtime limitation currently prevents execution of Ruby tests and compatibility verification.
