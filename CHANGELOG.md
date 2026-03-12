# Changelog

All notable changes to hibrow will be documented in this file.

## [Unreleased] - 03/12/2026

### Added
- `src/process.zig` — macOS process enumeration via `proc_listpids` + `sysctl(KERN_PROCARGS2)` for discovering Chrome browsers from process args
- Process-based browser discovery: finds `--remote-debugging-port` and `--user-data-dir` directly from running Chrome process command lines
- E2E results display: test results now render in the browser with pass/fail counts, individual test list, and 10s auto-close countdown (click to close early)
- Persistent CDP connection cache in gateway Server (`ProfileConn` struct + `connections` HashMap)
- `getConnection()` method: returns cached CDP WebSocket or creates new one (skips port scan on cache hit)
- `evictConnection()` method: removes and closes a cached connection on error or browser kill
- `lookupPort()` in browser.zig: process-based port lookup by profile name

### Changed
- `discover()` now uses process scanning instead of 100-port TCP scan + registry lookup
- `lookupPort()` now uses process scanning instead of registry file read
- `launch()` no longer writes to profile registry — process args are the registry
- `handleBrowserLaunch` simplified to single discovery path via `findBrowserPort()`
- `getConnection()` simplified to single lookup via `lookupPort()` (no registry fallback)
- `handleBrowserEval` and `handleBrowserNavigate` now use cached connections instead of connect-per-request
- `handleBrowserKill` evicts cached connection after sending Browser.close
- `handleGatewayShutdown` closes all cached connections before shutting down
- `Server.deinit()` closes all cached connections on cleanup
- E2E cleanup no longer needs to clean profile registry entries

### Removed
- `ProfileRegistry` struct and all its methods (registry file no longer used)
- `ProfileEntry` struct
- `registerProfile()` function
- `getProfileRegistryPath()` function
- `connectToProfile()` method and `CdpResult` union type (replaced by `getConnection()` cache)

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
