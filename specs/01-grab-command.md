# `hibrow grab` — extract binary data from browser to filesystem

## Context

Rothko demonstrated a useful pattern: use `eval` to get base64 data from the browser, chunk it to stay under the 1MB gateway line limit, decode and save. This should be a first-class hibrow command so any tool can grab images, files, or fetched resources from a browser session.

## Command

```
hibrow grab <profile> <js-expr-or-url> -o <file>
hibrow grab circuit "document.querySelector('canvas').toDataURL()" -o screenshot.png
hibrow grab circuit https://example.com/image.png -o image.png
```

## Design

### Two modes (auto-detected):

1. **URL mode** — arg starts with `http://` or `https://`: inject JS that fetches the URL in-browser (using cookies/auth), converts to base64, chunks it, returns chunks
2. **JS mode** — arg is a JS expression: inject wrapper that evals the expression (must return a base64 string or data URI), chunks result, returns chunks

### Chunking strategy (from rothko):

The gateway has a ~1MB line limit. Large base64 strings (images, video) exceed this. Solution:
- Inject JS that stores the full base64 in `window.__hibrowGrab` as an array of ≤950KB chunks
- Poll `window.__hibrowGrabStatus` until "done" or "error"
- Pull chunks one by one via repeated eval calls
- Decode concatenated base64, write binary to file

### Implementation:

**CLI only** — no new gateway method needed. `grab` is a multi-step orchestration of existing `eval` calls, implemented entirely in `main.zig`.

1. Parse args: profile, expression/URL, `-o <file>`
2. Generate the injection JS (URL-fetch or expression-eval wrapper)
3. `client.eval(profile, injection_js)` — kicks off async work, stores result chunked
4. Poll: `client.eval(profile, "window.__hibrowGrabStatus")` until done
5. Read chunk count: `client.eval(profile, "window.__hibrowGrabChunks.length")`
6. Pull chunks: `client.eval(profile, "window.__hibrowGrabChunks[N]")` for each N
7. Concatenate, base64-decode, write to output file

## Files

- `src/main.zig` — add `cmdGrab`, parse args, orchestrate eval calls, base64 decode, write file
- Usage string update

## Verification

```bash
zig build test
# URL mode:
hibrow launch testff --browser firefox
hibrow nav testff https://en.wikipedia.org/wiki/Opossum
hibrow grab testff "document.querySelector('.mw-file-element')?.src" -o /tmp/test.jpg
# or URL mode:
hibrow grab testff https://upload.wikimedia.org/wikipedia/commons/thumb/0/07/Didelphis_virginiana_with_young.JPG/250px-Didelphis_virginiana_with_young.JPG -o /tmp/test.jpg
open -a Preview /tmp/test.jpg
```
