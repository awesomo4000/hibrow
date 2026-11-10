# `hibrow screenshot` — capture part of the page

## Context

Sometimes you want a picture of one part of a page, not the whole thing: a panel, a
dialog, a single component, or a region inside a larger app layout.

The case that prompted this was a guided tour. A script staged a series of scenes in a
page (opening windows, running commands, scrolling a report), measured the elements it
wanted to annotate, and shot each scene. The page sat in one pane of a larger window, so
every shot needed cropping to that pane, and the annotation boxes were placed relative to
the crop. The same need shows up for documentation images, visual-regression checks on a
single component, bug reports that show only the broken element, and widget thumbnails.

Today the caller crops after the fact: measure the target with `eval`
(`getBoundingClientRect()`), take a full `screenshot`, convert viewport points to pixels
by the scale factor, and crop with an outside tool (`sips`, ImageMagick, Pillow). Every
caller redoes the scale math and brings its own image tool, and the crop is only as good
as the measurement — which goes stale if the page moves between the `eval` and the
`screenshot`.

## What we already have

`screenshot <profile[:tab]> -o <file> [--frame <path>]` captures the whole page by
default, or clips to a frame with `--frame`. The clipping machinery is already built and
is most of this feature:

- **A region-clip primitive.** `captureClip(x, y, w, h)` in `src/cdp.zig` drives CDP
  `Page.captureScreenshot` with a `clip` rect at `scale: 1` and
  `captureBeyondViewport: true`. That is exactly the rectangle capture this spec needs; it
  just is not exposed.
- **Atomic resolve-then-clip.** `screenshotFrame` → `resolveFrameRect` measures a
  `getBoundingClientRect()` and clips within a single gateway request, so the rect cannot
  go stale between measuring and capturing. A selector built the same way inherits that.
- **Capture beyond the viewport.** Because `captureBeyondViewport: true` is already set,
  the default shot is full-page and a clip may cover scrolled-out content. Capturing a
  region that is not currently on screen is therefore free here, not a later feature.
- **A shadow-piercing selector→rect resolver.** The click path already resolves a
  `a >>> b >>> c` selector through shadow roots and returns `[left, top, width, height]`
  (`src/cdp.zig`). That is a selector-to-rectangle function sitting next to the clip
  primitive.
- **Firefox element capture.** The Marionette path (`src/marionette.zig`,
  `screenshotFrame`) already shoots a single element via `WebDriver:TakeScreenshot` with
  an element id, so a selector maps cleanly on Firefox.

So the gaps are the flags and the result shape, not the capture itself.

## Command

Add three optional flags to `screenshot`. With none of them, behavior is unchanged.

```
hibrow screenshot <profile[:tab]> -o <file> [--frame <path>]
                   [--selector <css>] [--region <x,y,w,h>] [--padding <pts>]

hibrow screenshot app -o panel.png   --selector '#report-pane'
hibrow screenshot app -o badge.png   --selector '#host >>> #status'   --padding 8
hibrow screenshot app -o crop.png    --region 40,120,600,400
```

| Flag | Meaning |
| --- | --- |
| `--selector <css>` | CSS selector (supports `>>>` shadow piercing), resolved in the main frame; the first match's bounding rect is captured |
| `--region <x,y,w,h>` | Rectangle in viewport points — the same units as `click` and `getBoundingClientRect()` |
| `--padding <pts>` | Points added on every side of a `--selector` or `--region` rect |

`--selector`, `--region` and `--frame` are mutually exclusive; passing more than one is an
error.

## Design

- **Units.** CDP `clip`, `getBoundingClientRect()`, and `click`'s `clientX/clientY` are
  all CSS pixels at `scale: 1`, so `--region` and `--selector` speak the same "viewport
  points" the rest of the CLI already uses. No scale math for the caller.
- **Selector capture (both engines).** Chrome: resolve the selector to a rect with the
  existing shadow-aware resolver, add padding, then `captureClip`. Firefox: find the
  element and shoot it with the element-screenshot path, or measure its rect and crop;
  whichever gives shadow parity with Chrome.
- **Region capture.** `--region` is `captureClip` with the given numbers (plus padding).
  Chrome-native immediately. Firefox has no raw-rect screenshot, so a region there is
  measure-the-viewport-and-crop, or we scope raw `--region` to Chrome first and add
  Firefox after.
- **Resolve and capture in one request.** The selector is resolved and the clip is taken
  inside a single gateway call, so a page that moves cannot invalidate the rect — the
  staleness the after-the-fact crop suffers from does not exist here.
- **Clamping.** Clip the rect to the page bounds (not just the viewport — we already
  capture beyond the viewport, and shooting a partly-scrolled element whole is a feature,
  not a bug). A rect that is entirely off the page, or zero-sized after clamping, returns
  a clear error rather than an empty image. An unmatched selector returns an error naming
  the selector.
- **Report the captured region.** The gateway currently returns a bare base64 PNG string,
  which the CLI decodes straight to `-o`; there is nowhere to put the rect that was
  actually shot. Widen the screenshot response to an object — `{data, width, height,
  region: {x, y, width, height}}` — where `region` is the rect after padding and clamping,
  in viewport points. The CLI writes `data` to `-o` as now and prints `region` as its one
  JSON stdout value, so a tour script can place annotations onto the image without
  guessing. This is the only part that changes the wire contract; it can land as its own
  step.
- **Frames.** `--selector` resolves in the main frame, like `eval`. `--frame` keeps
  working as today for iframe capture; to shoot an element inside an iframe, combine the
  frame's rect with the element's rect as a `--region`.

## Files

- `src/main.zig` — `cmdScreenshot`: parse `--selector` / `--region` / `--padding`,
  enforce mutual exclusion, pass through; print `region` to stdout; usage string.
- `src/root.zig` — thread the new params through `Client.screenshot` into the request.
- `src/gateway.zig` — `handleBrowserScreenshot`: route selector/region/padding; widen the
  response to carry `region`; clamp and raise the empty/off-page/no-match errors.
- `src/cdp.zig` — selector→rect via the existing shadow resolver + padding → `captureClip`
  returning the clamped rect; `--region` path.
- `src/marionette.zig` — element capture for `--selector`; region fallback.
- `tests/e2e-features.sh` — see below.

## Verification

```bash
zig build test
```

E2E on both engines, against the existing frame/shadow fixtures:

- `--region x,y,w,h` yields an image whose pixel size equals the region times the scale
  factor, and the reported `region` echoes the request.
- `--selector '#el'` matches the capture of the equivalent measured `--region`.
- `--selector '#host >>> #inner'` captures a shadow-DOM element (parity with Chrome).
- `--padding` grows the region and the result is still clamped.
- Clamping at each page edge; errors for an off-page region, a zero-sized region, and an
  unmatched selector (the message names the selector).
- A plain `screenshot -o out.png` with no new flags is unchanged.

## Rollout

1. `--selector` + `--padding` + clamping/errors — the whole guided-tour case, almost all
   existing parts wired together, both engines.
2. `--region` — Chrome-native, Firefox via crop.
3. `region` in the response — the wire-contract widening, taken on its own.
