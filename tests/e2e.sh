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

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  $(green PASS) $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
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
# Test: navigation
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Navigation')"

out=$($HIBROW nav $PROFILE "https://example.com" 2>&1)
assert_contains "$out" "navigated" "nav returns navigated status"

sleep 1  # let page load

# --------------------------------------------------------------------------
# Test: eval
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> JavaScript evaluation')"

# Simple arithmetic
out=$($HIBROW eval $PROFILE "1 + 1" 2>&1)
assert_equals "$(echo "$out" | tr -d '[:space:]')" "2" "eval 1+1 returns 2"

# String result
out=$($HIBROW eval $PROFILE "document.title" 2>&1)
assert_contains "$out" "Example Domain" "eval document.title on example.com"

# DOM query
out=$($HIBROW eval $PROFILE "document.querySelector('h1').textContent" 2>&1)
assert_contains "$out" "Example Domain" "eval DOM query h1 text"

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
# Test: navigate to different page and verify
# --------------------------------------------------------------------------

echo ""
echo "$(bold '==> Navigate and verify')"

$HIBROW nav $PROFILE "https://www.iana.org/help/example-domains" > /dev/null 2>&1
sleep 1

out=$($HIBROW eval $PROFILE "window.location.hostname" 2>&1)
assert_contains "$out" "iana.org" "nav to iana.org and verify hostname"

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
# Cleanup: kill the test browser (it survives gateway stop)
# --------------------------------------------------------------------------

# The browser process is still running since we detached it.
# Find and kill it by looking for our test profile in the user-data-dir.
pkill -f "user-data-dir.*$PROFILE" 2>/dev/null || true

# Clean up profile registry entry
if [ -f ~/.hibrow/profiles.json ]; then
    # Remove test profile entry (best effort)
    python3 -c "
import json, sys
try:
    with open('$HOME/.hibrow/profiles.json') as f:
        profiles = json.load(f)
    profiles = [p for p in profiles if p.get('name') != '$PROFILE']
    with open('$HOME/.hibrow/profiles.json', 'w') as f:
        json.dump(profiles, f)
except: pass
" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

echo ""
echo "────────────────────────────────"
echo "  $(bold 'Results'): $TOTAL tests, $(green "$PASS passed"), $([ $FAIL -gt 0 ] && red "$FAIL failed" || echo "$FAIL failed")"
echo "────────────────────────────────"
echo ""

if [ $FAIL -gt 0 ]; then
    exit 1
fi
