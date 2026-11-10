# hibrow bugs

## BUG-006: clients keep using an old gateway after an upgrade, and a second gateway orphans the first

**Date:** 11/10/2026
**Severity:** Medium. After a rebuild or upgrade, commands silently run the old gateway
code, so fixed bugs appear unfixed. Orphaned daemons pile up and are never reclaimed.
**Status:** Partially fixed (11/10/2026). The stale-gateway half is addressed: the CLI now
warns (on stderr, once per invocation) when the running gateway was built from a different
hibrow binary than the CLI. Warn-only by deliberate choice — the gateway keeps running and
keeps its browsers; the user decides whether to restart it. The orphaned-gateway half
(socket-steal race) is still open — see "Remaining" below.
**Affected commands:** every command that goes through the gateway; `gateway serve`
(auto-start)

### Symptom

1. **Stale gateway.** Rebuilding hibrow (or replacing the installed binary) leaves the
   running `hibrow gateway serve` from the previous build in place. Every new client
   connects to it, so the new build's gateway-side fixes do not take effect until someone
   runs `hibrow gateway stop`. Nothing reports the mismatch: `hibrow --version` prints the
   client's version, `gateway status` prints only `"running"`, and two builds of the same
   release both say `0.1.0`.

   Observed: after the BUG-003 fix was built, the gateway answering on the socket had been
   started hours earlier by a binary built before the fix. Testing the fix with the new
   binary would have exercised the old `kill`. The kill/launch/nav loop passed 20/20 only
   after the gateway was stopped and auto-started again from the new binary.

2. **Orphaned gateways.** Three `hibrow gateway serve` processes were running at once.
   Each held a listening Unix socket named `/tmp/hibrow-<uid>/gateway.sock`, but only the
   newest was bound to the file at that path. The other two were listening on socket files
   that had been unlinked, so no client could reach them, and they would have run until
   reboot. One had been up for about a day.

### Root cause

- `Client.connectImpl` connects and starts sending requests with no handshake. The client
  never learns which build the gateway is.
- `Server.serve` unconditionally deletes the socket file before binding:

  ```zig
  // Remove stale socket file if it exists
  std.Io.Dir.deleteFileAbsolute(self.io, sock_path) catch {};
  ```

  It never checks whether a live gateway is listening there. Any second `gateway serve`
  steals the path from the first, and the first keeps running, unreachable. This happens
  when two clients find no gateway at the same moment and both auto-start one, when a
  connect attempt fails transiently, or when `gateway serve` is run by hand. The PID file
  is overwritten the same way, so `gateway stop` can only ever reach the newest daemon.

### Fix applied — stale-gateway detection (warn-only)

Implemented differently from the round-trip sketch below, and simpler:

1. **Build fingerprint via content hash.** `build.zig` hashes the source files (all of
   `src/*.zig` behind the library plus `main.zig`) into a `build_id`, injected with
   `b.addOptions` and read by both the daemon and the CLI (they are the same binary).
   Chosen over an executable-mtime stat or a build-time stamp because it needs no child
   process (zig's macOS build environment breaks the `/usr/bin/git` xcode shim), it is
   reproducible, and it changes on any source edit — including uncommitted ones, which a
   git hash would miss. The reads are declared with `dependOnFileContents` so a source
   change re-runs configure and regenerates the id instead of serving a cached one.

2. **Piggyback, not a round trip.** Every gateway response carries the daemon's `build_id`
   in a `gw` field (the gateway is one-request-per-connection, so a separate `gateway.status`
   probe would mean a second connection on every command). The client compares `gw` to its
   own `build_id` on the response it already receives and, on a mismatch, prints one note to
   stderr (once per process, via a `warned` flag). Zero extra round trips, and stderr so it
   never contaminates command output an agent parses.

3. **Warn-only — never restart, never refuse.** The sketch below proposed auto-restarting a
   stale gateway. That was deliberately not done: a restart (even though browsers survive it)
   is a surprise the user did not ask for, and "lose browser instances / refuse to run" is
   exactly what must not happen. The note tells the user to run `hibrow gateway stop` if they
   want the new build; the choice stays theirs.

### Remaining — orphaned gateways (socket-steal race), still open

The sketch below for this half still stands:

1. **Never steal a live socket.** In `serve`, before deleting the socket file, try to
   connect to it. If something answers, exit with "gateway already running (pid N)"
   instead of unlinking it. To close the race between two daemons starting at once, take
   an exclusive lock (`flock`) on a lock file in the runtime directory. Hold it for the
   daemon's lifetime, and only delete or bind the socket while holding it. The loser of
   the race exits, and its client connects to the winner.

2. **Make `gateway stop` find stragglers.** Optionally have `gateway status` or
   `gateway stop --all` report or stop other `hibrow gateway serve` processes for this
   user that are not the one bound to the socket. With (1) in place none should exist,
   but this cleans up ones left by older builds.

### Verification

Stale-gateway detection (done):

```bash
# A stale gateway triggers a one-line stderr note; the command still runs.
mise run build && cp zig-out/bin/hibrow /tmp/hibA      # build A
# edit any src file, then:
mise run build && cp zig-out/bin/hibrow /tmp/hibB      # build B (different build_id)
/tmp/hibA gateway stop; /tmp/hibA launch p --headless  # daemon from A
/tmp/hibB eval p "1+1"                                  # stderr: "...different hibrow binary..."; stdout: 2
/tmp/hibA eval p "1+1"                                  # no note (same build)
```

Orphaned gateways (remaining):

```bash
# 1. No orphans from concurrent auto-start
hibrow gateway stop
for i in $(seq 1 8); do hibrow ls >/dev/null & done; wait
pgrep -f "hibrow gateway serve" | wc -l            # expect 1

# 2. Manual second serve refuses
hibrow gateway serve; echo $?                      # non-zero, "already running"
```
