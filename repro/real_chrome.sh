#!/usr/bin/env bash
# Trigger matrix against real Chromium. Usage: repro/real_chrome.sh <hibrow-bin> <scenario>
#   idle-close   cached tab closed by someone else between evals (user closes window)
#   self-close   the eval itself closes its tab (window.close())
#   inflight     tab closed by someone else while an eval is running
#   relaunch     browser quit outside hibrow, relaunched with same profile/port
#   newtab-close agent opens a 2nd tab, user closes the 1st (cached) one
set -u
BIN=$1; SC=$2
CHROME=${CHROME:-/opt/pw-browsers/chromium-1243/chrome-linux64/chrome}
PORT=9600; PROFILE=realprof
WORK=$(mktemp -d); mkdir -p "$WORK/$PROFILE"
J="http://127.0.0.1:$PORT/json"

start_chrome() {
  "$CHROME" --headless=new --no-sandbox --disable-gpu --remote-debugging-port=$PORT \
    --user-data-dir="$WORK/$PROFILE" about:blank >/dev/null 2>&1 &
  CH=$!
  for _ in $(seq 50); do curl -sf "$J/version" >/dev/null && break; sleep 0.1; done
}
first_page() { curl -s "$J" | python3 -c 'import json,sys; print([t["id"] for t in json.load(sys.stdin) if t["type"]=="page"][0])'; }
alive() { kill -0 $GW 2>/dev/null; }

"$BIN" gateway stop >/dev/null 2>&1
start_chrome
"$BIN" gateway serve 2>"$WORK/gw.err" & GW=$!
trap 'kill $GW $CH 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 0.3

"$BIN" eval $PROFILE "document.title='first'; 1" >/dev/null   # cache conn to tab 0
TAB0=$(first_page)

case $SC in
  idle-close)   curl -s "$J/close/$TAB0" >/dev/null; sleep 0.3
                "$BIN" eval $PROFILE "2" ;;
  self-close)   "$BIN" eval $PROFILE "window.close(); 2"
                sleep 0.3; "$BIN" eval $PROFILE "3" ;;
  inflight)     ( sleep 0.5; curl -s "$J/close/$TAB0" >/dev/null ) &
                "$BIN" eval $PROFILE "const t=Date.now(); while(Date.now()-t<2000){}; 2" ;;
  relaunch)     kill $CH; wait $CH 2>/dev/null; start_chrome; sleep 0.3
                "$BIN" eval $PROFILE "2" ;;
  newtab-close) curl -s -X PUT "$J/new?about:blank" >/dev/null
                curl -s "$J/close/$TAB0" >/dev/null; sleep 0.3
                "$BIN" eval $PROFILE "2" ;;
esac
echo "eval exit=$?"
sleep 0.3
if alive; then echo "RESULT $SC: gateway alive"; else
  wait $GW; echo "RESULT $SC: gateway DIED status=$?"; grep -m1 -E "exception|panic|Segmentation" "$WORK/gw.err"; fi
