# hibrow bugs

## BUG-003: `kill` returns before the browser has exited, so an immediate relaunch fails

**Date:** 11/10/2026
**Severity:** Medium — kill-then-relaunch of the same profile fails intermittently
**Status:** Fixed (11/10/2026)
**Affected commands:** `kill`, then `launch` / `nav` on the same profile (Chrome observed;
Firefox likely the same)

### Symptom

Restarting a profile, for example to switch between headless and windowed mode, fails
when the commands run back to back:

```bash
hibrow kill work
hibrow launch work --browser chrome --headless
hibrow nav work "https://example.com"
# Error: Browser not found
```

`kill` reports success (`"killed"`), and `launch` appears to succeed. `nav` then finds no
browser. Running the same sequence a few seconds later works.

Callers currently have to work around this by polling the OS process table until the old
browser's processes are gone, e.g. `pgrep -f .hibrow/profiles/<name>`. That ties them to
hibrow's profile directory layout and to `pgrep`, which doesn't exist on Windows.

### Root cause

`handleBrowserKill` in `gateway.zig`:

- Chrome: sends CDP `Browser.close` and returns as soon as the call is acknowledged.
- Firefox: sends Marionette `quit`, ignoring errors.

It then calls `self.evict(profile)` under the comment "Browser is gone" and replies
`"killed"`. Both `Browser.close` and `quit` only *start* shutdown. Chrome keeps running
for a short while (renderers, GPU process, profile writes) and holds the profile's
`SingletonLock` until it actually exits.

`handleBrowserLaunch` then starts with:

```zig
// Already running? Check via process scan.
const existing_info = try findBrowserInfo(self.allocator, self.io, profile);
if (existing_info) |ei| {
    ... "already_running": true, "port": ep ...
    return self.ok(id, .{ .object = obj });
}
```

If the dying browser is still in the process table, `launch` returns
`already_running: true` with the **old** port and does not start a new browser. Once the
old process exits, nothing is listening, and the next command fails with
`browser_not_found`. If the scan misses it but the old process still holds
`SingletonLock`, the new Chrome can hand off to the dying instance and exit, with the
same result.

The `already_running` path also ignores the requested mode: a windowed browser that is
still alive will be "reused" for a `--headless` launch request.

### Proposed fix

1. **Make `kill` synchronous.** After `Browser.close` / `quit`, wait until the browser's
   processes for that profile have exited (bounded, e.g. 10 s). If they haven't, terminate
   them (SIGTERM, then SIGKILL) before replying. Only then evict and return `"killed"`.
   The gateway already has process-scan logic in `findBrowserInfo`, so it can do this
   without callers reaching into the OS.
2. **Report the outcome.** Return something like `{"killed": true, "exited": true,
   "forced": false}` so callers can tell a clean exit from a forced one.
3. **Make `launch` robust too.** When the process scan finds the profile but its debug
   port doesn't answer (`/json/version` fails), treat it as exiting: wait briefly for it
   to go away, then launch fresh, rather than returning `already_running` with a dead port.
4. **Respect the requested mode.** If `already_running` is returned but the running
   browser's headless/windowed mode or browser type differs from the request, fail with a
   clear error (or restart it) instead of silently reusing it.

With (1) in place, `kill && launch` is reliable and callers can drop their process
polling.

### Fix (applied)

Implemented items 1–3 above:

- **`kill` is synchronous** (`handleBrowserKill`, `gateway.zig`). After `Browser.close` /
  `quit` it waits — via `waitForGone`, a bounded poll of `stillRunning` — until no usable
  browser remains for the profile (debug port no longer answers), up to 10 s. If it has
  not exited, `terminateProcess` sends SIGTERM to the profile's pids, waits 3 s, then
  SIGKILL. Only then does it evict and reply.
- **Outcome reported.** `kill` now returns `{"killed": true, "exited": <bool>, "forced":
  <bool>}` instead of the bare string `"killed"`.
- **`launch` verifies liveness.** The `already_running` path now reuses an instance only
  when its debug port actually answers (`portAlive`). A lingering process with a dead port
  is evicted, briefly waited out (`waitForGone`), and a fresh browser is launched instead
  of handing back a dead port.
- **New primitive.** `os.terminateProcess(pid, force)` — POSIX `kill` with SIGTERM/SIGKILL,
  Windows `OpenProcess` + `TerminateProcess`.

Item 4 (reject/restart on a headless-vs-windowed or browser-type mismatch when a browser
is genuinely still running) is **not** done; with synchronous `kill` the common
restart-to-switch-mode flow works because the old browser is fully gone before the new
launch. Reusing a *live* browser of the wrong mode without a kill is still silent.

### Verification

```bash
for i in $(seq 1 20); do
  hibrow kill t >/dev/null 2>&1
  hibrow launch t --browser chrome --headless >/dev/null && \
  hibrow nav t "about:blank" >/dev/null || echo "iteration $i failed"
done
hibrow kill t
```

Measured on macOS before the fix: 8/15 failed. After: **0/20** for Chrome, **0/10**
alternating `--headless`/windowed, **0/12** for `--browser firefox`.

(Note: the full `tests/e2e-features.sh` suite has a *separate*, pre-existing flake in
eval/push/Marionette calls issued immediately after `launch` — see BUG-004 — which this
fix neither causes nor cures.)

### Related requests (not bugs)

Found while driving a sign-in flow that waits for the browser to reach a particular page,
then reads a form field from it:

- **Wait for a URL.** Callers poll `hibrow eval <profile> "location.href"` in a loop,
  starting a new process every 0.5 s. A `hibrow wait-url <profile> <regex> [--timeout s]`
  (or `wait --url`) that blocks in the gateway and prints the matching URL would replace
  the loop. A "URL unchanged for N seconds" signal would also help callers notice that a
  page is waiting for a person.
- **Document the output contract.** Callers parse `eval` stdout as JSON and rely on exit
  status 0/non-zero from `launch`, `nav`, `kill` and `eval`. Writing that down in the
  README as stable (stdout is exactly one JSON value; errors go to stderr with non-zero
  exit) would let scripts depend on it safely.
- **Profile location.** If callers still need to know whether a profile's browser is
  alive, `hibrow ls <profile>` should be the supported way (with a field such as
  `"alive": true`), not scanning for `~/.hibrow/profiles/<name>` in the process table.
