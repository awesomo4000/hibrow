# hibrow bugs

## BUG-004: commands issued immediately after `launch` fail intermittently

**Date:** 11/10/2026
**Severity:** Medium — the feature e2e suite is flaky; real scripts that launch and
immediately drive a browser hit it too
**Status:** Open
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

### Verification (once fixed)

```bash
for i in $(seq 1 20); do ./tests/e2e-features.sh >/dev/null 2>&1 || echo "run $i failed"; done
```

Expect zero failed runs across both browsers.
