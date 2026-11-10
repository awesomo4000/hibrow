# hibrow bugs

## BUG-006: clients keep using an old gateway after an upgrade, and a second gateway orphans the first

**Date:** 11/10/2026
**Severity:** Medium. After a rebuild or upgrade, commands silently run the old gateway
code, so fixed bugs appear unfixed. Orphaned daemons pile up and are never reclaimed.
**Status:** Fixed (11/10/2026). Two parts:
- **Stale gateway** — the CLI warns (on stderr, once per invocation) when the running gateway
  was built from a different hibrow binary than the CLI. Warn-only by deliberate choice: the
  gateway keeps running and keeps its browsers; the user decides whether to restart it.
- **Orphaned gateways** — a serving daemon now holds an exclusive advisory lock on
  `gateway.lock` for its lifetime, so at most one daemon ever owns the socket; losers of the
  startup race exit cleanly instead of stealing the socket. See "Fix applied" below.
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

### Fix applied — orphaned gateways (singleton lock)

`serve` now takes an exclusive advisory lock (`std.Io.Dir.createFileAbsolute` with
`lock = .exclusive, lock_nonblocking = true`) on `gateway.lock` in the runtime dir before
it touches the socket, and holds it (the open `File`) for the daemon's lifetime. The OS
releases the lock when the process closes the file or exits — even on a crash — so a dead
daemon never blocks the next one.

- **Lock acquired:** we are the sole owner. Any socket file present is a dead daemon's
  leftover, so removing it cannot steal a live socket. Bind and serve.
- **Lock held by someone else** (`error.WouldBlock`): a daemon already owns the socket.
  `serve` returns `error.GatewayAlreadyRunning` without deleting anything; `gateway serve`
  prints "gateway already running" and exits 0. A lost auto-start race ends here, and the
  client connects to the winner.

Two subtleties that had to be right:
- `self.socket_path` is assigned **only after** the lock is won. A loser must not own the
  path, or its `deinit` would delete the live winner's socket file and wedge it (daemon
  alive, no socket, holding the lock — found in testing).
- The client's auto-start poll re-forks `gateway serve` about once a second while waiting,
  so a fork that lost the race to a daemon that was *shutting down* (its lock briefly held)
  is retried once the lock frees, instead of giving up with `GatewayStartFailed`.

Still optional, not done: a `gateway stop --all` to reap stragglers left by builds from
before this fix. With the lock in place no new orphans are created, so this is only cleanup
for pre-existing ones (a reboot or manual kill also clears them).

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

Orphaned gateways (done):

```bash
# 1. No orphans from concurrent auto-start
hibrow gateway stop
for i in $(seq 1 10); do hibrow ls >/dev/null & done; wait
pgrep -f "hibrow gateway serve" | wc -l            # expect 1

# 2. Manual second serve refuses cleanly
hibrow gateway serve                               # prints "gateway already running", exits 0

# 3. A hard-killed daemon leaves a stale lock; the next command still starts
kill -9 "$(pgrep -f 'hibrow gateway serve')"; hibrow ls >/dev/null   # works (new daemon)

# 4. Rapid stop/launch cycles never wedge
for i in $(seq 1 15); do hibrow gateway stop; hibrow ls >/dev/null; done   # all succeed, 1 daemon
```
