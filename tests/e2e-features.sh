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
[ -x "$HIBROW" ] || HIBROW="$HIBROW.exe"   # Windows build produces hibrow.exe

# `mise run e2e` builds first (zig is mise-managed and not on PATH here, so the
# script cannot build itself). mise sets MISE_TASK_NAME when running a task — it
# is empty on a direct ./tests/e2e-features.sh invocation, and stays empty even in
# a mise-activated shell since only task execution sets it. Warn when standalone so
# a stale binary cannot masquerade as a passing run.
if [ -z "${MISE_TASK_NAME:-}" ]; then
    printf '\033[33mnote:\033[0m not run via mise — testing the existing binary without rebuilding (%s).\n' "$HIBROW" >&2
    printf '      run \x27mise run e2e\x27 to build first if you changed the source.\n' >&2
fi

# Browsers need a real file: URL. Under Git Bash the repo path is /c/..., which
# no Windows browser resolves; cygpath -m rewrites it to C:/... form. Elsewhere
# the repo path is already absolute and usable as-is.
fileurl() {
    if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s' "$(cygpath -m "$REPO/$1")"
    else printf 'file://%s' "$REPO/$1"; fi
}
FRAMES="$(fileurl evals/skill/frames/top.html)"
SHADOW="$(fileurl evals/skill/frames/shadow.html)"
MEDIA="$(fileurl evals/skill/frames/media.html)"
PLAYBACK="$(fileurl evals/skill/frames/playback.html)"
PASS=0; FAIL=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

g() { printf '\033[32m%s\033[0m' "$*"; }
r() { printf '\033[31m%s\033[0m' "$*"; }
ok()  { PASS=$((PASS+1)); echo "  $(g PASS) $1"; }
no()  { FAIL=$((FAIL+1)); echo "  $(r FAIL) $1 — got: [${2:-}]"; }

eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2"; fi; }
gt()       { if awk "BEGIN{exit !($2 > $3)}" 2>/dev/null; then ok "$1"; else no "$1" "$2 not > $3"; fi; }
contains() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else no "$1" "$2"; fi; }
is_png()   { if [ -f "$2" ] && file "$2" | grep -q "PNG image"; then ok "$1"; else no "$1" "no png"; fi; }

[ -x "$HIBROW" ] || { echo "$(r ERROR): build first (zig build) — $HIBROW missing"; exit 1; }

# Browser detection is cross-platform: macOS keeps browsers in /Applications,
# Linux puts them on PATH under various names, Windows installs them under
# Program Files. hibrow itself finds them the same way per platform, so here we
# just gate whether to run.
on_path() { for n in "$@"; do command -v "$n" >/dev/null 2>&1 && return 0; done; return 1; }
have_chrome() {
    [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] ||
    [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ] ||
    [ -x "/c/Program Files/Google/Chrome/Application/chrome.exe" ] ||
    [ -x "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" ] ||
    on_path google-chrome google-chrome-stable chromium chromium-browser
}
have_firefox() {
    [ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ] ||
    [ -x "/c/Program Files/Mozilla Firefox/firefox.exe" ] ||
    [ -x "/c/Program Files (x86)/Mozilla Firefox/firefox.exe" ] ||
    on_path firefox
}

run_browser() {
    local browser="$1" P="e2e-$1"
    echo; echo "========== $browser =========="
    "$HIBROW" gateway stop >/dev/null 2>&1; sleep 1

    # --allow-autoplay so the real-playback block below can start media without
    # a user gesture (Chrome blocks scripted play otherwise; no-op on Firefox).
    "$HIBROW" launch "$P" --browser "$browser" --headless --allow-autoplay >/dev/null 2>&1 || { no "launch $browser" "launch failed"; return; }
    ok "launch $browser --headless"

    # --- session listing + daemon status ---
    contains "ls lists the session" "$("$HIBROW" ls "$P" 2>&1 | tr -d '\n ')" "\"profile\":\"$P\""
    contains "ls reports browser"   "$("$HIBROW" ls "$P" 2>&1 | tr -d '\n ')" "\"browser_type\":\"$browser\""
    contains "gateway status"       "$("$HIBROW" gateway status 2>&1)" "running"

    # --- core: nav + eval ---
    "$HIBROW" nav "$P" "$FRAMES" >/dev/null 2>&1   # nav waits for load; no sleep needed
    eq "eval returns value"        "$("$HIBROW" eval "$P" '1+1' 2>&1)" "2"
    eq "eval reads top DOM"        "$("$HIBROW" eval "$P" "document.querySelector('#top').innerText" 2>&1)" '"TOP"'
    # A thrown error must surface its real message, not a bare category. Both engines
    # include the error type and the offending identifier (chrome prefixes "Uncaught").
    contains "eval surfaces error msg" "$("$HIBROW" eval "$P" 'nonexistentVar123' 2>&1)" "ReferenceError"
    contains "eval error names ident"  "$("$HIBROW" eval "$P" 'nonexistentVar123' 2>&1)" "nonexistentVar123"
    contains "url reports location" "$("$HIBROW" url "$P" 2>&1)" "frames/top.html"

    # --- push: plain input + window variable ---
    "$HIBROW" push "$P" '#pin' 'PUSHED-IN' >/dev/null 2>&1
    eq "push sets input value"     "$("$HIBROW" eval "$P" "document.getElementById('pin').value" 2>&1)" '"PUSHED-IN"'
    "$HIBROW" push "$P" 'window.__pv' 'PUSHED-VAR' >/dev/null 2>&1
    eq "push sets window var"      "$("$HIBROW" eval "$P" 'window.__pv' 2>&1)" '"PUSHED-VAR"'

    # --- grab: JS-mode base64 decoded to a file ---
    "$HIBROW" eval "$P" 'window.__g = btoa("GRABBED-BYTES")' >/dev/null 2>&1
    "$HIBROW" grab "$P" 'window.__g' -o "$tmpdir/grab.bin" >/dev/null 2>&1
    eq "grab writes decoded bytes" "$(cat "$tmpdir/grab.bin" 2>/dev/null)" "GRABBED-BYTES"

    # --- frame tree / plain click / eval from file+stdin / wait --gone ---
    contains "frame list --tree"   "$("$HIBROW" frame list "$P" --tree 2>&1 | tr -d ' ')" '\[0/0\]'
    "$HIBROW" click "$P" '#tbtn' >/dev/null 2>&1
    eq "click top-level element"   "$("$HIBROW" eval "$P" 'window.__tc' 2>&1)" "1"
    printf '6*7\n' > "$tmpdir/eval.js"
    eq "eval -f file"              "$("$HIBROW" eval "$P" -f "$tmpdir/eval.js" 2>&1)" "42"
    eq "eval -f- stdin"            "$(printf '%s' '"io-"+"stdin"' | "$HIBROW" eval "$P" -f- 2>&1)" '"io-stdin"'
    "$HIBROW" eval "$P" "var d=document.createElement('div');d.id='ephemeral';document.body.appendChild(d);setTimeout(function(){d.remove();},800);'made'" >/dev/null 2>&1
    eq "wait --gone"               "$("$HIBROW" wait "$P" '#ephemeral' --gone --timeout 5 2>&1)" "true"

    # --- frames ---
    contains "frame list shows nested" "$("$HIBROW" frame list "$P" 2>&1 | tr -d '\n ')" '"path":"0/0"'
    eq "eval --frame index"        "$("$HIBROW" eval "$P" --frame 0 "document.querySelector('#a').innerText" 2>&1)" '"CHILD-A"'
    eq "eval --frame nested"       "$("$HIBROW" eval "$P" --frame 0/0 "document.querySelector('#g').innerText" 2>&1)" '"GRANDCHILD"'
    eq "eval --frame selector"     "$("$HIBROW" eval "$P" --frame '#fa/#fg' "document.querySelector('#g').innerText" 2>&1)" '"GRANDCHILD"'

    # --- eval --await: settle a promise in one command ---
    # A sync value returns immediately; a promise is awaited; errors, rejections,
    # and a never-settling promise all come back as structured diagnostics without
    # wedging the session. Deterministic async via setTimeout — no network.
    eq "await sync value"            "$("$HIBROW" eval "$P" --await '1+2' 2>&1)" "3"
    contains "await resolves object" "$("$HIBROW" eval "$P" --await 'new Promise(function(r){setTimeout(function(){r({ok:true});},150);})' 2>&1 | tr -d '\n ')" '"ok":true'
    eq "await async IIFE"            "$("$HIBROW" eval "$P" --await '(async()=>{await new Promise(function(r){setTimeout(r,50);});return 6*7;})()' 2>&1)" "42"
    contains "await rejection message" "$("$HIBROW" eval "$P" --await 'Promise.reject(new Error("awaitfail777"))' 2>&1)" "awaitfail777"
    contains "await keeps non-error reject" "$("$HIBROW" eval "$P" --await 'Promise.reject("plainreject888")' 2>&1)" "plainreject888"
    "$HIBROW" eval "$P" --await 'Promise.reject(new Error("x"))' >/dev/null 2>&1; eq "await error exits nonzero" "$?" "1"
    contains "await reports timeout"  "$("$HIBROW" eval "$P" --await --timeout 1 'new Promise(function(){})' 2>&1)" '"type":"timeout"'
    eq "await session survives timeout" "$("$HIBROW" eval "$P" --await '555' 2>&1)" "555"
    eq "await in frame"              "$("$HIBROW" eval "$P" --frame 0 --await 'Promise.resolve(document.querySelector("#a").innerText)' 2>&1)" '"CHILD-A"'

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
    "$HIBROW" nav "$P" "$SHADOW" >/dev/null 2>&1
    contains "text pierces shadow" "$("$HIBROW" text "$P" 2>&1)" "NESTED-SHADOW-TEXT"
    "$HIBROW" click "$P" '#host >>> #sbtn' >/dev/null 2>&1
    eq "shadow >>> click"          "$("$HIBROW" eval "$P" "document.getElementById('result').textContent" 2>&1)" '"SHADOW-CLICKED"'
    "$HIBROW" click "$P" '#host >>> #nh >>> #nbtn' >/dev/null 2>&1
    eq "nested shadow click"       "$("$HIBROW" eval "$P" "document.getElementById('result').textContent" 2>&1)" '"NESTED-CLICKED"'

    # --- media ---
    "$HIBROW" nav "$P" "$MEDIA" >/dev/null 2>&1
    contains "media list captions" "$("$HIBROW" media list "$P" 2>&1 | tr -d '\n ')" '"captions"'
    contains "media mute"          "$("$HIBROW" media mute "$P" 2>&1 | tr -d '\n ')" '"muted"'
    contains "media unmute"        "$("$HIBROW" media unmute "$P" 2>&1 | tr -d '\n ')" '"muted":false'
    contains "media play"          "$("$HIBROW" media play "$P" 2>&1 | tr -d '\n ')" '"tag":"audio"'
    contains "media pause"         "$("$HIBROW" media pause "$P" 2>&1 | tr -d '\n ')" '"paused":true'

    # --- real playback: muted autoplay, timeline advances, wait-ended via seek ---
    # A multi-second tone built in-page (evals/skill/frames/playback.html) so the
    # clock actually moves. These prove playback happens, not just that the
    # commands return the right shape.
    "$HIBROW" nav "$P" "$PLAYBACK" >/dev/null 2>&1
    eq "muted autoplay is playing"  "$("$HIBROW" eval "$P" "var e=document.getElementById('pb');(!e.paused)+','+e.muted" 2>&1)" '"true,true"'
    "$HIBROW" eval "$P" "document.getElementById('pb').currentTime=0;'ok'" >/dev/null 2>&1
    "$HIBROW" media play "$P" '#pb' >/dev/null 2>&1
    pt0="$("$HIBROW" eval "$P" "document.getElementById('pb').currentTime" 2>&1)"
    sleep 1
    pt1="$("$HIBROW" eval "$P" "document.getElementById('pb').currentTime" 2>&1)"
    gt "playback advances currentTime" "$pt1" "$pt0"
    "$HIBROW" eval "$P" "var e=document.getElementById('pb');e.currentTime=e.duration-0.2;e.play();'ok'" >/dev/null 2>&1
    contains "wait-ended after seek" "$("$HIBROW" media wait-ended "$P" '#pb' --timeout 10 2>&1 | tr -d '\n ')" '"ended":true'

    # --- tab lifecycle: new / switch / close (count-based; indices reshuffle) ---
    ntabs() { "$HIBROW" tab list "$P" 2>&1 | grep -o '"index"' | wc -l | tr -d ' '; }
    eq "tab count starts at 1"     "$(ntabs)" "1"
    "$HIBROW" tab new "$P" >/dev/null 2>&1
    eq "tab new adds a tab"        "$(ntabs)" "2"
    contains "tab switch"          "$("$HIBROW" tab switch "$P:0" 2>&1)" "switched"
    "$HIBROW" tab close "$P:0" >/dev/null 2>&1
    eq "tab close removes a tab"   "$(ntabs)" "1"

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
