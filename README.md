# hibrow

A headless browser multiplexer. Launch, control, and script Chrome instances from the command line.

hibrow manages named browser sessions through a local gateway daemon. Each session gets a profile name. You launch browsers, navigate to pages, evaluate JavaScript, and extract data — all from shell commands or scripts. The gateway keeps persistent CDP (Chrome DevTools Protocol) connections so commands are fast.

```
hibrow launch work
hibrow nav work "https://example.com/dashboard"
hibrow eval work "document.querySelector('.balance').textContent"
# → "$4,821.33"
```

## Why

Browser automation tools are either too heavy (Playwright, Puppeteer — require Node, install their own browsers, want to own the whole lifecycle) or too low-level (raw CDP over websockets). hibrow sits in between:

- **Named sessions that persist.** Launch a browser once, use it across multiple scripts and shell sessions. The browser stays open until you kill it.
- **Zero dependencies.** Single static binary. Uses your existing Chrome installation. No Node, no Python, no runtime.
- **Scriptable.** Every command reads from stdin and writes JSON to stdout. Pipe `eval` output into `jq`. Chain commands in bash. Use it as a building block.
- **Fast.** Written in Zig. The gateway daemon keeps CDP WebSocket connections cached — eval calls don't pay connection setup on every invocation.
- **Auth-aware.** Because hibrow uses real Chrome with real profiles, your sessions have real cookies, real Duo/SSO tokens, real everything. Log in once in the browser, then script against authenticated pages.

## Install

Requires [Zig 0.16.0](https://ziglang.org/download/) (exactly):

```bash
git clone https://github.com/you/hibrow.git
cd hibrow
zig build -Doptimize=.ReleaseFast
# Binary: ./zig-out/bin/hibrow
```

Copy to your PATH:

```bash
cp ./zig-out/bin/hibrow ~/.local/bin/
```

## Quick start

```bash
# Launch a browser with the profile name "dev"
hibrow launch dev

# Navigate to a page
hibrow nav dev "https://news.ycombinator.com"

# Extract data
hibrow eval dev "document.title"
# → "Hacker News"

# Run complex JS
hibrow eval dev "Array.from(document.querySelectorAll('.titleline a')).slice(0,5).map(a => a.textContent)"
# → ["Show HN: ...", "Ask HN: ...", ...]

# Run JS from a file
hibrow eval dev -f scrape.js

# Pipe JS from stdin
echo 'document.querySelectorAll("a").length' | hibrow eval dev -f-
# → 142

# Check current URL
hibrow url dev
# → "https://news.ycombinator.com"

# Close the browser
hibrow kill dev
```

## Commands

### `hibrow launch <profile> [--proxy <url>] [--proxy-dns]`

Launch a new Chrome instance with the given profile name. Each profile gets its own user data directory (`~/.hibrow/profiles/<profile>`), so cookies, localStorage, and login sessions are isolated and persistent across launches.

```bash
hibrow launch work
hibrow launch personal
hibrow launch scraper --proxy socks5://localhost:9050
```

### `hibrow ls [profile]`

List all running browser sessions, or get details for a specific one.

```bash
hibrow ls
# [{"profile": "work", "port": 9322, "pid": 41023, "managed": true}, ...]

hibrow ls work
# {"profile": "work", "port": 9322, "pid": 41023, ...}
```

### `hibrow nav <profile> <url>`

Navigate a browser tab to a URL.

```bash
hibrow nav work "https://github.com"
```

### `hibrow eval <profile> "<js>" | -f <file> | -f-`

Evaluate JavaScript in the page context and return the result as JSON.

Three ways to provide code:
- **Inline:** `hibrow eval work "1 + 1"` 
- **File:** `hibrow eval work -f script.js`
- **Stdin:** `cat script.js | hibrow eval work -f-`

Results are serialized via CDP's `returnByValue`, so you get real JSON — strings, numbers, arrays, objects — not stringified representations.

```bash
# Simple expression
hibrow eval work "window.location.hostname"
# → "github.com"

# Return an object
hibrow eval work "({url: location.href, title: document.title})"
# → {"url": "https://github.com", "title": "GitHub"}

# Trigger a fetch and store results (eval doesn't await promises)
hibrow eval work '
  fetch("/api/data").then(r => r.json()).then(d => { window.__result = d; });
  "started"
'
sleep 2
hibrow eval work "window.__result"
```

### `hibrow url <profile>`

Print the current URL of the active tab.

```bash
hibrow url work
# → https://github.com/notifications
```

### `hibrow kill <profile>`

Gracefully close a browser via CDP's `Browser.close`. The profile data on disk is preserved — next `launch` will restore cookies and sessions.

```bash
hibrow kill work
```

### `hibrow tab list|new|close|switch <profile>`

Manage tabs within a browser.

```bash
hibrow tab list work
hibrow tab new work
hibrow tab switch work:2
hibrow tab close work:3
```

### `hibrow gateway status|stop|serve`

Manage the gateway daemon. Normally you don't need these — the gateway auto-starts on first command and runs in the background.

```bash
hibrow gateway status    # check if running
hibrow gateway stop      # shut it down
```

## Architecture

```
  your script          hibrow CLI           gateway daemon         Chrome
  ----------          ----------           ---------------        --------
                     $ hibrow eval ──────► Unix socket ──────────► CDP/WebSocket
                       work "..."          /tmp/hibrow-{uid}/       :9222
                                           gateway.sock
                     (JSON-RPC 2.0)                              (DevTools Protocol)
```

**Gateway daemon** — A background process that owns all CDP WebSocket connections. It auto-starts on the first `hibrow` command and listens on a per-user Unix domain socket at `/tmp/hibrow-{uid}/gateway.sock`. The gateway caches CDP connections per profile, so repeated `eval` calls skip the WebSocket handshake.

**Browser discovery** — hibrow finds running Chrome instances by scanning macOS process tables for `--remote-debugging-port` and `--user-data-dir` flags. No port registry, no config files — if Chrome is running with a debug port, hibrow can find it.

**Wire protocol** — CLI ↔ gateway communication uses line-delimited JSON-RPC 2.0 over Unix domain sockets. Gateway ↔ Chrome uses standard CDP over WebSockets. Both layers use allocator-backed dynamic buffers, no fixed-size limits on message payloads.

## Scripting patterns

### Authenticated scraping

Log into a site once in the browser, then script it forever:

```bash
hibrow launch mybank
hibrow nav mybank "https://mybank.com/login"
# → Complete login manually (MFA, captcha, whatever)

# Now script against the authenticated session
hibrow eval mybank "document.querySelector('.account-balance').textContent"
```

### Store-and-poll for async operations

`hibrow eval` executes synchronously — it doesn't await promises. For async work, store results in a window variable and poll:

```bash
# Kick off the async work
hibrow eval work '
  window.__status = "pending";
  fetch("/api/export").then(r => r.blob()).then(b => {
    var reader = new FileReader();
    reader.onload = function() { window.__data = reader.result; window.__status = "done"; };
    reader.readAsDataURL(b);
  });
  "started"
'

# Poll until done
while [ "$(hibrow eval work 'window.__status')" != "done" ]; do
  sleep 1
done

# Extract the result
hibrow eval work "window.__data"
```

### Extracting large data in chunks

For data larger than a few KB, chunk it in the browser and pull piece by piece:

```bash
# Pre-chunk in the browser
hibrow eval work '
  var raw = window.__bigString;
  var chunks = [];
  for (var i = 0; i < raw.length; i += 20000) {
    chunks.push(raw.substring(i, i + 20000));
  }
  window.__chunks = chunks;
  chunks.length
'
# → 15

# Pull each chunk
for i in $(seq 0 14); do
  hibrow eval work "window.__chunks[$i]" >> output.txt
done
```

### Using with jq

All output is JSON, so `jq` works naturally:

```bash
# Extract just the URLs from a page
hibrow eval work "Array.from(document.querySelectorAll('a')).map(a => a.href)" | jq '.[]'

# Get structured page data
hibrow eval work "({
  title: document.title,
  links: document.querySelectorAll('a').length,
  images: document.querySelectorAll('img').length
})" | jq '.links'
```

## Building from source

```bash
zig build                    # debug build
zig build -Doptimize=.ReleaseFast  # optimized build
zig build test               # run all unit tests
```

The binary is at `./zig-out/bin/hibrow`. No external dependencies — Zig's standard library provides HTTP, WebSocket, JSON, and Unix socket support.

### macOS SDK note

If `zig build` fails to link with `undefined symbol: __availability_version_check`
(and every libc symbol undefined), your Command Line Tools default to a newer
macOS SDK (26.x/27.x) whose `.tbd` files Zig 0.16.0's linker can't parse. Build
with SDK detection disabled so Zig uses its bundled libSystem stub:

```bash
DEVELOPER_DIR=/dev/null zig build
```

Alternatively, point at an older installed SDK, e.g.
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk` (may require
clearing `~/.cache/zig` since native libc detection is cached).

## Environment variables

| Variable | Description |
|----------|-------------|
| `HIBROW_BROWSER` | Path to Chrome/Chromium binary (auto-detected if not set) |

## Requirements

- macOS (process discovery uses `proc_listpids` / `sysctl`)
- Chrome or Chromium installed
- Zig 0.16.0 exactly (build only — the output binary is standalone)

## License

MIT
