#!/usr/bin/env bash
#
# hibrow end-to-end tests
#
# Exercises the real CLI binary against a real browser.
# Uses a dedicated "test-e2e" profile to avoid interfering with real sessions.
#
# Usage: ./tests/e2e.sh
#
set -euo pipefail

HIBROW="./zig-out/bin/hibrow"
PROFILE="test-e2e"
PASS=0
FAIL=0
TOTAL=0
RESULTS=()

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    RESULTS+=("PASS|$1")
    echo "  $(green PASS) $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    RESULTS+=("FAIL|$1")
    echo "  $(red FAIL) $1"
    if [ -n "${2:-}" ]; then
        echo "       got: $2"
    fi
}

assert_contains() {
    local output="$1" expected="$2" label="$3"
    if echo "$output" | grep -q "$expected"; then
        pass "$label"
    else
        fail "$label" "$output"
    fi
}

assert_equals() {
    local output="$1" expected="$2" label="$3"
    if [ "$output" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "$output"
    fi
}

assert_exit_zero() {
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        pass "$label"
    else
        fail "$label" "exit code $?"
    fi
}

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

echo ""
bold "hibrow e2e tests"
echo ""
echo "binary: $HIBROW"
echo "profile: $PROFILE"
echo ""

# Make sure binary exists
if [ ! -x "$HIBROW" ]; then
    echo "$(red ERROR): binary not found at $HIBROW"
    echo "Run: zig build"
    exit 1
fi

# Clean slate: stop gateway if running, kill any test browser
$HIBROW gateway stop 2>/dev/null || true
sleep 0.5

# --------------------------------------------------------------------------
# Test: --help and --version
# --------------------------------------------------------------------------

echo "$(bold '==> CLI basics')"

out=$($HIBROW --help 2>&1)
assert_contains "$out" "Usage: hibrow" "--help shows usage"

out=$($HIBROW --version 2>&1)
assert_contains "$out" "hibrow" "--version shows version"

# --------------------------------------------------------------------------
# Test: gateway lifecycle
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Gateway lifecycle')"

# Status when not running
out=$($HIBROW gateway status 2>&1)
assert_contains "$out" "not running" "status shows not running when daemon is down"

# Launch a browser (implicitly starts gateway)
out=$($HIBROW launch $PROFILE 2>&1)
assert_contains "$out" "\"profile\"" "launch returns profile JSON"
assert_contains "$out" "\"port\"" "launch returns port"

# Gateway should now be running
out=$($HIBROW gateway status 2>&1)
assert_contains "$out" "running" "gateway status shows running after launch"

# --------------------------------------------------------------------------
# Test: browser listing
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Browser listing')"

out=$($HIBROW ls 2>&1)
assert_contains "$out" "$PROFILE" "ls shows test profile"

out=$($HIBROW ls $PROFILE 2>&1)
assert_contains "$out" "\"profile\"" "ls <profile> returns browser info"
assert_contains "$out" "$PROFILE" "ls <profile> shows correct profile name"

# --------------------------------------------------------------------------
# Test: duplicate launch detection
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Duplicate launch')"

out=$($HIBROW launch $PROFILE 2>&1)
assert_contains "$out" "already_running" "second launch detects already running"

# --------------------------------------------------------------------------
# Test: navigation (local pages only — no network requests)
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Navigation')"

out=$($HIBROW nav $PROFILE "about:blank" 2>&1)
assert_contains "$out" "navigated" "nav returns navigated status"

sleep 0.3

# --------------------------------------------------------------------------
# Test: eval
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> JavaScript evaluation')"

# Simple arithmetic
out=$($HIBROW eval $PROFILE "1 + 1" 2>&1)
assert_equals "$(echo "$out" | tr -d '[:space:]')" "2" "eval 1+1 returns 2"

# Inject a test page and read it back (proves DOM round-trip without network)
$HIBROW eval $PROFILE "
document.title = 'Hibrow Test Page';
const h1 = document.createElement('h1'); h1.textContent = 'Hibrow Test Page';
document.body.appendChild(h1);
'injected'
" > /dev/null 2>&1

# String result
out=$($HIBROW eval $PROFILE "document.title" 2>&1)
assert_contains "$out" "Hibrow Test Page" "eval document.title on injected page"

# DOM query
out=$($HIBROW eval $PROFILE "document.querySelector('h1').textContent" 2>&1)
assert_contains "$out" "Hibrow Test Page" "eval DOM query h1 text"

# Boolean
out=$($HIBROW eval $PROFILE "true" 2>&1)
assert_equals "$(echo "$out" | tr -d '[:space:]')" "true" "eval boolean true"

# Null
out=$($HIBROW eval $PROFILE "null" 2>&1)
assert_equals "$(echo "$out" | tr -d '[:space:]')" "null" "eval null"

# Object
out=$($HIBROW eval $PROFILE "({a: 1, b: 2})" 2>&1)
assert_contains "$out" "\"a\"" "eval object returns JSON with keys"

# Array
out=$($HIBROW eval $PROFILE "[1, 2, 3]" 2>&1)
assert_contains "$out" "1" "eval array returns JSON array"

# DOM mutation (verify it does not error)
out=$($HIBROW eval $PROFILE "document.body.style.backgroundColor = 'red'; 'ok'" 2>&1)
assert_contains "$out" "ok" "eval DOM mutation succeeds"

# Eval from stdin
out=$(echo "40 + 2" | $HIBROW eval $PROFILE -f- 2>&1)
assert_equals "$(echo "$out" | tr -d '[:space:]')" "42" "eval -f- reads from stdin"

# --------------------------------------------------------------------------
# Test: eval error handling
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Eval error handling')"

out=$($HIBROW eval $PROFILE "throw new Error('boom')" 2>&1) || true
assert_contains "$out" "Error" "eval throw returns error"

out=$($HIBROW eval $PROFILE "undefinedVariable.foo" 2>&1) || true
assert_contains "$out" "Error" "eval reference error returns error"

# --------------------------------------------------------------------------
# Test: navigate to second page and verify location
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Navigate and verify')"

$HIBROW nav $PROFILE "chrome://version" > /dev/null 2>&1
sleep 0.5

out=$($HIBROW eval $PROFILE "window.location.href" 2>&1)
assert_contains "$out" "chrome://version" "nav to chrome://version and verify location"

# --------------------------------------------------------------------------
# Test: url command
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> URL command')"

out=$($HIBROW url $PROFILE 2>&1)
assert_contains "$out" "chrome://version" "url returns current page URL"

# Navigate to about:blank and check url again
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

out=$($HIBROW url $PROFILE 2>&1)
assert_contains "$out" "about:blank" "url returns about:blank after nav"

# --------------------------------------------------------------------------
# Test: tab management
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Tab management')"

# List tabs — should show 1 tab
out=$($HIBROW tab list $PROFILE 2>&1)
assert_contains "$out" "index" "tab list returns tab info"
assert_contains "$out" "about:blank" "tab list shows current URL"

# Create a new tab
out=$($HIBROW tab new $PROFILE 2>&1)
assert_contains "$out" "created" "tab new returns created status"

sleep 0.5

# List tabs — should now show 2 tabs
out=$($HIBROW tab list $PROFILE 2>&1)
# Count the number of "index" occurrences to verify 2 tabs
tab_count=$(echo "$out" | grep -c '"index"')
if [ "$tab_count" -ge 2 ]; then
    pass "tab list shows 2 tabs after tab new"
else
    fail "tab list shows 2 tabs after tab new" "got $tab_count tabs"
fi

# Switch to tab 0 (first tab)
out=$($HIBROW tab switch $PROFILE:0 2>&1)
assert_contains "$out" "switched" "tab switch returns switched status"

sleep 0.3

# Close tab 1 (second tab)
out=$($HIBROW tab close $PROFILE:1 2>&1)
assert_contains "$out" "closed" "tab close returns closed status"

sleep 0.3

# List tabs — should be back to 1 tab
out=$($HIBROW tab list $PROFILE 2>&1)
tab_count=$(echo "$out" | grep -c '"index"')
if [ "$tab_count" -eq 1 ]; then
    pass "tab list shows 1 tab after closing second tab"
else
    fail "tab list shows 1 tab after closing second tab" "got $tab_count tabs"
fi

# --------------------------------------------------------------------------
# Test: eyeball with random hex — visual proof of real browser control
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Eyeball test (render SVG + read back random hex)')"

# Generate a random 6-char hex code in the shell. The browser never sees this
# until we inject it, then we read it back from the DOM to prove round-trip.
SECRET_HEX=$(head -c 3 /dev/urandom | xxd -p)

# Inject an animated eyeball SVG with the secret hex displayed underneath.
# The eyeball pupil follows a circular path via CSS animation.
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

$HIBROW eval $PROFILE "
document.body.style.cssText = 'margin:0;background:#111;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;overflow:hidden';

// --- eyeball SVG ---
const svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
svg.setAttribute('viewBox','0 0 200 200');
svg.setAttribute('width','300');
svg.setAttribute('height','300');
svg.innerHTML = \`
  <defs>
    <radialGradient id=\"eg\" cx=\"50%\" cy=\"40%\" r=\"50%\">
      <stop offset=\"0%\" stop-color=\"#fff\"/>
      <stop offset=\"100%\" stop-color=\"#ddd\"/>
    </radialGradient>
    <radialGradient id=\"ig\" cx=\"40%\" cy=\"35%\" r=\"50%\">
      <stop offset=\"0%\" stop-color=\"#4a9\"/>
      <stop offset=\"100%\" stop-color=\"#162\"/>
    </radialGradient>
  </defs>
  <!-- sclera -->
  <ellipse cx=\"100\" cy=\"100\" rx=\"90\" ry=\"70\" fill=\"url(#eg)\" stroke=\"#333\" stroke-width=\"3\"/>
  <!-- iris+pupil group that moves -->
  <g id=\"pupilGroup\">
    <circle cx=\"100\" cy=\"100\" r=\"30\" fill=\"url(#ig)\"/>
    <circle cx=\"100\" cy=\"100\" r=\"14\" fill=\"#000\"/>
    <circle cx=\"92\" cy=\"92\" r=\"5\" fill=\"rgba(255,255,255,0.7)\"/>
  </g>
\`;
document.body.appendChild(svg);

// --- CSS animation: pupil follows a circular path ---
const style = document.createElement('style');
style.textContent = \`
  @keyframes look {
    0%   { transform: translate(0px, 0px); }
    25%  { transform: translate(20px, -10px); }
    50%  { transform: translate(-15px, 5px); }
    75%  { transform: translate(10px, 15px); }
    100% { transform: translate(0px, 0px); }
  }
  #pupilGroup {
    animation: look 2s ease-in-out infinite;
    transform-origin: 100px 100px;
  }
\`;
document.head.appendChild(style);

// --- hex code label ---
const label = document.createElement('div');
label.id = 'secret-hex';
label.textContent = '${SECRET_HEX}';
label.style.cssText = 'margin-top:24px;font:bold 48px monospace;color:#0f0;text-shadow:0 0 20px #0f0;letter-spacing:8px';
document.body.appendChild(label);

'rendered'
" > /dev/null 2>&1

# Let the eyeball animate for a moment
sleep 1.5

# Now read the hex back from the DOM — this is the real test.
# We injected a random value the browser had never seen, rendered it,
# and now read it back. If this matches, the full pipeline is proven.
READBACK=$($HIBROW eval $PROFILE "document.getElementById('secret-hex').textContent" 2>&1 | tr -d '"[:space:]')

if [ "$READBACK" = "$SECRET_HEX" ]; then
    pass "eyeball rendered, hex $SECRET_HEX round-tripped through DOM"
else
    fail "hex round-trip: expected $SECRET_HEX, got $READBACK"
fi

# Bonus: read computed style to verify the animation is actually set
out=$($HIBROW eval $PROFILE "getComputedStyle(document.getElementById('pupilGroup')).animationName" 2>&1)
assert_contains "$out" "look" "eyeball pupil animation is active"

# --------------------------------------------------------------------------
# Test: kill browser (graceful close, profile preserved)
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Kill browser')"

out=$($HIBROW kill $PROFILE 2>&1)
assert_contains "$out" "killed" "kill returns killed"

sleep 1

# Browser should be gone from listing
out=$($HIBROW ls 2>&1)
if echo "$out" | grep -q "$PROFILE"; then
    fail "browser still listed after kill" "$out"
else
    pass "browser no longer listed after kill"
fi

# Profile directory should still exist
if [ -d "$HOME/.hibrow/profiles/$PROFILE" ]; then
    pass "profile directory preserved after kill"
else
    fail "profile directory was deleted by kill"
fi

# Relaunch should work (profile reuse)
out=$($HIBROW launch $PROFILE 2>&1)
assert_contains "$out" "\"profile\"" "relaunch after kill succeeds"

# Kill again for clean state before gateway stop test
$HIBROW kill $PROFILE > /dev/null 2>&1
sleep 0.5

# --------------------------------------------------------------------------
# Test: kill nonexistent browser
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Kill error handling')"

out=$($HIBROW kill nonexistent-profile 2>&1) || true
assert_contains "$out" "not found" "kill nonexistent profile returns error"

# --------------------------------------------------------------------------
# Test: gateway stop
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Gateway stop')"

out=$($HIBROW gateway stop 2>&1)
assert_contains "$out" "shutting_down" "gateway stop returns shutting_down"

sleep 1

out=$($HIBROW gateway status 2>&1)
assert_contains "$out" "not running" "gateway shows not running after stop"

# --------------------------------------------------------------------------
# Terminal summary
# --------------------------------------------------------------------------

echo ""
echo "────────────────────────────────"
echo "  $(bold 'Results'): $TOTAL tests, $(green "$PASS passed"), $([ $FAIL -gt 0 ] && red "$FAIL failed" || echo "$FAIL failed")"
echo "────────────────────────────────"
echo ""

# --------------------------------------------------------------------------
# Results display in browser
# --------------------------------------------------------------------------

# Build a JS-safe results array from the RESULTS bash array
RESULTS_JS="["
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"
    label="${r#*|}"
    # Escape single quotes in label
    label="${label//\'/\\\'}"
    RESULTS_JS+="['${status}','${label}'],"
done
RESULTS_JS+="]"

# Relaunch a browser to show results (the previous one was killed)
$HIBROW launch $PROFILE > /dev/null 2>&1
sleep 0.5
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

# Inject results page
$HIBROW eval $PROFILE "
const R = ${RESULTS_JS};
const pass = ${PASS}, fail = ${FAIL}, total = ${TOTAL};
const allPassed = fail === 0;

document.title = allPassed ? 'hibrow e2e: ALL PASSED' : 'hibrow e2e: FAILURES';

document.body.style.cssText = 'margin:0;padding:24px 32px;background:#111;color:#eee;font-family:-apple-system,system-ui,sans-serif;overflow-y:auto';

// Header
const h = document.createElement('div');
h.style.cssText = 'margin-bottom:20px';
h.innerHTML = '<h1 style=\"margin:0 0 8px;font-size:28px;color:#eee\">hibrow e2e results</h1>'
  + '<div style=\"font-size:18px\">'
  + '<span style=\"color:#4f4\">' + pass + ' passed</span>'
  + ' &middot; '
  + (fail > 0 ? '<span style=\"color:#f44\">' + fail + ' failed</span>' : '<span>' + fail + ' failed</span>')
  + ' &middot; '
  + total + ' total'
  + '</div>';
document.body.appendChild(h);

// Test list
const list = document.createElement('div');
list.style.cssText = 'margin-bottom:24px';
for (const [s, label] of R) {
  const row = document.createElement('div');
  row.style.cssText = 'padding:4px 0;font-size:14px;font-family:monospace';
  const dot = s === 'PASS' ? '\u2714' : '\u2718';
  const color = s === 'PASS' ? '#4f4' : '#f44';
  row.innerHTML = '<span style=\"color:' + color + ';margin-right:8px\">' + dot + '</span>' + label;
  list.appendChild(row);
}
document.body.appendChild(list);

// Footer: countdown or close button
const footer = document.createElement('div');
footer.style.cssText = 'padding-top:16px;border-top:1px solid #333';
document.body.appendChild(footer);

window._done = false;

if (allPassed) {
  let secs = 30;
  footer.innerHTML = '<span id=\"countdown\" style=\"font-size:16px;color:#888\">Auto-closing in ' + secs + '...</span>'
    + ' <button id=\"closebtn\" style=\"margin-left:12px;padding:6px 16px;background:#333;color:#eee;border:1px solid #555;border-radius:4px;cursor:pointer;font-size:14px\">Close now</button>';
  const cd = document.getElementById('countdown');
  const timer = setInterval(() => {
    secs--;
    if (secs <= 0) { clearInterval(timer); window._done = true; cd.textContent = 'Closing...'; return; }
    cd.textContent = 'Auto-closing in ' + secs + '...';
  }, 1000);
  document.getElementById('closebtn').onclick = () => { clearInterval(timer); window._done = true; };
} else {
  footer.innerHTML = '<button id=\"closebtn\" style=\"padding:6px 16px;background:#333;color:#eee;border:1px solid #555;border-radius:4px;cursor:pointer;font-size:14px\">Close</button>';
  document.getElementById('closebtn').onclick = () => { window._done = true; };
}

'results_rendered'
" > /dev/null 2>&1

# Poll window._done every second
for i in $(seq 1 60); do
    done_val=$($HIBROW eval $PROFILE "window._done" 2>&1 | tr -d '[:space:]') || true
    if [ "$done_val" = "true" ]; then
        break
    fi
    sleep 1
done

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------

# Kill test browser and stop gateway
$HIBROW kill $PROFILE > /dev/null 2>&1 || true
sleep 0.3
$HIBROW gateway stop > /dev/null 2>&1 || true

# Kill test browser if still running (belt and suspenders)
pkill -f "user-data-dir.*$PROFILE" 2>/dev/null || true

# Clean up test profile directory
rm -rf "$HOME/.hibrow/profiles/$PROFILE" 2>/dev/null || true

if [ $FAIL -gt 0 ]; then
    exit 1
fi
