#!/usr/bin/env bash
#
# hibrow feature e2e — exercises the real CLI against real Chrome AND Firefox,
# headless, using local fixtures. Independent of the skill / eval battery.
#
# Covers: launch/nav/eval, frames (list/--frame index+nested+selector),
# click (+ shadow >>>), wait, screenshot (+ --frame), text (shadow), media, tabs.
#
# Usage: ./tests/e2e-features.sh [chrome|firefox]   (default: both installed)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HIBROW="$REPO/zig-out/bin/hibrow"
FRAMES="file://$REPO/evals/skill/frames/top.html"
SHADOW="file://$REPO/evals/skill/frames/shadow.html"
MEDIA="file://$REPO/evals/skill/frames/media.html"
PASS=0; FAIL=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

g() { printf '\033[32m%s\033[0m' "$*"; }
r() { printf '\033[31m%s\033[0m' "$*"; }
ok()  { PASS=$((PASS+1)); echo "  $(g PASS) $1"; }
no()  { FAIL=$((FAIL+1)); echo "  $(r FAIL) $1 — got: [${2:-}]"; }

eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2"; fi; }
contains() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else no "$1" "$2"; fi; }
is_png()   { if [ -f "$2" ] && file "$2" | grep -q "PNG image"; then ok "$1"; else no "$1" "no png"; fi; }

[ -x "$HIBROW" ] || { echo "$(r ERROR): build first (zig build) — $HIBROW missing"; exit 1; }

have_chrome()  { [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] || [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ]; }
have_firefox() { [ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ]; }

run_browser() {
    local browser="$1" P="e2e-$1"
    echo; echo "========== $browser =========="
    "$HIBROW" gateway stop >/dev/null 2>&1; sleep 1

    "$HIBROW" launch "$P" --browser "$browser" --headless >/dev/null 2>&1 || { no "launch $browser" "launch failed"; return; }
    ok "launch $browser --headless"

    # --- core: nav + eval ---
    "$HIBROW" nav "$P" "$FRAMES" >/dev/null 2>&1; sleep 2
    eq "eval returns value"        "$("$HIBROW" eval "$P" '1+1' 2>&1)" "2"
    eq "eval reads top DOM"        "$("$HIBROW" eval "$P" "document.querySelector('#top').innerText" 2>&1)" '"TOP"'

    # --- frames ---
    contains "frame list shows nested" "$("$HIBROW" frame list "$P" 2>&1 | tr -d '\n ')" '"path":"0/0"'
    eq "eval --frame index"        "$("$HIBROW" eval "$P" --frame 0 "document.querySelector('#a').innerText" 2>&1)" '"CHILD-A"'
    eq "eval --frame nested"       "$("$HIBROW" eval "$P" --frame 0/0 "document.querySelector('#g').innerText" 2>&1)" '"GRANDCHILD"'
    eq "eval --frame selector"     "$("$HIBROW" eval "$P" --frame '#fa/#fg' "document.querySelector('#g').innerText" 2>&1)" '"GRANDCHILD"'

    # --- click (in a frame) + wait ---
    "$HIBROW" click "$P" '#gbtn' --frame 0/0 >/dev/null 2>&1
    eq "click in frame"            "$("$HIBROW" eval "$P" --frame 0/0 "document.getElementById('gstate').textContent" 2>&1)" '"CLICKED"'
    eq "wait for element in frame" "$("$HIBROW" wait "$P" '#glate' --frame 0/0 --timeout 5 2>&1)" "true"

    # --- screenshot (full + frame) ---
    "$HIBROW" screenshot "$P" -o "$tmpdir/full.png" >/dev/null 2>&1;  is_png "screenshot full"  "$tmpdir/full.png"
    "$HIBROW" screenshot "$P" --frame 0/0 -o "$tmpdir/frame.png" >/dev/null 2>&1; is_png "screenshot --frame" "$tmpdir/frame.png"

    # --- tabs ---
    contains "tab list"            "$("$HIBROW" tab list "$P" 2>&1 | tr -d '\n ')" '"index":0'

    # --- shadow DOM: text + trusted >>> click ---
    "$HIBROW" nav "$P" "$SHADOW" >/dev/null 2>&1; sleep 2
    contains "text pierces shadow" "$("$HIBROW" text "$P" 2>&1)" "NESTED-SHADOW-TEXT"
    "$HIBROW" click "$P" '#host >>> #sbtn' >/dev/null 2>&1
    eq "shadow >>> click"          "$("$HIBROW" eval "$P" "document.getElementById('result').textContent" 2>&1)" '"SHADOW-CLICKED"'
    "$HIBROW" click "$P" '#host >>> #nh >>> #nbtn' >/dev/null 2>&1
    eq "nested shadow click"       "$("$HIBROW" eval "$P" "document.getElementById('result').textContent" 2>&1)" '"NESTED-CLICKED"'

    # --- media ---
    "$HIBROW" nav "$P" "$MEDIA" >/dev/null 2>&1; sleep 1
    contains "media list captions" "$("$HIBROW" media list "$P" 2>&1 | tr -d '\n ')" '"captions"'
    contains "media mute"          "$("$HIBROW" media mute "$P" 2>&1 | tr -d '\n ')" '"muted"'

    "$HIBROW" kill "$P" >/dev/null 2>&1
    "$HIBROW" gateway stop >/dev/null 2>&1
}

TARGET="${1:-}"
if [ -n "$TARGET" ]; then
    run_browser "$TARGET"
else
    have_chrome  && run_browser chrome  || echo "(skipping chrome — not installed)"
    have_firefox && run_browser firefox || echo "(skipping firefox — not installed)"
fi

echo; echo "=============================="
echo "$(g PASS) $PASS   $([ "$FAIL" -gt 0 ] && r FAIL || echo FAIL) $FAIL"
[ "$FAIL" -eq 0 ]
