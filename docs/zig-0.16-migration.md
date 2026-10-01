# Zig 0.16.0 migration plan

Branch: `zig-0.16` (off `main`). Target: build + `zig build test` green under
Zig 0.16.0 while `main` stays on 0.15.2.

Build/run on this machine uses the SDK workaround:
`DEVELOPER_DIR=/dev/null ~/.zvm/0.16.0/zig build`.

## Status: build + tests green (not yet runtime-smoke-tested)

`DEVELOPER_DIR=/dev/null ~/.zvm/0.16.0/zig build` and `... zig build test` both
pass (118/118 tests); the binary runs. Not yet exercised against a live
Chrome/Firefox — that smoke test (launch/nav/eval/screenshot/tab) is the
remaining verification.

### Design decision: raw posix-fd I/O for the wire protocol
Data transfer over the gateway/CDP/Marionette sockets uses `std.posix.read` /
`std.c.write` on the fd inside the `std.Io.net.Stream`, rather than the
`Io.Reader`/`Io.Writer` wrappers. Rationale: the default Threaded backend uses
**blocking** sockets, and this preserves the growable, no-over-read `readLine`
needed for multi-MB screenshot responses without the buffered reader swallowing
bytes. `Io` is still used for socket lifecycle (connect/accept/close) and all
file I/O. Trade-off: bypasses Io cancellation (hibrow is synchronous by design)
and assumes blocking sockets. Candidate for later cleanup to full `Io.Reader`/
`Io.Writer` if desired.

## Why this is a real migration

0.16 landed the async-I/O rework ("Io as an interface"). Concretely:

- `std.net` is **removed**. Networking is now `std.Io.net` (`Stream`, `Server`,
  `IpAddress`, `UnixAddress`), and every operation takes an `Io`.
- `std.fs.File` moved to `std.Io.File`; `.writer()/.reader()` now take
  `(io, buffer)`.
- `std.http.Client` gained an `io: Io` field.
- Program entry changed: `pub fn main(init: std.process.Init)` provides
  `init.io`, `init.gpa`, `init.arena`, `init.minimal.args`, `init.environ_map`.
- `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`.
- `std.process.argsWithAllocator` removed → `std.process.Args` +
  `iterateAllocator(gpa)`.

The core consequence: an `Io` must be threaded through everything that touches a
socket or file — the gateway server/client, websocket, cdp, marionette, browser.
Structs that hold a `stream` must also hold (or be passed) an `io`.

## I/O surface inventory (what breaks)

| File | Usage | 0.16 replacement |
|------|-------|------------------|
| main.zig:70 | `GeneralPurposeAllocator` | `init.gpa` (drop manual GPA) |
| main.zig:74 | `argsWithAllocator` | `init.minimal.args.iterateAllocator(gpa)` |
| main.zig:131,141 | `File.stdout()/stderr().writerStreaming(&buf)` | `std.Io.File...writerStreaming(io, &buf)` |
| main.zig:317,630 | `File.stdin().readToEndAlloc(a, n)` | `stdin.reader(io,&buf).interface.allocRemaining(gpa, .limited(n))` |
| gateway.zig:41,156,205,237,1007,1013,1037,1273-1447 | `std.net.Stream/Server/Address/connectUnixSocket`, socketpair `Stream{.handle=fd}` | `std.Io.net.Stream/Server/UnixAddress`, `listen(&addr, io, opts)`; verify fd-wrapping API |
| websocket.zig:271 | `net.Stream` field | `std.Io.net.Stream` + store/thread `io` |
| marionette.zig:45 | `net.Stream` field | `std.Io.net.Stream` + store/thread `io` |
| browser.zig:475-476 | `Address.resolveIp` + `tcpConnectToAddress` (port probe) | `std.Io.net.IpAddress` + connect(io) |
| gateway.zig:1057 | `file.writer(&buf)` (pid file) | `file.writer(io, &buf)` |
| cdp.zig:519,539 | `std.http.Client{ .allocator }` + `fetch` | add `.io = io`; `fetch` stays |

## Ordered steps

**Step 0 — allocator rename (done, uncommitted).**
`main.zig:70` `GeneralPurposeAllocator` → `DebugAllocator`. Will be superseded
by Step 1 (use `init.gpa`); keep for now so partial builds progress.

**Step 1 — entry point + Io plumbing (main.zig).**
- `pub fn main() !void` → `pub fn main(init: std.process.Init) !void`.
- Use `init.gpa` as the allocator, `const io = init.io;`.
- Replace arg iteration with `init.minimal.args.iterateAllocator(init.gpa)`.
- Thread `io` into every command handler. Handler signature today is
  `fn(allocator, *args)`; add `io` (or pass a small context struct).
- Update `writeStdout`/`writeStderr` to `writerStreaming(io, &buf)` and stdin
  reads to the reader `allocRemaining` pattern. Keep the streaming-mode choice
  (the BUG-002 fix) — `writerStreaming` still exists, just takes `io`.

**Step 2 — gateway net layer (gateway.zig).**
- Add `io: Io` to `Server` and `Client` structs.
- `std.net.Address.initUnix` → `std.Io.net.UnixAddress`; `std.net.Server` →
  `std.Io.net.Server` via `UnixAddress.listen(&addr, io, opts)`.
- `connectUnixSocket(path)` → `UnixAddress` connect through `io`.
- Rework the socketpair / `Stream{ .handle = fd }` spots (console streaming and
  IPC) — confirm how 0.16 wraps an existing fd into a `Stream`. **Highest-risk
  item**; may need a raw `posix` path if no direct wrapper exists.
- `readLine(stream)` → stream reader that takes `io`.

**Step 3 — websocket.zig + marionette.zig.**
- Change `stream: ?net.Stream` fields to `std.Io.net.Stream`.
- Give each connection access to `io` (store it alongside the stream).
- Frame read/write and connect calls take `io`.

**Step 4 — browser.zig port probe.**
- `resolveIp` + `tcpConnectToAddress` → `std.Io.net.IpAddress` + connect(io),
  with the same "is the port open?" semantics.

**Step 5 — cdp.zig HTTP.**
- `std.http.Client{ .allocator = a }` → `.{ .allocator = a, .io = io }`.
  `client.fetch(...)` signature is unchanged.

**Step 6 — build + test.**
- `DEVELOPER_DIR=/dev/null ~/.zvm/0.16.0/zig build` then `... zig build test`.
- Confirm build.zig needs no changes (module wiring looks version-agnostic).
- Manual smoke: launch, ls, nav, eval, tab, screenshot, console (the console
  path exercises the reworked socketpair streaming).

## Open questions / risks — resolved during planning

1. **fd → Stream wrapping** (gateway socketpair, console streaming): **solved.**
   `Socket.handle` is `std.posix.fd_t`; wrap a raw fd with
   `std.Io.net.Stream{ .socket = .{ .handle = fd } }`. Read/write via
   `Stream.Reader/Writer.init(stream, io, &buf)`.
2. **Blocking semantics under `init.io`**: **confirmed.** Stream/Server ops call
   `io.vtable.net*`, which the default Threaded backend implements as blocking
   syscalls — synchronous behavior matches today's code.
3. **`std.fs.File`**: **confirmed removed.** All File refs become `std.Io.File`.
4. **Daemonization** (double-fork / detach) interaction with the Io backend —
   still to verify the gateway detaches cleanly; check during Step 2.

### 0.16 net API cheat-sheet
- `std.Io.net.UnixAddress.init(path)` → `.connect(io)` / `.listen(io, opts)`
- `std.Io.net.IpAddress` → `.connect(io, opts)` (port probe)
- `std.Io.net.Server.accept(io)` → `Stream` (blocking)
- `Stream{ .socket = .{ .handle = fd } }` from an existing fd
- `Stream.Reader.init(stream, io, &buf)` / `Stream.Writer.init(stream, io, &buf)`
