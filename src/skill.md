---
name: hibrow
description: Drive a real Chrome or Firefox from the command line to do browser tasks — navigate, read/scrape pages, fill forms, trusted-click, log in, screenshot, and download. Use this whenever you need to interact with a website, inspect a live page, automate a web UI, test a web app, extract data from a page that needs a real browser (JS-rendered, auth-gated, or behind a login), or capture a site's network traffic. Reach for it especially when you are blocked by a cross-origin iframe (SecurityError on contentWindow), content inside a shadow root (missing from innerText / unreachable by querySelector), a click or video that only responds to a real trusted gesture, or a SCORM/LMS/e-learning course — or whenever the user mentions hibrow.
---

# hibrow

`hibrow` controls a persistent, real browser from one-line shell commands. Every
command prints **JSON to stdout**, so you read results by parsing that JSON.

Mental model: it is like `tmux` for browsers. You `launch` a named session once,
then `nav`/`eval`/etc. against it as many times as you want. The browser stays
open across commands until you `kill` it. A background gateway auto-starts on the
first command — you never manage it.

## Golden rules

1. **Target by profile name.** Almost every command takes a profile:
   `hibrow <verb> <profile> ...`. Use `<profile>:<tab>` to target a tab,
   e.g. `work:2`.
2. **`eval` returns real JSON**, serialized by value. A string comes back quoted
   (`"Hacker News"`); objects/arrays come back as JSON. Pipe to `jq`.
3. **`eval --await` settles a promise in one command; plain `eval` does not.**
   Add `--await` to wait for a returned promise/thenable and print its resolved
   value (see "Awaiting async work"). Without it, `eval` is synchronous and a
   promise comes back unsettled.
4. **Don't `eval` huge strings.** For anything bigger than a few KB of binary or
   text, use `grab` (handles fetch + chunking for you).
5. **Prefer running JS from a file** (`-f file.js`) over cramming complex JS into
   one shell-quoted line. The multi-line snippets below are meant to be saved to
   a `.js` file and run with `hibrow eval <profile> -f file.js` (or piped via
   `-f-`). This avoids quoting hell and makes them reusable.
6. **Build a reusable toolkit — don't rawdog fresh JS every time.** When you work
   a site, save the selectors and snippets that worked (login, extract-X,
   enumerate controls, instrument) into `.hibrow-scripts/<site>/` and re-run them
   with `-f`, instead of re-deriving brittle selectors each session. Ask the user
   before creating the directory. Treat it as a growing library the next run (or
   the next agent) inherits. See "Project convention: `.hibrow-scripts/`".

## Core commands

```bash
hibrow launch <profile> [--browser chrome|firefox] [--headless] [--allow-autoplay] [--proxy <url>]
hibrow ls [profile]                                  # list sessions / details (JSON)
hibrow nav <profile[:tab]> <url>                     # navigate
hibrow url <profile[:tab]>                            # print current URL
hibrow eval <profile[:tab]> "<js>" | -f <file> | -f- # run JS, return JSON
hibrow push <profile[:tab]> <target> <text> | -f <f> # set an input value / window var
hibrow console <profile[:tab]>                        # stream console output from the tab
hibrow screenshot <profile[:tab]> -o <file.png>      # save a PNG
hibrow grab <profile> <url-or-js> -o <file>          # download binary/large data
hibrow tab list|new|close|switch <profile[:tab]>     # manage tabs
hibrow kill <profile>                                # close browser (profile kept)
hibrow gateway status|stop                           # background daemon (rarely needed)
```

Profiles are persistent (`~/.hibrow/profiles/<profile>`): cookies, logins, and
localStorage survive `kill` + relaunch. **Log in once, script forever.**

## Reading a page

```bash
hibrow launch work
hibrow nav work "https://news.ycombinator.com"
hibrow eval work "document.title"
# → "Hacker News"
hibrow eval work "Array.from(document.querySelectorAll('.titleline > a')).slice(0,5).map(a=>a.textContent)"
# → ["...","...",...]
```

Read structured data in one shot and parse with jq:

```bash
hibrow eval work "({url: location.href, links: document.querySelectorAll('a').length})" | jq .
```

**Table → JSON** (`extract-table.js`, run with `-f`):

```js
(function () {
  var t = document.querySelector("table");
  var headers = Array.from(t.querySelectorAll("thead th, tr:first-child th, tr:first-child td"))
    .map(function (h) { return h.innerText.trim(); });
  return Array.from(t.querySelectorAll("tbody tr, tr")).slice(headers.length ? 0 : 1)
    .map(function (row) {
      var cells = Array.from(row.children).map(function (c) { return c.innerText.trim(); });
      if (!cells.length) return null;
      var o = {}; cells.forEach(function (v, i) { o[headers[i] || ("col" + i)] = v; });
      return o;
    }).filter(Boolean);
})()
```

```bash
hibrow eval work -f extract-table.js | jq .
```

## Waiting

**Wait for a selector** before acting (better than a blind `sleep` — SPAs render
late). A small shell helper:

```bash
wait_for() {  # wait_for <profile> <css-selector> [max_tries]
  for i in $(seq 1 "${3:-60}"); do
    [ "$(hibrow eval "$1" "!!document.querySelector('$2')")" = "true" ] && return 0
    sleep 0.5
  done
  return 1
}
wait_for work "#results" && hibrow eval work "document.querySelector('#results').innerText"
```

**Wait for the USER to log in** (very common — we do NOT store credentials).
This needs a **visible** browser so the human can type, so launch WITHOUT
`--headless`. Navigate to the login page, ask the user to sign in (including any
MFA), and poll for a logged-in signal:

```bash
hibrow launch work                      # visible window so the user can log in
hibrow nav work "https://app.example.com/login"
echo "Please log in (and complete any MFA) in the browser window. I'll continue automatically."

# Poll until a logged-in signal appears (pick one that's true only after login):
until [ "$(hibrow eval work 'location.pathname !== "/login" || !!document.querySelector("[data-testid=\"user-menu\"]")')" = "true" ]; do
  sleep 2
done
echo "Logged in — continuing."
```

Tip: choose a signal that is reliably present only when authenticated — a
redirect away from `/login`, an avatar/user-menu element, or an auth cookie
(`document.cookie.includes("session")`). After this, the session persists, so
future runs against the same profile are already logged in.

## Awaiting async work

**Preferred: `eval --await`.** Add `--await` and `eval` waits for a returned
promise or thenable to settle, then prints its resolved value — one command, no
page globals, no polling. Return the promise as the last expression (an async IIFE
is the idiom):

```bash
hibrow eval work --await 'fetch("/api/data").then(r => r.json())' | jq .

hibrow eval work --await '
(async () => {
  const r = await fetch("/api/data");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return await r.json();
})()
'
```

- A plain (non-promise) value returns immediately, so `--await` is safe to leave on.
- `--timeout <secs>` bounds the wait (default 30s). On timeout the command exits
  nonzero with `{"error":{"type":"timeout",...}}` on stderr and the session stays
  usable — the page's own JS/network keep running, the timeout just stops waiting.
- A rejected promise or a thrown error exits nonzero with a structured diagnostic
  on stderr (`type` is `javascript`, `timeout`, or `context-loss`); stdout stays
  clean, so a success result always pipes straight into `jq`. Non-`Error`
  rejections (`Promise.reject("nope")`) keep their value.
- Composes with `-f`, `-f-`, `<profile>:<tab>`, and `--frame`. Top-level `await` is
  not supported — wrap in an async IIFE as above.

**Fallback: store-and-poll.** For fire-and-forget work, or several overlapping
async operations you want to start and check independently, stash results on
`window` and poll:

```bash
hibrow eval work '
  window.__done = false;
  fetch("/api/data").then(r=>r.json()).then(d=>{ window.__data=d; window.__done=true; });
  "started"
'
until [ "$(hibrow eval work 'window.__done')" = "true" ]; do sleep 0.5; done
hibrow eval work "window.__data" | jq .
```

## Finding and clicking things

Enumerate interactive elements with stable selectors before acting
(`enumerate.js`, run with `-f`):

```js
Array.from(document.querySelectorAll("a,button,[role=button],input,select,textarea,[onclick]"))
  .map(function (e, i) {
    return {
      i: i, tag: e.tagName.toLowerCase(),
      text: (e.innerText || e.value || e.placeholder || "").trim().slice(0, 50),
      sel: e.id ? "#" + e.id : (e.name ? "[name=\"" + e.name + "\"]" : null),
      aria: e.getAttribute("aria-label") || null
    };
  })
  .filter(function (o) { return o.text || o.sel; })
```

Then click it. Prefer the first-class `click` command over a JS `.click()` — it
scrolls into view and performs a **real trusted click** (`isTrusted` true, via
Firefox `ElementClick` / Chrome `Input.dispatchMouseEvent`), which works where a
JS `.click()` or `video.play()` is blocked, e.g. media play buttons. Selectors
may pierce open shadow roots with `>>>` (see Shadow DOM):

```bash
hibrow click work "#submit"
hibrow click work "#play" --frame 0/0      # click inside a nested frame
```

(Plain `hibrow eval work 'document.querySelector("#submit").click()'` still works
for simple cases.)

**Wait** for an element instead of guessing with `sleep` (SPAs render late and
keep stale controls around):

```bash
hibrow wait work "#results"                    # until it appears (default 10s)
hibrow wait work "#spinner" --gone --timeout 20   # until it disappears
hibrow wait work "#lesson-body" --frame 0/0    # inside a frame
```

## Filling inputs (and the React gotcha)

Setting `input.value = "x"` directly often does **not** register in React/Vue/
Angular apps — the framework tracks its own state and ignores the raw assignment,
so your text looks typed but submits as empty. Set the value through the native
setter and dispatch events (`fill.js`, run with `-f`):

```js
(function () {
  function setValue(el, value) {
    var proto = el.tagName === "TEXTAREA"
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, value);                                 // native setter
    el.dispatchEvent(new Event("input",  { bubbles: true })); // React onChange
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  setValue(document.querySelector("#email"), "me@example.com");
  setValue(document.querySelector("#password"), "hunter2");
  return "filled";
})()
```

`hibrow push <profile> <css-selector> <text>` is a shortcut for simple inputs,
but for React forms prefer the native-setter snippet above.

## Pagination and infinite scroll

**Click "next" and collect across pages:**

```bash
all="[]"
while :; do
  page=$(hibrow eval work -f extract-table.js)
  all=$(jq -s 'add' <(printf '%s' "$all") <(printf '%s' "$page"))
  more=$(hibrow eval work 'var b=document.querySelector(".pagination .next:not([disabled])"); if(b){b.click();"yes"}else"no"')
  [ "$more" = '"yes"' ] || break
  sleep 1
done
printf '%s' "$all" | jq 'length'
```

**Infinite scroll** — scroll until the page stops growing:

```bash
prev=0
while :; do
  h=$(hibrow eval work 'window.scrollTo(0, document.body.scrollHeight); document.body.scrollHeight')
  [ "$h" = "$prev" ] && break
  prev=$h; sleep 1.5
done
```

## Capturing network traffic (all fetch + XHR)

**Simplest — capture one triggered request in a single `eval`.** When you know
which action fires the request (a click, etc.), do install + trigger + read in
ONE eval. The fetch wrapper records the URL *synchronously* before the request
even starts, so it is already there when you read it — no ordering or timing to
get wrong:

```bash
hibrow eval work '(function(){
  var seen=[]; var of=window.fetch;
  window.fetch=function(u){ seen.push(typeof u==="string"?u:u.url); return of.apply(this,arguments); };
  document.querySelector("#the-trigger").click();  // the element that fires the request
  return seen[0] || null;                          // eval returns the captured URL
})()'
```

Do it this way unless you need to capture many requests, responses, or XHR too —
then use the fuller recipe below.

**Full capture (all fetch + XHR, with responses).** Install, do the action, then
read `window.__net` (`capture-net.js`, `-f`):

```js
(function () {
  if (window.__net) return "already capturing";
  window.__net = [];
  var LIM = 20000; // cap stored body size

  var of = window.fetch;
  window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : input.url;
    var rec = { t: Date.now(), kind: "fetch", method: (init && init.method) || "GET", url: url, status: null };
    window.__net.push(rec);
    return of.apply(this, arguments).then(function (res) {
      rec.status = res.status;
      res.clone().text().then(function (b) { rec.body = b.slice(0, LIM); }).catch(function () {});
      return res;
    });
  };

  var XP = window.XMLHttpRequest.prototype, oopen = XP.open, osend = XP.send;
  XP.open = function (m, u) { this.__rec = { t: Date.now(), kind: "xhr", method: m, url: u, status: null }; window.__net.push(this.__rec); return oopen.apply(this, arguments); };
  XP.send = function (body) {
    var self = this;
    if (body) self.__rec.reqBody = String(body).slice(0, LIM);
    this.addEventListener("load", function () { self.__rec.status = self.status; self.__rec.body = (self.responseText || "").slice(0, LIM); });
    return osend.apply(this, arguments);
  };
  return "capturing network";
})()
```

```bash
hibrow eval work -f capture-net.js       # install BEFORE the action
# ...click/navigate/trigger the thing...
hibrow eval work "window.__net" | jq '.[] | {method, url, status}'
```

**Timing gotcha:** hibrow injects AFTER the page has loaded, so any requests the
app fired during initial load are already gone. Install capture, then **re-trigger
the action** (click, in-app navigation, refresh the data) so it flows through your
wrapped `fetch`/`XHR`. For truly first-paint requests, capture then
`hibrow nav` the SPA route again (client-side) rather than a full reload.

## Console output

`hibrow console <profile[:tab]>` streams the tab's console (`console.log`/`warn`/
`error`) and uncaught page errors as they happen — the quickest way to see what a
page is logging without wrapping anything yourself. It runs until interrupted, so
read it with a timeout or in the background when you only want a window of output:

```bash
hibrow console work                    # stream live (Ctrl-C to stop)

# Capture a few seconds around an action:
hibrow console work > console.log &    # start streaming in the background
hibrow click work "#submit"            # do the thing that logs
sleep 2; kill %1                       # stop; inspect console.log
```

Use `console` to watch what the page already logs; use the `fetch`/`XHR` capture
snippets above when you need the request/response bodies, not just log lines.

## Instrumenting React (gotchas)

React makes page instrumentation tricky. Key gotchas:

- **React replaces DOM nodes on re-render**, so listeners bound to a specific
  element vanish. Use **event delegation on `document` with capture = true**:
  `document.addEventListener("click", handler, true);`
- **Synthetic events:** React listens via one delegated listener at the root, so
  events you dispatch must have `{ bubbles: true }` (same reason the form-fill
  snippet dispatches bubbling `input`/`change`).
- **Read props/state off a DOM node** via the fiber keys React attaches (the
  suffix is a hash in prod):
  ```js
  var el = document.querySelector("#thing");
  var pk = Object.keys(el).find(k => k.startsWith("__reactProps$"));
  var fk = Object.keys(el).find(k => k.startsWith("__reactFiber$"));
  ({ props: pk && el[pk], hasFiber: !!fk })
  ```
- **MutationObserver is extremely noisy** in React apps (constant re-renders).
  Scope it to a specific subtree and the attributes/childList you care about, and
  debounce, or you will drown in events.
- **Instrument before the app uses the API**, not after — see the timing gotcha
  above. Wrapping `fetch`/`XHR` only catches calls made *after* injection.

## General instrumentation

Watch clicks + DOM changes into a log (`watch.js`, `-f`):

```js
(function () {
  window.__log = [];
  document.addEventListener("click", function (e) {
    var t = e.target.closest("a,button,[role=button]");
    if (t) window.__log.push(["click", t.tagName, (t.innerText || "").trim().slice(0, 40)]);
  }, true);
  new MutationObserver(function (m) { window.__log.push(["dom", m.length]); })
    .observe(document.body, { childList: true, subtree: true });
  return "watching";
})()
```

Watch reads/writes of a specific global with a `Proxy`:

```js
window.__access = [];
window.appState = new Proxy(window.appState || {}, {
  get: function (t, k) { window.__access.push(["get", k]); return t[k]; },
  set: function (t, k, v) { window.__access.push(["set", k]); t[k] = v; return true; }
});
"watching appState"
```

## Large / binary data: use `grab`

For downloads, images, exports, or any large payload, do NOT eval the bytes —
`grab` fetches in the page and chunks it back to a file safely:

```bash
hibrow grab work "https://example.com/report.pdf" -o report.pdf
hibrow grab work "window.__someBigBase64" -o out.bin   # JS mode: expr returns base64/data-URI
```

**`grab` fetches inside the current page**, so a cross-origin URL hits CORS.
Fix: `hibrow nav work <same-origin-page>` first, then grab the same-origin URL.

## Cookies and storage

```bash
hibrow eval work "document.cookie"
hibrow eval work "Object.fromEntries(Object.entries(localStorage))" | jq .
hibrow eval work "Object.fromEntries(Object.entries(sessionStorage))" | jq .
```

## Dialogs (alert / confirm / prompt)

Native dialogs block the page and freeze `eval`. Neutralize them **before**
triggering the action that would pop them:

```bash
hibrow eval work 'window.alert=function(){}; window.confirm=function(){return true}; window.prompt=function(){return ""}; "dialogs neutralized"'
```

## Project convention: `.hibrow-scripts/`

When working inside a project/repo, ask the user if you can create a
`.hibrow-scripts/` directory to stash reusable JS for the site(s) you are
automating. Organize by site and run with `-f`:

```
.hibrow-scripts/
  acme/
    login.js          # waits for / verifies login
    list-orders.js    # returns orders as JSON
    enumerate.js      # dumps clickable elements
    capture-net.js    # installs network capture
```

```bash
hibrow eval work -f .hibrow-scripts/acme/list-orders.js | jq .
```

This turns flaky one-off selectors into a maintained, re-runnable toolkit, and
lets the next agent pick up where you left off.

## Frames / iframes

Content inside an `<iframe>` — especially a cross-origin one — is NOT reachable
from a normal `eval` on the top page. Target the frame explicitly.

List the frames (both browsers). Each entry has a `path` (for `--frame`), a
`selector` hint, `title`, `url`, `name`, and `parent`. Use `--tree` for a view:

```bash
hibrow frame list work
# [{"path":"0","parent":"","url":"...","name":"fa","selector":"#fa","title":"a"}, ...]

hibrow frame list work --tree
#   [0] #fa  "a"  file:///.../a.html
#     [0/0] #fg  "g"  file:///.../g.html
#   [1] #fb  "b"  file:///.../b.html
```

Then target a frame with `--frame <path>`. A path is frame indices and/or CSS
selectors of the `<iframe>` element, nested, separated by `/` or `,`. Numeric
indices follow **DOM order** — the order `frame list` shows. On pages that inject
frames (ad/analytics/WalkMe widgets) the DOM order is the safe reference;
**selector paths are the most robust** (`#player/#lesson-frame`). The same
`--frame` works on `eval`, `click`, `wait`, and `screenshot`:

```bash
hibrow eval work --frame 0 "document.body.innerText"      # first child frame
hibrow eval work --frame 0/0 "document.title"             # nested: frame 0, its child 0
hibrow eval work --frame 1,0,0 "..."                      # commas work too
hibrow eval work --frame "#content" "..."                 # by iframe selector (from frame list)
hibrow eval work --frame "#outer/#inner" "..."            # nested selectors
hibrow click work "#play" --frame 0/0                     # click inside a frame
hibrow wait  work "#lesson" --frame 0/0                   # wait inside a frame
hibrow screenshot work -o lesson.png --frame 0/0          # screenshot just the frame
```

Works on Chrome (CDP execution contexts) and Firefox (Marionette SwitchToFrame),
preserving the session (cookies/login). On Chrome the frame eval runs in an
isolated world: full DOM access (read text, click, fill) but not the frame
page's own JS globals. Chrome supports **one level** of cross-origin
out-of-process (OOPIF) frame; for **deeply nested cross-origin** frames
(cross-origin inside cross-origin), use `--browser firefox`, which handles
arbitrary nesting. If a `--frame` op returns null/empty, the frame may still be
loading — `wait`, or `frame list` to confirm the path.

## Shadow DOM (open roots)

Content inside an **open shadow root** (e.g. Articulate Rise / Mondrian blocks)
is NOT in `document.body.innerText` and NOT reachable by a normal
`querySelector`. Read all text, descending into nested open shadow roots (and
frame-aware):

```bash
hibrow text work                     # whole body, piercing open shadow roots
hibrow text work "#lesson-root"      # from a sub-tree
hibrow text work --frame 0/0         # inside a frame
```

To **click** an element inside a shadow root, use `>>>` in the selector — each
segment after `>>>` is found inside the previous element's shadow root. This is
a trusted click on both browsers and works at any nesting depth, inside frames:

```bash
hibrow click work "#host >>> .continue-btn"          # one level
hibrow click work "#outer >>> #inner-host >>> .btn"  # nested shadow roots
hibrow click work "#host >>> .play" --frame 0/0      # shadow inside a frame
```

To read/eval inside a shadow root, use a piercing query:

```bash
hibrow eval work '(function(){function q(sel,root){root=root||document;var e=root.querySelector(sel);if(e)return e;var all=root.querySelectorAll("*");for(var i=0;i<all.length;i++){if(all[i].shadowRoot){var r=q(sel,all[i].shadowRoot);if(r)return r;}}return null;}return q(".score")?.textContent;})()'
```

Note: closed shadow roots are inaccessible by design.

## Media (video / audio)

Inspect and control `<video>`/`<audio>` elements. All subcommands are
frame-aware — add `--frame <path>` to target media inside a frame:

```bash
hibrow media list work
# [{"i":0,"tag":"video","src":"...","duration":212.5,"currentTime":0,
#   "paused":true,"ended":false,"muted":false,"readyState":4,
#   "captions":[{"kind":"captions","label":"English","language":"en","mode":"disabled"}]}]

hibrow media mute work --persist      # mute all; --persist keeps SPA-created players muted
hibrow media unmute work
hibrow media play work "#player"      # best-effort (see note)
hibrow media pause work "#player"
hibrow media wait-ended work "#player" --timeout 600   # poll until the media ends
```

Notes:
- **Autoplay policy** blocks programmatic `play()` for unmuted media without a
  user gesture (the "`video.play()` did nothing" case). Two fixes: launch the
  profile with **`--allow-autoplay`** so `media play` / `element.play()` / page
  `autoplay` start without a gesture (Chrome; no-op on Firefox), or, for a single
  gated player in an ordinary session, **`hibrow click`** the play button (a
  trusted click) instead — then use the media commands to inspect/await it.
- `media list` reports each element's **caption tracks** — handy for summarizing
  training videos.
- After a carousel/tab switch, re-run `media list` to get the resulting state
  (hidden players may pause).

## Tabs

```bash
hibrow tab list work          # JSON: index, title, url per tab
hibrow tab new work
hibrow nav work:2 "https://..."   # act on tab index 2
hibrow tab close work:2
```

## Headless (unattended)

By default the browser opens a visible window. For unattended automation (no
window, no focus stealing — e.g. scraping, CI, an agent working in the
background), add `--headless` at launch:

```bash
hibrow launch work --headless
```

Notes:
- **Per-launch, set once.** It applies to that browser instance and only when it
  is actually spawned. You cannot toggle a running browser between headless and
  windowed — `kill` and relaunch to switch. If the profile is already running,
  `launch --headless` just finds the existing instance and the flag is a no-op.
- **Incompatible with manual login** (there is no window to type in). But the
  profile's data dir is shared across modes, so the pattern is: launch
  **visible**, log in once, `kill`, then relaunch the **same profile
  `--headless`** — you are still logged in, now automating with no window.

## Routing through a proxy

Launch a Chrome profile whose traffic goes through a proxy with `--proxy <url>`
(Chrome only — Firefox launches ignore it). For a SOCKS5 proxy, add `--proxy-dns`
so DNS is resolved at the proxy too, instead of leaking local lookups:

```bash
hibrow launch work --proxy "http://127.0.0.1:8080"
hibrow launch work --proxy "socks5://127.0.0.1:1080" --proxy-dns   # DNS via the proxy
```

Like `--headless`, this is set once at spawn — it applies to that instance only,
and is a no-op if the profile is already running. `kill` and relaunch to change
it.

## Chrome vs Firefox

Both are supported (`--browser chrome` default, `--browser firefox`). Chrome is
driven over the DevTools Protocol, Firefox over Marionette. Behavior is the same
for `nav`/`eval`/`screenshot`/`grab`. Firefox full-page screenshots fall back to
viewport if the page exceeds its canvas limit.

## Windows shells (cmd / PowerShell)

hibrow runs the same from Git Bash, cmd, and PowerShell — the binary parses its
own arguments. What differs is how each shell quotes the JS you pass to `eval`.

- **Windows PowerShell 5.1** (the default `powershell.exe`) **strips embedded
  double quotes** from an inline argument before the program ever sees them — its
  native-argument-passing bug. So `hibrow eval p --await
  'Promise.resolve(document.querySelector("body"))'` arrives as
  `...querySelector(body)` and fails with `ReferenceError: body is not defined`.
  This is not a hibrow bug and cannot be fixed in hibrow (the quotes are gone
  before hibrow starts). It affects any `eval`, not just `--await`. Avoid it by
  **running JS from a file** — `-f script.js` or piping via `-f-` — which bypasses
  shell quoting entirely (the standing recommendation anyway). Or use PowerShell
  7.3+ (`pwsh`), which passes quotes correctly.
- **cmd** has no such bug: wrap the JS in `"..."` and escape inner quotes as `\"`.
- **Scripting gotcha:** in a PowerShell script, do **not** pipe the first hibrow
  command (the one that auto-starts the gateway) through `| Out-Null`. The gateway
  daemon inherits the pipe's write handle and PowerShell blocks forever waiting for
  it to close. Let the command print, or redirect to a file (`> $null`).

## Troubleshooting

- **Empty/null eval result** — the element/data isn't there yet (SPA still
  rendering) or your JS returned nothing. Use `wait_for`; make sure the last
  statement is the value you want returned.
- **Form submits empty in a React app** — use the native-setter snippet.
- **Captured no network** — you installed capture after the request fired;
  re-trigger the action (see the timing gotcha).
- **`grab` fails cross-origin** — `nav` to the same origin first (CORS).
- **Page/eval frozen** — a native dialog is open; neutralize alert/confirm/prompt
  first.
- **"could not connect to gateway"** — it auto-starts; just retry once. Check
  with `hibrow gateway status`.
- **Nothing happens on click** — the real control may be a parent/child; use the
  enumerate snippet to find the actual clickable element and its selector.
