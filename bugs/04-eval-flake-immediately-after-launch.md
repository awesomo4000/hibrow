# hibrow bugs

## BUG-004: commands issued immediately after `launch` fail intermittently

**Date:** 11/10/2026
**Severity:** Medium — the feature e2e suite is flaky; real scripts that launch and
immediately drive a browser hit it too
**Status:** Largely fixed (11/10/2026) — flaky suite runs dropped from ~1-in-2 to ~1-in-18.
Fixes: Marionette connect-retry, chrome stale-socket retry, and `click` auto-wait. The
remaining residual is now tab lifecycle (`tab new`/`tab switch`), not click or transport
(see below)
**Affected commands:** `eval`, `push`, `wait`, `text`, `click` — the first few commands
after `launch` + `nav`, on both Chrome and Firefox

### Symptom

Running `tests/e2e-features.sh` repeatedly, roughly one run in two to six fails, always in
the early block right after `launch`/`nav`, never deterministically. Observed failures:

- Chrome: `push sets window var` / `push sets input value` return `null`, `""`, or
  `Error: eval failed: UnexpectedEndOfInput`.
- Chrome shadow block: `text pierces shadow` returns the previous page's text, `shadow >>>
  click` / `nested shadow click` return `Error: javascript error` or
  `UnexpectedEndOfInput`.
- Firefox: `eval returns value`, `wait --gone`, `push` return `Error: Marionette
  connection failed`.

A given run fails 1–4 of these; most runs fail zero or one. The dedicated BUG-003 repro
(kill → relaunch → nav, no early eval burst) does **not** flake, so this is specific to
hammering a freshly launched browser.

### Pre-existing, not from BUG-003

Confirmed by stashing the BUG-003 fix and rebuilding: the prior binary flakes the same way
(4 of 6 runs, some with 3–4 failures). The BUG-003 fix neither causes nor cures it. They
are independent bugs that happen to share a neighbourhood (browser lifecycle timing).

### Suspected cause (unconfirmed)

The errors point at a connection used before it is valid, not at wrong logic:

- `UnexpectedEndOfInput` is the gateway reading EOF on a CDP websocket — a cached
  connection that Chrome has since closed. Chrome swaps its page target around the first
  real navigation (the initial `about:blank` target goes away), so a connection cached
  against the old target, or a resolution cached before the first nav, can be dead on the
  next `eval`. The connection/resolution caches may need to drop an entry when the target
  changes, or detect the EOF and reconnect once rather than surfacing it.
- `Marionette connection failed` right after a Firefox `launch` suggests the Marionette
  port is accepted into the resolution/connection path before it is actually ready, so the
  first connect races startup.
- `text pierces shadow` returning the *previous* page's text suggests a command ran against
  a target/context that had not finished the latest `nav` — a readiness gap even though
  `nav` is supposed to wait for load.

### Proposed investigation

1. Reproduce in isolation: `launch`, then a tight loop of `eval`/`push` with no sleeps, and
   log when a cached CDP/Marionette connection returns EOF or a connect fails.
2. On a read that ends in EOF (`UnexpectedEndOfInput`) against a cached connection, evict
   and retry once before failing — a cached socket going stale is expected, per the
   resolution-cache design notes.
3. Check whether the connection cache keys on a target that can change across the first
   navigation, and invalidate it when the active target changes.
4. For Firefox, confirm the Marionette port is actually accepting before caching a
   resolution for it (a short readiness probe at launch, like the Chrome `/json/version`
   check).

### Fix (applied)

Two distinct causes were found and fixed; a third, rarer one remains.

1. **Firefox — Marionette single-session race (the dominant failure).** Every gateway
   command opened a fresh Marionette connection, and Marionette allows only one session at
   a time. When the previous command's socket had not finished tearing its session down,
   `NewSession` (or the connect) transiently failed, surfaced as "Marionette connection
   failed". Fixed in `marionette.zig`: `connect` now retries up to 6 times with a short
   backoff, resetting partial state between attempts. The happy path still connects on the
   first try, so no added latency when healthy.
2. **Chrome — stale cached CDP socket.** Chrome can close a target's websocket between
   commands (a tab closing, an idle teardown), leaving the gateway's cached connection
   dead; the next use failed with `UnexpectedEndOfInput` and the handler surfaced it with
   no retry. Fixed in `gateway.zig` with `chromeOp`, a helper that runs a connection op and,
   on failure, evicts and reconnects once before giving up. All seven chrome connection
   sites (eval, frames, click, wait, navigate, url, screenshot) now go through it, replacing
   seven copies of the no-retry block.

Measured on macOS: flaky full-suite runs went from roughly 5-6 of 12 (before) to **1 of
14** (after).

### Remaining residual — investigated, re-diagnosed

After the two fixes the suite still flakes ~1 run in 12-14. An earlier guess — that the
gateway closes the client connection mid-response — was **investigated and disproven**. The
gateway's connection handler was instrumented to log every failure branch (failed
request-read, empty request line, failed response-write) and the daemon's stderr captured
across 24 real suite runs (with restarts) plus a persistent-gateway run. Findings:

- **The gateway transport is clean.** Zero failure-branch logs across all 24 runs. The
  gateway always read a request and wrote a complete response; it never closed early. So
  the residual is *not* a client↔gateway bug, and "make the gateway always write one
  complete response" was the wrong target.
- **Most of the residual is frame/element readiness, surfaced by the test's own shape.**
  The e2e fixtures `g.html` and `shadow.html` both start their state node as the literal
  text `idle`. The failing checks (`click in frame`, `shadow >>> click`) run `click`
  (discarding its output) then `eval` the state node. `click`/`clickInFrame` correctly
  return `error.ElementNotFound` when the target is not present yet (a nested frame subtree
  or shadow tree that has not finished loading), but the suite throws that away, so the
  follow-up `eval` reads the unchanged initial `idle`. In other words these are clicks that
  legitimately failed because the element was not ready, not wrong values from a desync.
- **A rare genuine transport EOF remains unexplained.** One run in 24 showed `tab switch …
  UnexpectedEndOfInput` with **no** gateway-side log — client read EOF although the gateway
  recorded no failure. Single occurrence, mechanism not yet pinned.

Next steps, in priority order:

1. **Make `click` wait for its target** — **done.** `click`/`clickInFrame` now wait up to
   `--timeout` (default 5s) for the element: Chrome awaits a page-side MutationObserver that
   resolves with the element's rect the instant it matches; Firefox uses Marionette's native
   implicit wait. The `chromeOp` retry was also narrowed to transient connection errors so a
   genuine miss fails in one timeout, not two. Measured effect: flaky suite runs dropped from
   ~1-in-12 to ~1-in-18, and the frame/shadow `click` failures no longer appear.
2. Separately, have the e2e not discard `click` output, so a failed click is reported as a
   click failure rather than as a confusing stale-value read downstream. (Still open.)
3. **Remaining residual is now tab lifecycle, not click.** The failures still seen (~1 in 18)
   are `tab new adds a tab` returning a count of 1 instead of 2, and the earlier rare `tab
   switch … UnexpectedEndOfInput` — i.e. `tab.new`/`tab.switch` occasionally not taking
   effect or racing the count read. Next: instrument the tab handlers (CDP `Target.createTarget`
   / target-list timing) to see whether the new target is not yet listed when the count is read.

### Verification

```bash
for i in $(seq 1 20); do ./tests/e2e-features.sh >/dev/null 2>&1 || echo "run $i failed"; done
```

Expect at most the rare client↔gateway residual above; zero Marionette-connect or
chrome stale-socket failures.
