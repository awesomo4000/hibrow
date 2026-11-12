# `hibrow eval --await` — settle a promise in one command

**Status:** Implemented. `--await` + `--timeout <secs>` ship on `eval` for Chrome
and Firefox, inline / `-f` / `-f-` / tab / `--frame`, with the four error
categories below; the feature e2e suite asserts the behavior on both engines. The
gateway-side read-deadline backstop (see "Timeout") was left out of v1 — the
page-side race and CDP/Marionette context-destroyed errors cover the realistic
cases — and can be added if a pathological hang is ever observed.

## Context

`eval` is synchronous: it returns the completion value of the expression and does
not wait for a promise to settle. To inspect anything asynchronous — a `fetch`, a
timer, a save that completes a beat later — the caller has to start the work, stash
its result on a page global, and poll that global from a second command:

```bash
hibrow eval work '
  window.__result = null;
  fetch("/api/state").then(r => r.json()).then(v => window.__result = v);
  "started"
'
until [ "$(hibrow eval work "window.__result !== null")" = "true" ]; do sleep 0.3; done
hibrow eval work "window.__result" | jq .
```

This is several commands, it mutates page state, and it is racy: a rejection needs a
separate branch, two overlapping checks clobber the same global, and the poll interval
is a guess. The common need — "run this async thing and give me its real result or its
real error, in one command" — deserves a first-class path.

## What we already have

Most of the browser-protocol work is done, because `wait`, `click`, and `nav` already
drive promise settlement:

- **Chrome — native await.** `cdp.zig` `evalAwait` runs `Runtime.evaluate` with
  `awaitPromise: true` and `returnByValue: true`. It awaits a returned promise or
  thenable, returns a plain value immediately, and surfaces a rejection through
  `exceptionDetails` with the real message and stack (the BUG-005 parser handles that).
  `evalAwaitInFrame` exists for frame targets.
- **Firefox — async script.** `marionette.zig` `evalAsync` settles a promise via
  `WebDriver:ExecuteAsyncScript`, receiving the resolve callback as the script's last
  argument.
- **Statement bodies already work.** Both engines wrap user code as `(0,eval)("<json
  string>")` (indirect eval in global scope). That means multi-statement scripts
  (`var x = 1; x + 1`) return their completion value today, so we can wrap the user's
  code in a timeout race without requiring them to pass a bare expression. The request's
  "don't wrap me in an async function or change my scope" constraint is already honored:
  indirect eval keeps top-level `var`/`let` script-scoped exactly as plain `eval` does.

The gap is not "can we await" — it is a clean, bounded, error-preserving await exposed
on the `eval` command for both engines, including frames.

## Command

A new opt-in flag. Absent the flag, `eval` behaves exactly as it does today.

```bash
hibrow eval work --await 'fetch("/api/state").then(r => r.json())'
hibrow eval work --await -f verify.js
hibrow eval work:2 --await -f-
hibrow eval work --frame 0 --await 'someAsyncThing()'
hibrow eval work --await --timeout 10 'new Promise(r => setTimeout(() => r({ready:true}), 500))'
```

`--await` composes with everything `eval` already supports: inline string, `-f <file>`,
`-f-` (stdin), `<profile>:<tab>`, and `--frame <path>`.

`--timeout <seconds>` bounds an awaited evaluation, default **30**. It is the same
`--timeout <secs>` already used by `wait`, `click`, and `media wait-ended`, so the units
are consistent across the CLI. It has no effect without `--await`.

## Semantics

With `--await`:

1. Evaluate the supplied JavaScript under the existing evaluation rules (indirect eval,
   same scope as plain `eval`).
2. If the completion value is a promise or thenable, await it; otherwise return it
   immediately.
3. Serialize the settled value with the existing by-value JSON output, so the result
   drops straight into `jq` — the resolved object itself, never a promise descriptor and
   never a JSON string nested inside another JSON string.
4. Preserve existing behavior for `undefined` and values that do not serialize.

Top-level `await` is **not** supported initially; an async IIFE is the idiom:

```bash
hibrow eval work --await '
(async () => {
  const r = await fetch("/api/state");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return await r.json();
})()
'
```

## Timeout (the load-bearing design choice)

CDP `awaitPromise` has **no built-in timeout**, and the gateway caches the per-profile
connection and services requests serially. A promise that never settles would block that
connection's socket read indefinitely and wedge the profile. So the timeout cannot be a
"nice to have" — it is what keeps a bad script from taking the session down.

**Enforce the timeout page-side, not by abandoning the socket.** Wrap the user's code in
a race against a page-side timer, then await the race. The promise always settles, so the
connection is never left hanging:

```js
Promise.race([
  Promise.resolve((0,eval)("<user code>")),
  new Promise((_, reject) => setTimeout(() => reject(__HIBROW_TIMEOUT), N * 1000)),
])
```

This also gives the semantics the request asks for: a timeout stops *waiting*, it does
**not** cancel the JavaScript or network requests already running in the page — the race
simply stops listening. As defense in depth against a context that is torn down before
even the page timer fires, the gateway keeps a hard backstop read deadline slightly above
the page timeout (`N + 2s`), mirroring what `evalAsync` already does on Firefox
(`script` timeout set to `timeout_ms + 2000`). The page-side timer is the primary
mechanism; the backstop only ever fires if the whole context is gone.

On timeout the command must: exit nonzero, report a **distinct** timeout error (not a
generic JS error), leave the session usable for the next command, and say in the
diagnostic that the underlying work may still be running in the page.

## Errors

A synchronous throw or a rejected promise exits nonzero and writes a structured
diagnostic to **stderr**, with nothing on stdout:

```json
{ "error": { "type": "javascript", "message": "HTTP 500", "stack": "..." } }
```

Four categories, distinguishable by `type`:

- `javascript` — a thrown error or a rejected promise. Include message and, when present,
  stack. Non-`Error` rejections (`Promise.reject("nope")`, `Promise.reject(42)`) keep
  their value as the message.
- `timeout` — the await deadline expired.
- `context-loss` — the page navigated or the frame was removed before settlement.
- `serialization` — the settled value could not be serialized by value.

Implementation note: `evalAsync` currently maps **every** rejection to `false` (correct
for `wait`, where a rejection means "condition not met"). The await path must not reuse
that; it needs a variant that forwards `{ __ok: v }` / `{ __err: stack || String(e) }`
through the callback so resolve and reject are distinguishable and a non-`Error`
rejection survives intact.

## Context loss, and no silent reruns

The Chrome path normally reconnects and **retries once** on a dropped socket (the
`chromeOp` helper). The await path must **opt out of that retry**: a disconnect in the
middle of an await becomes a terminal `context-loss` error, never a silent
re-execution. Re-running an awaited script that may already have performed a mutation is
exactly the failure we refuse to risk (same discipline as not double-executing a `click`
that legitimately found nothing).

## Browser support

Chrome and Firefox must behave equivalently, including for supported frame targets:

- **Chrome:** reuse `evalAwait` / `evalAwaitInFrame`, with the user code wrapped in the
  timeout race before it is handed to `Runtime.evaluate`.
- **Firefox inline:** a new async variant alongside `evalAsync` that preserves errors
  (the `{__ok}/{__err}` wrapper) instead of collapsing rejections to `false`.
- **Firefox frames:** net-new — `SwitchToFrame` + `ExecuteAsyncScript`, since there is an
  `evalInFrame` but no async-in-frame today.

If a browser or frame context genuinely cannot support an awaited eval, return an explicit
error rather than silently falling back to a synchronous evaluation.

## Backward compatibility

`--await` is strictly additive and opt-in. With the flag absent:

- The command dispatches to the same code path it does now (`cmdEval` → `browser.eval` /
  `evalInFrame`), with the same by-value JSON on stdout, the same error reporting, and the
  same exit status.
- No shared evaluation code changes behavior; the new behavior lives behind the flag and
  the new gateway params (`await`, `timeout_ms`).

So an existing script — anything calling `hibrow eval <profile> ...` without `--await` —
is unaffected: same output, same timing, same exit codes. The structured
`{ "error": { ... } }` stderr contract is introduced **only** for `--await` failures; we
do not retrofit it onto plain-eval errors in this change (that would alter output existing
callers may parse). If we later decide plain-eval errors should match, that is a separate,
explicitly-called-out change.

The one thing a caller could notice: `--await` is now a reserved flag to `eval`, so a
script that (bizarrely) passed the literal token `--await` as an expression would now be
parsed as the flag. That is the standard cost of adding any flag and is acceptable.

## Implementation sketch

- `cdp.zig`: wrap user code in the timeout race for the await path; add a frame-aware
  await entry if the existing `evalAwaitInFrame` needs the race too; ensure the await op
  does **not** go through the reconnect-and-retry helper.
- `marionette.zig`: an error-preserving async variant (`evalAwaitErr` or similar) and its
  frame counterpart (`SwitchToFrame` + `ExecuteAsyncScript`).
- `gateway.zig`: `handleBrowserEval` reads `await` (bool) and `timeout_ms`, routes to the
  await methods, and maps failures to the four error categories. Needs a timeout error
  code and a context-loss signal in the error mapping.
- `protocol.zig`: whatever error-type tag the categories require on the error response.
- `root.zig`: thread `await` / `timeout_ms` through the library `eval` options.
- `main.zig`: parse `--await` and `--timeout` in `cmdEval`; on failure, emit the
  structured JSON to stderr and exit nonzero; keep stdout clean.
- `src/skill.md`: document `--await` in the async section (and soften golden-rule #3,
  which currently says eval never awaits).

## Acceptance tests (e2e, both engines)

- A synchronous value returns immediately with `--await`.
- A delayed promise resolves to each JSON shape: object, array, string, number, boolean,
  null.
- Async IIFE works from inline, `-f`, and `-f-`.
- A rejected promise and a synchronous throw exit nonzero with a useful diagnostic; a
  non-`Error` rejection keeps its value.
- A never-settling promise times out, exits nonzero with `type: timeout`, and the **next**
  command on the same profile still works.
- Navigating (or removing the frame) mid-await yields `context-loss` and does **not**
  rerun the script.
- Tab and frame targeting behave the same on Chrome and Firefox.
- Without `--await`, every existing `eval` behavior is unchanged.
- No caller-managed page globals or polling commands are required for any of the above.

### Test machinery notes

- The feature suite (`tests/e2e-features.sh`) needs a page that can produce deterministic
  async outcomes without the network: a tiny in-page helper that returns promises
  resolving/rejecting after a set delay, plus one that never settles (for the timeout
  case). Prefer a local `data:`/fixture page over any live endpoint so the suite stays
  hermetic and fast, same as the existing media and frame fixtures.
- The never-settles test must assert the **follow-up** command succeeds, which is the real
  proof the timeout left the session healthy rather than just that the first command
  failed.
