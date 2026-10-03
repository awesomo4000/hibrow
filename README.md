<p align="center">
  <img src="img/hibrow.png" alt="hibrow" width="240">
</p>

<h1 align="center">hibrow</h1>

<p align="center"><b>Give any agent — or any shell script — a quick way to do browser stuff.</b></p>

---

hibrow is a tiny command-line tool that drives a **real** Chrome or Firefox from one-line commands. Every command takes simple arguments and prints **JSON to stdout**, which makes it an easy building block for LLM agents, automation scripts, or just you at a terminal.

```bash
hibrow launch work
hibrow nav work "https://news.ycombinator.com"
hibrow eval work "document.title"
# → "Hacker News"
```

An agent can launch a browser, navigate, run JavaScript, read the page back as structured data, take screenshots, and pull files — all without a headless framework, a language runtime, or any API keys.

## Why agents like it

- **One line in, JSON out.** No SDK, no session objects — just `hibrow <verb> <profile> ...` and parse the JSON. Trivial to call from any tool-use loop.
- **Real browser, real logins.** It uses your actual Chrome/Firefox profiles, so sessions have real cookies and SSO/MFA tokens. Log in once; script against authenticated pages after.
- **Persistent, named sessions.** Launch a browser once and reuse it across many commands and scripts. It stays open until you kill it.
- **Zero dependencies.** A single static binary that uses the browser you already have. No Node, no Python.
- **Fast.** A background gateway keeps the DevTools/Marionette connections warm, so repeated `eval` calls skip connection setup.

## Install

Requires [Zig 0.16.0](https://ziglang.org/download/) (exactly):

```bash
git clone https://github.com/awesomo4000/hibrow.git
cd hibrow
zig build -Doptimize=.ReleaseFast
cp ./zig-out/bin/hibrow ~/.local/bin/
```

> **macOS build note:** if linking fails with `undefined symbol: __availability_version_check`, your Command Line Tools default to a newer SDK the 0.16 linker can't read. Build with `DEVELOPER_DIR=/dev/null zig build`.

**Tests:** `zig build test` runs the unit suite. `./tests/e2e-features.sh` runs the
full command surface against real Chrome **and** Firefox (headless) using local
fixtures — pass `chrome` or `firefox` to run just one.

## Commands

The gateway daemon auto-starts on the first command — you don't manage it.

| Command | What it does |
|---|---|
| `hibrow launch <profile> [--browser chrome\|firefox]` | Launch a browser with a named, persistent profile |
| `hibrow ls [profile]` | List running sessions (or details for one) |
| `hibrow nav <profile[:tab]> <url>` | Navigate to a URL |
| `hibrow eval <profile[:tab]> "<js>" \| -f <file> \| -f- [--frame <path>]` | Run JavaScript, return the result as JSON |
| `hibrow click <profile[:tab]> <selector> [--frame <path>]` | Natively click an element (trusted click on Firefox) |
| `hibrow wait <profile[:tab]> <selector> [--frame <path>] [--timeout <s>] [--gone]` | Poll until a selector appears/disappears |
| `hibrow frame list <profile> [--tree]` | List nested frames (path, selector, title, url) |
| `hibrow url <profile[:tab]>` | Print the current URL |
| `hibrow screenshot <profile[:tab]> -o <file> [--frame <path>]` | Save a PNG screenshot (optionally of one frame) |
| `hibrow grab <profile> <url-or-js> -o <file>` | Download binary data through the browser to a file |
| `hibrow push <profile[:tab]> <target> <text> \| -f <file>` | Inject text into an input or `window.*` variable |
| `hibrow tab list\|new\|close\|switch <profile[:tab]>` | Manage tabs |
| `hibrow kill <profile>` | Close the browser (profile data is kept) |
| `hibrow gateway status\|stop` | Manage the background daemon |

`eval` is the workhorse. Provide code three ways — inline, `-f <file>`, or `-f-` (stdin) — and results come back as real JSON:

```bash
hibrow eval work "({url: location.href, links: document.querySelectorAll('a').length})"
# → {"url": "https://news.ycombinator.com/", "links": 142}

# Pipe code in, pipe output to jq
echo 'Array.from(document.querySelectorAll("a")).map(a => a.href)' \
  | hibrow eval work -f- | jq '.[]'
```

> `eval` runs synchronously and does not await promises. For async work, store the result on a `window.*` variable and poll it, then read it back — or use `grab`, which handles the fetch-and-chunk dance for you.

## How it works

```
  your agent / script        hibrow CLI            gateway daemon          browser
  -------------------       -----------           ---------------        ----------
   hibrow eval work ──────► Unix socket ─────────► CDP / Marionette ────► Chrome / Firefox
        "..."               (JSON-RPC 2.0)         (kept warm)
```

A background **gateway** owns the browser connections and auto-starts on first use (per-user socket at `/tmp/hibrow-{uid}/gateway.sock`). It finds browsers by scanning for `--remote-debugging-port` / Marionette processes — no port registry or config files. Chrome is driven over the DevTools Protocol; Firefox over Marionette.

## Requirements

- macOS (process discovery uses `proc_listpids` / `sysctl`)
- Chrome/Chromium and/or Firefox installed
- Zig 0.16.0 exactly (to build; the output binary is standalone)

## License

MIT
