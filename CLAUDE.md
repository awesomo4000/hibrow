# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**hibrow** is a simplified Zig reimplementation of [bromux](x/bromux/) — a browser multiplexer ("tmux for browsers"). The original Python project lives in `x/bromux/` as a reference (gitignored). hibrow requires Zig 0.16.0 (exactly).

The core idea: a daemon manages persistent browser instances via Chrome DevTools Protocol (CDP), and multiple CLI clients connect to the daemon over Unix sockets using JSON-RPC 2.0. Browsers survive client disconnects and daemon restarts, just like tmux sessions survive terminal closes.

hibrow works both as a **CLI tool** and as a **Zig library** with a clean API for embedding in other programs.

## Architecture

```
CLI Clients ──JSON-RPC 2.0──> Gateway Daemon ──CDP/WebSocket──> Chromium Browsers
            (Unix socket)         |                               (--remote-debugging-port)
                                  |
                            Discovery-first:
                            scans processes for
                            CDP-enabled browsers
```

### Three layers:

1. **Client** — CLI that sends JSON-RPC requests over a Unix domain socket
2. **Gateway Daemon** — single-instance server that discovers and manages browsers. Serializes CDP access per-browser (CDP is not thread-safe for concurrent clients). Discovery-first: finds browsers by scanning processes for `--remote-debugging-port` flags.
3. **Browser** — Chromium instances launched with `--remote-debugging-port` and `--user-data-dir` for persistent profiles

### Key protocols:
- **Client <-> Gateway**: JSON-RPC 2.0 over Unix domain socket (`/tmp/hibrow-{uid}/gateway.sock`)
- **Gateway <-> Browser**: Chrome DevTools Protocol over WebSocket (connect to `http://localhost:{port}/json` for endpoint discovery, then WebSocket to the page's `webSocketDebuggerUrl`)

### Key design principles:
- **Discovery over state** — find browsers by scanning processes, don't track them
- **Stateless operations** — each request triggers fresh discovery if needed
- **Simple registry** — only store profile name -> directory mappings (JSON file at `~/.hibrow/profiles.json`)
- **Automatic recovery** — browsers found automatically after crashes/restarts

## Module Layout

```
src/
  root.zig        # Library root — public API re-exports for embedding
  main.zig        # CLI entry point — parses args, dispatches commands
  protocol.zig    # JSON-RPC 2.0 types (Request, Response, Error) and ser/de
  gateway.zig     # Gateway daemon (Server) + gateway client (Client)
  browser.zig     # Find chromium binary, spawn with flags, discover running instances
  tab.zig         # Stable tab indexing (profile:N -> CDP targetId, monotonic counter)
  cdp.zig         # CDP protocol client (HTTP discovery + WebSocket commands)
  websocket.zig   # WebSocket client (RFC 6455, text frames for CDP)
```

## Library API

Other Zig programs import hibrow as a module:

```zig
const hibrow = @import("hibrow");
var client = try hibrow.Client.connect(allocator);
defer client.disconnect();
const result = try client.eval("work", "document.title");
```

Submodules are also accessible: `hibrow.protocol`, `hibrow.gateway`, `hibrow.browser`, `hibrow.tab`, `hibrow.cdp`, `hibrow.websocket`.

## CLI Commands

```
hibrow launch <profile> [--proxy <url>] [--proxy-dns]
hibrow ls [profile]
hibrow nav <profile[:tab]> <url>
hibrow eval <profile[:tab]> "<js>" | -f <file> | -f-
hibrow url <profile[:tab]>
hibrow console <profile[:tab]>
hibrow tab list|new|close|switch <profile[:tab]>
hibrow gateway status|stop
```

## Build & Test Commands

```bash
zig build                              # Build the project
zig build test                         # Run all tests
zig build run -- --help                # Run the CLI
zig build -Doptimize=.ReleaseSafe      # Build with optimizations
```

## Zig 0.16.0 Conventions

0.16 landed the async-I/O rework ("Io as an interface"): `std.net` is gone,
`std.fs.File`/`Dir` moved to `std.Io.File`/`std.Io.Dir`, and every socket/file
op takes an `Io`. See `docs/zig-0.16-migration.md` for the full port notes.

**Entry point / Io**: `pub fn main(init: std.process.Init) !void`. The runtime
provides `init.gpa` (GP allocator w/ leak checking), `init.io` (an `std.Io`),
`init.arena`, and `init.minimal.args`. Thread `io` into anything that touches a
socket or file; hibrow stores it in the structs that own a stream and keeps a
process-wide `g_io` in main.zig for the output helpers.

**Args**: `var it = try init.minimal.args.iterateAllocator(gpa);` then
`it.skip()` / `it.next()`. (`std.process.argsWithAllocator` was removed.)

**I/O**: `var w = std.Io.File.stdout().writerStreaming(io, &buf); const out = &w.interface;`
— functions take `*std.Io.Writer`; always `flush()`; never copy `.interface`.
Prefer `writerStreaming`/`readerStreaming` over `writer`/`reader` for stdio and
pipes (the positional default `pwrite`s at offset 0 — see BUG-002). File reads:
`std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`; whole-file write:
`file.writeStreamingAll(io, bytes)`; `file.close(io)`.

**Net**: `std.Io.net.UnixAddress.init(path)` -> `.connect(io)` / `.listen(io, opts)`;
`std.Io.net.Server.accept(io)` -> `Stream`; `Stream.close(io)`. Wrap an existing
fd with `std.Io.net.Stream{ .socket = .{ .handle = fd } }`. Wire-protocol data
transfer uses raw `std.posix.read` + `std.c.write` on `stream.socket.handle`
(the Threaded backend uses blocking sockets; `std.posix.write` was removed) —
this preserves the growable, no-over-read `readLine` needed for multi-MB
responses. HTTP: `std.http.Client{ .allocator = a, .io = io }`.

**Process**: `std.process.spawn(io, .{ .argv = ..., .stdin/out/err = .ignore, .pgid = 0 })`,
then `child.id.?`. Use `std.c.getpid()` / `std.c.getuid()` / `std.c.getenv()`.
Sleeping: `std.Thread.sleep(ns)` (use `std.time.ns_per_ms`).

**Allocator**: `std.heap.DebugAllocator(.{})` (`GeneralPurposeAllocator` was
removed). `std.heap.ArenaAllocator` for request-scoped work.

**Containers**: unmanaged. `var list: std.ArrayList(T) = .empty;` then
`list.append(allocator, item)` / `list.deinit(allocator)`. NOTE the JSON
asymmetry: `json.ObjectMap` is now UNMANAGED (pass allocator per-call) while
`json.Array` is still MANAGED (allocator stored at init).

**Build**: `b.createModule()` + `b.addExecutable(.{ .root_module = mod })`.
JSON: `std.json.Stringify.valueAlloc(allocator, value, .{})`.

**macOS build**: `zig build` may fail to link (`undefined symbol:
__availability_version_check`) because newer Command Line Tools SDKs (26/27)
ship `.tbd` files the 0.16 linker cannot parse. Build with SDK detection off:
`DEVELOPER_DIR=/dev/null zig build`.

**General**: error unions (`!`), allocator-passing pattern, strings are `[]const u8`.

## Reference Material

The `x/` directory (gitignored) contains:
- `x/bromux/` — full Python implementation
- `x/BROMUX_API_REFERENCE.md` — bromux API reference
- `x/BROMUX_CDP_PROTOCOL.md` — CDP protocol details
- `x/BROMUX_PATTERNS.md` — implementation patterns from bromux
- `x/BROMUX_REFERENCE_INDEX.md` — index of reference docs
- `x/BROMUX_SUMMARY.txt` — bromux architecture summary

Key bromux specs:
- `x/bromux/specs/025-simplified-gateway-refactor.md` — target architecture
- `x/bromux/specs/002-browser-gateway-architecture.md` — gateway design
- `x/bromux/specs/003-tmux-for-browsers.md` — tmux analogy and UX goals

## CDP Protocol Notes

1. **Discovery**: `GET http://localhost:{port}/json` returns JSON array of targets with `webSocketDebuggerUrl`
2. **Connection**: WebSocket to the page's `webSocketDebuggerUrl`
3. **Commands**: `{"id": N, "method": "...", "params": {...}}` over WebSocket
4. **Key methods**: `Runtime.evaluate`, `Page.navigate`, `Page.captureScreenshot`, `Target.getTargets`, `Target.createTarget`, `Target.closeTarget`, `Target.activateTarget`

## JSON-RPC 2.0 Protocol

Gateway methods:
- `browser.list` — discover and list all running browsers
- `browser.get` — find browser by profile name
- `browser.launch` — launch new browser with profile
- `browser.eval` — execute JavaScript in browser
- `browser.navigate` — navigate to URL
- `browser.screenshot` — capture screenshot
- `gateway.status` — health check
- `gateway.shutdown` — graceful shutdown

Wire format: line-delimited JSON over Unix socket.
Standard error codes: -32700 (parse), -32600 (invalid request), -32601 (method not found), -32602 (invalid params), -32603 (internal).
Application error codes: -32000 (browser not found), -32001 (launch failed), -32002 (CDP error).
