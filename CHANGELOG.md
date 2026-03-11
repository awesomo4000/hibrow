# Changelog

All notable changes to hibrow will be documented in this file.

## [0.1.0] - 03/11/2026

### Added
- Initial project scaffolding with build.zig and build.zig.zon for Zig 0.15.2
- Module structure: root.zig (library API), main.zig (CLI), protocol.zig, gateway.zig, browser.zig, tab.zig, cdp.zig, websocket.zig
- CLI with command parsing and --help/--version flags
- Stub implementations for all commands: launch, ls, nav, eval, url, console, tab, gateway
- JSON-RPC 2.0 protocol types (Request, Response, Error) with standard error codes
- Gateway client/server stubs with socket path resolution
- Browser struct and launch options with chromium binary discovery (HIBROW_BROWSER env, platform-specific paths)
- Tab reference parsing (profile:N notation) and monotonic tab mapping (TabMap)
- CDP types (Target, Connection, EvalResult) and discovery stubs
- WebSocket client stubs with RFC 6455 frame types and XOR masking
- Library module ("hibrow") importable by the CLI and other Zig programs
- Unit tests for all modules (protocol, gateway, browser, tab, cdp, websocket)
- Moved bromux reference docs into x/ directory
