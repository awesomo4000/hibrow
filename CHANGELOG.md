# Changelog

All notable changes to hibrow will be documented in this file.

## [Unreleased] - 10/30/2026

### Changed
- `nav` now waits for the page to load before returning. On Chrome, after `Page.navigate` commits (the new document's context is already current), it awaits the document `load` event — which also covers subframes — with a 30s page-side safety bound so a stuck page cannot wedge the connection; Firefox already blocked on load via `WebDriver:Navigate`. Callers no longer need a fixed sleep after navigating: the feature e2e suite dropped its post-`nav` sleeps and now runs in ~12s (was ~28s)
- `wait` is now event-driven instead of polling. The browser evaluates a Promise backed by a `MutationObserver` that resolves the instant the selector reaches the desired presence (with a page-side timeout fallback), consumed via CDP `awaitPromise` on Chrome and `WebDriver:ExecuteAsyncScript` on Firefox. The gateway blocks on a single round trip rather than re-evaluating every 200ms, so `wait` returns the moment the DOM changes and right at the deadline on a genuine timeout

### Added
- `launch --allow-autoplay` lets media play without a user gesture. On Chrome this passes `--autoplay-policy=no-user-gesture-required`, so `media play`, a scripted `element.play()`, and page `autoplay` actually start instead of staying paused under automation; it works headless or not, and is a no-op on Firefox (which already permits muted autoplay). Off by default, so an ordinary launched session never starts media on its own. The feature e2e suite launches with this flag and proves real playback — autoplay running, `currentTime` advancing while playing, and `wait-ended` firing after a seek to the end — against a multi-second in-page tone
- Profile→(port, browser_type) resolution cache in the gateway, so warm commands skip the per-command process scan that dominated latency; a cheap TCP liveness probe validates a cached entry before use, and a dead or failed entry is evicted so a browser restart self-heals without a visible error. Warm command latency drops from ~100ms to ~15ms
- `TCP_NODELAY` on gateway and browser sockets (`os.setTcpNoDelay`) to avoid Nagle/delayed-ACK stalls on the localhost request/response path
- Cross-platform support: hibrow now runs on macOS, Linux, and Windows with an identical command surface. OS-specific code is contained behind `src/os.zig` (small shims) and `src/os_windows.zig` (Win32), so the rest of the codebase stays platform-neutral
- Firefox support over the Marionette protocol, alongside Chrome over CDP; `launch --browser chrome|firefox`
- Linux browser discovery via `/proc/<pid>/cmdline`, and executable lookup on `PATH`
- Windows browser discovery via the process PEB command line (toolhelp snapshot), and executable lookup via the App Paths registry
- `os.homeDir` resolves the user home from `USERPROFILE` (with a `HOME` fallback) on Windows and `HOME` elsewhere
- `tests/e2e-features.sh` runs the full dual-browser feature suite on all three platforms (Windows under Git Bash), driven uniformly by `mise run e2e`

### Changed
- Build and language updated to Zig 0.17.0 (`minimum_zig_version = "0.17.0"`)
- Gateway socket I/O routed through `os.sockRead` / `os.sockWriteAll` so the transport is shared across platforms
- Browser process discovery and the home-directory lookup moved behind the `os` shims

### Fixed
- WebSocket `readFrame` double-free when the peer closes the connection mid-read

### Added (earlier, macOS)
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
