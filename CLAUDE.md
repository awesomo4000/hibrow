# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**hibrow** is a simplified Zig reimplementation of [bromux](x/bromux/) — a browser multiplexer ("tmux for browsers"). The original Python project lives in `x/bromux/` as a reference (gitignored). hibrow targets Zig 0.15.2.

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

## Zig 0.15.2 Conventions

**I/O (Writergate)**: Zig 0.15.2 overhauled I/O. Key patterns:
- `var buf: [4096]u8 = undefined; var w = std.fs.File.stdout().writer(&buf); const stdout = &w.interface;`
- Functions take `*std.Io.Writer` not `anytype`
- Always call `flush()` after writing
- Never copy `.interface` — always use references (`&writer.interface`)

**Containers**: Unmanaged by default:
- `var list: std.ArrayList(T) = .{};` then `list.deinit(allocator);`
- `list.append(allocator, item)` — allocator passed to mutating methods
- `std.AutoHashMap` similarly takes allocator per-call

**Build system**: Use `b.createModule()` + `b.addExecutable(.{ .root_module = mod })` pattern.

**JSON**: Use `std.json.Stringify.valueAlloc(allocator, value, .{})` for serialization. Use `std.json.ArrayHashMap` for ordered JSON objects.

**General**: Error unions (`!`), allocator-passing pattern, `std.heap.ArenaAllocator` for request-scoped work, strings are `[]const u8`.

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
