---
name: hibrow
description: Drive a real Chrome or Firefox from the command line to do browser tasks — navigate, read/scrape pages, fill forms, click, log in, screenshot, and download. Use this whenever you need to interact with a website, inspect a live page, automate a web UI, test a web app, extract data from a page that needs a real browser (JS-rendered, auth-gated, or behind a login), capture a site's network traffic, or whenever the user mentions hibrow.
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
3. **`eval` is synchronous — it does NOT await promises.** For anything async
   (fetch, timers), store the result on a `window.*` variable and poll it.
4. **Don't `eval` huge strings.** For anything bigger than a few KB of binary or
   text, use `grab` (handles fetch + chunking for you).
5. **Prefer running JS from a file** (`-f file.js`) over cramming complex JS into
   one shell-quoted line. The multi-line snippets below are meant to be saved to
   a `.js` file and run with `hibrow eval <profile> -f file.js` (or piped via
   `-f-`). This avoids quoting hell and makes them reusable.

## Core commands

```bash
hibrow launch <profile> [--browser chrome|firefox]   # start a named session
hibrow ls [profile]                                  # list sessions / details (JSON)
hibrow nav <profile[:tab]> <url>                     # navigate
hibrow url <profile[:tab]>                            # print current URL
hibrow eval <profile[:tab]> "<js>" | -f <file> | -f- # run JS, return JSON
hibrow push <profile[:tab]> <target> <text> | -f <f> # set an input value / window var
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
This needs a **visible** browser so the human can type, so launch normally (do
NOT use a headless setup for login). Navigate to the login page, ask the user to
sign in (including any MFA), and poll for a logged-in signal:

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

## Async: store-and-poll

`eval` won't wait for a promise. Kick it off, stash the result on `window`, poll.

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

Then click by the selector you found:

```bash
hibrow eval work 'document.querySelector("#submit").click(); "clicked"'
```

If an element isn't there yet (SPA still rendering), use `wait_for` above, or
poll: `hibrow eval work 'document.querySelector("#submit") ? "ready" : "waiting"'`.

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

A very common need: see every request a site makes (and the responses). Install
capture, then do the action, then read `window.__net` (`capture-net.js`, `-f`):

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

## Tabs

```bash
hibrow tab list work          # JSON: index, title, url per tab
hibrow tab new work
hibrow nav work:2 "https://..."   # act on tab index 2
hibrow tab close work:2
```

## Chrome vs Firefox

Both are supported (`--browser chrome` default, `--browser firefox`). Chrome is
driven over the DevTools Protocol, Firefox over Marionette. Behavior is the same
for `nav`/`eval`/`screenshot`/`grab`. Firefox full-page screenshots fall back to
viewport if the page exceeds its canvas limit.

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
