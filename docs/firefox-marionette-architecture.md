# Firefox Support via Marionette — Architecture

## Decision: Marionette over BiDi

We're using Firefox's **Marionette** protocol, not WebDriver BiDi. Reasons:

- Marionette is mature, stable, battle-tested (geckodriver has used it for years)
- BiDi has a session-reconnect bug (`/session/<id>` returns 404 on `--remote-debugging-port` path)
- BiDi orphans sessions on disconnect — requires Firefox restart. Marionette cleans up and re-accepts.
- Marionette is simpler: length-prefixed JSON over TCP. No WebSocket framing.
- BiDi is the future but Marionette works today with zero caveats

## How Marionette Works

### Wire Protocol

TCP connection. Firefox talks first (handshake), then request/response:

```
← 48:{"marionetteProtocol":3,"applicationType":"gecko"}     (handshake, unprompted)
→ 85:[0,1,"WebDriver:NewSession",{"capabilities":{}}]       (request)
← 234:[1,1,null,{"sessionId":"abc","capabilities":{...}}]    (response)
```

Format: `{length}:{json_array}`

- Request:  `[0, id, "CommandName", {params}]`   (type 0 = incoming)
- Response: `[1, id, null, {result}]`             (success)
- Response: `[1, id, {error}, null]`              (error)

IDs are u32, monotonically increasing.

### Connection Lifecycle

1. Launch Firefox with `--marionette` flag
2. Firefox writes Marionette port to `<profile>/MarionetteActivePort`
3. TCP connect to that port
4. Read handshake (Firefox sends it unprompted)
5. Send `WebDriver:NewSession` to create a session
6. Send commands, receive responses
7. On disconnect: Firefox cleans up the session, goes back to listening
8. Reconnect: just TCP connect again, read handshake, create new session
9. Browser state (tabs, pages, cookies) survives across reconnects

### Port Assignment

Marionette port is a Firefox pref set in `user.js` before launch:

```js
user_pref("marionette.port", 9800);
```

Hibrow always assigns the port explicitly from a dedicated range (9800–9900),
same pattern as Chrome CDP (9322–9422). We never rely on `MarionetteActivePort`
— that file is an external state dependency we don't want. The port is ours to
assign, discoverable by scanning the range, no files involved.

### Single Connection

Marionette accepts one TCP client at a time. Second connection is refused while
first is active. When the active connection drops, Firefox re-opens the listener.
(Geckodriver even sends `Marionette:AcceptConnections(false)` explicitly.)

This matches hibrow's gateway model perfectly — one connection per browser, gateway
serializes access from multiple CLI clients.

## Protocol Auto-Detection

Hibrow scans a port range and auto-detects whether a port is CDP or Marionette:

1. TCP connect
2. Wait ~200ms for data
3. **Data arrives?** → Marionette (Firefox sends handshake unprompted). Parse `{length}:{json}`, confirm `marionetteProtocol` field.
4. **Silence?** → CDP (Chrome waits for HTTP request). Send `GET /json/version`, confirm JSON response.

One port range, one scanner. No flag needed.

## Key Marionette Commands

These are the `WebDriver:*` commands that map to hibrow operations:

| hibrow operation | Marionette command | Params |
|---|---|---|
| Launch/connect | `WebDriver:NewSession` | `{"capabilities": {}}` |
| Navigate | `WebDriver:Navigate` | `{"url": "..."}` |
| Eval JS | `WebDriver:ExecuteScript` | `{"script": "...", "args": []}` |
| Screenshot | `WebDriver:TakeScreenshot` | `{"id": null, "highlights": [], "full": false}` |
| Full screenshot | `WebDriver:TakeScreenshot` | `{"id": null, "highlights": [], "full": true}` |
| List windows | `WebDriver:GetWindowHandles` | `{}` |
| Switch tab | `WebDriver:SwitchToWindow` | `{"handle": "..."}` |
| New tab | `WebDriver:NewWindow` | `{"type_hint": "tab"}` |
| Close tab | `WebDriver:CloseWindow` | `{}` |
| Get URL | `WebDriver:GetCurrentUrl` | `{}` |
| Get title | `WebDriver:GetTitle` | `{}` |
| Click element | `WebDriver:ElementClick` | `{"id": "element-ref"}` |
| Pixel click | `WebDriver:PerformActions` | `{actions: [{type: "pointer", ...}]}` |
| Switch frame | `WebDriver:SwitchToFrame` | `{"id": frame_index}` |
| Back to parent | `WebDriver:SwitchToParentFrame` | `{}` |
| End session | `WebDriver:DeleteSession` | (via `Marionette:Quit` with `eForceQuit`) |

## Firefox Launch

```
firefox --marionette --profile <dir> --no-remote
```

Required prefs in `<profile>/user.js` (before first launch):

```js
// Marionette port — deterministic, so gateway can find it
user_pref("marionette.port", 9800);

// Suppress UI noise
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.page", 0);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "about:blank");
user_pref("app.update.disabledForTesting", true);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.warnOnQuit", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("toolkit.startup.max_resumed_crashes", -1);

// Extension loading (for future hibrow-bridge extension)
user_pref("extensions.autoDisableScopes", 0);
user_pref("extensions.enabledScopes", 5);

// Privileged JS access via about:config (for proxy changes)
user_pref("browser.aboutConfig.showWarning", false);
user_pref("devtools.debugger.remote-enabled", true);
user_pref("devtools.debugger.prompt-connection", false);
```

See `x/geckodriver/src/prefs.rs` for the full set geckodriver uses (~50 prefs).
We only need the subset above for hibrow's use case.

## Firefox Binary Discovery

Search order (mirrors Chrome discovery pattern):

1. `HIBROW_FIREFOX` env var (explicit override)
2. Platform-specific search:
   - **macOS**: `/Applications/Firefox.app/Contents/MacOS/firefox`
   - **Linux**: `firefox` in PATH

## Process Discovery

Same pattern as Chrome — scan running processes for `--marionette` flag in args:

- macOS: `proc_listpids` + `sysctl(KERN_PROCARGS2)`, look for `--marionette` and `--profile`
- Extract the profile path → profile name (basename)
- Read `<profile>/MarionetteActivePort` for the port, OR parse `marionette.port` from `user.js`
- Better: scan for the port in process args isn't possible (it's a pref, not a flag)

Since we always assign ports from our range (9800–9900), discovery is just port
scanning with protocol auto-detection — same as Chrome. No file dependencies.

## Architecture in hibrow

```
CLI ──JSON-RPC──> Gateway ──CDP/WebSocket──> Chrome  (existing)
                    │
                    └──Marionette/TCP──> Firefox  (new)
```

The gateway holds one persistent connection per browser, regardless of type.
CLI commands are browser-agnostic — `hibrow nav work https://...` works whether
"work" is a Chrome or Firefox profile.

### What Changes

| Component | Change |
|---|---|
| `main.zig` | Add `--browser firefox\|chrome` to `launch` command (chrome is default) |
| `browser.zig` | Add `BrowserType` enum, `findFirefox()`, Firefox launch with `--marionette`, profile pref writing |
| `process.zig` | Add `findFirefoxBrowsers()` — scan for `--marionette` in process args |
| `marionette.zig` | **New file.** TCP client: connect, handshake, send/recv length-prefixed JSON |
| `gateway.zig` | Route to CDP or Marionette based on browser type. Unified dispatch. |
| `browser.zig` | `Browser` struct gets a `browser_type` field, `discover()` scans both |
| `browser.zig` | `verify()` uses protocol auto-detection (handshake vs silence) |

### What Doesn't Change

- CLI command surface (except `launch` gets `--browser`)
- JSON-RPC protocol between CLI and gateway
- Profile directory structure (`~/.hibrow/profiles/<name>`)
- Unix socket path and daemon lifecycle
- Tab indexing logic

## Implementation Phases

### Phase 1: Firefox Binary Discovery + Launch
- Add `BrowserType` enum (`chrome`, `firefox`) to `browser.zig`
- Add `findFirefox()` (parallel to `findChromium()`)
- Write `user.js` prefs into profile dir before launch
- Launch Firefox with `--marionette --profile <dir> --no-remote`
- Add `--browser` flag to CLI `launch` command
- **Test:** `hibrow launch myprofile --browser firefox` starts Firefox, visible on screen

### Phase 2: Marionette TCP Client
- New `marionette.zig`: TCP connect, read handshake, send/recv messages
- Length-prefix framing: read digits until `:`, read N bytes, parse JSON array
- Request/response with ID correlation
- **Test:** Unit tests for framing. Integration test: connect to running Firefox, send `session.status`, get response.

### Phase 3: Gateway Integration
- Gateway detects browser type when discovering/connecting
- Routes commands to CDP or Marionette based on type
- Marionette command translation (hibrow JSON-RPC → Marionette wire format)
- Start with: navigate, eval, get-url, get-title, screenshot
- **Test:** `hibrow nav myprofile https://example.com` works on Firefox profile.
  `hibrow eval myprofile "document.title"` returns title.

### Phase 4: Process Discovery
- Extend `process.zig` to also scan for `--marionette` in process args
- Or: port-range scanning with protocol auto-detection
- `hibrow ls` shows both Chrome and Firefox browsers
- **Test:** Launch Firefox manually with `--marionette`, `hibrow ls` finds it.

### Phase 5: Reconnection + Robustness
- Gateway handles Marionette TCP disconnect gracefully
- Reconnect: TCP connect, read handshake, new session, pick up existing tabs
- Test with the parallel test suite to verify serialization under load
- **Test:** Kill gateway, restart, Firefox operations resume. Disconnect/reconnect cycle.

### Phase 6: Tab Management
- Map Marionette window handles to hibrow's tab indexing
- `hibrow tab list/new/close/switch` for Firefox
- Frame switching (for iframe access)
- **Test:** `hibrow tab list myprofile` shows Firefox tabs.

### Phase 7: Proxy Control (stretch)
- Write proxy prefs to `user.js` at launch time (like Chrome's `--proxy-server`)
- Runtime proxy changes via Marionette `WebDriver:ExecuteScript` on `about:config`
- Or: pre-installed hibrow-bridge extension with `browser.proxy.onRequest`
- **Test:** `hibrow launch myprofile --browser firefox --proxy socks5://127.0.0.1:1080`

## Key Differences from Chrome Path

| | Chrome (CDP) | Firefox (Marionette) |
|---|---|---|
| Transport | WebSocket | TCP (length-prefixed JSON) |
| Handshake | None (HTTP server waits) | Firefox sends first |
| Session | None needed | `WebDriver:NewSession` required |
| Discovery | `GET /json` (HTTP) | Port scan + handshake auto-detect |
| Port config | `--remote-debugging-port=N` (CLI flag) | `marionette.port` (pref in `user.js`) |
| Reconnect | Just reconnect WS | TCP reconnect + new session (browser state preserved) |
| Multiple clients | Allowed (but broken) | Refused (single client enforced) |
| Profile prefs | N/A (Chrome uses flags) | Must write `user.js` before launch |

## Reference

- Geckodriver source: `x/geckodriver/` (pulled from mozilla-central `testing/geckodriver/`)
- Firefox BiDi research: `x/firefox-bidi-research.md` (read only)
- Firefox BiDi how-to: `firefox-bidi-how.md`
- Geckodriver default prefs: `x/geckodriver/src/prefs.rs`
- Marionette wire protocol: `x/geckodriver/marionette/src/message.rs`
- Marionette commands: `x/geckodriver/marionette/src/webdriver.rs`
