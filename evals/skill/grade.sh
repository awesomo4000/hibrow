#!/usr/bin/env bash
# Grade the hibrow skill test battery by reading window.__answer (and secondary
# state) from each task's browser profile. Objective pass/fail, no prose parsing.
#
# Usage: ./grade.sh [path-to-hibrow]
set -u
H="${1:-hibrow}"
pass=0; total=0

# hibrow eval already returns JSON; do NOT JSON.stringify again (double-encoding).
ans() { "$H" eval "$1" "window.__answer === undefined ? null : window.__answer" 2>/dev/null; }
check() { # check <id> <got> <predicate-desc> <0|1 ok>
  total=$((total+1))
  if [ "$4" = "1" ]; then pass=$((pass+1)); printf "PASS  %-3s %s\n" "$1" "$3";
  else printf "FAIL  %-3s %s  (got: %s)\n" "$1" "$3" "$2"; fi
}

# T1 scrape
g=$(ans ev1); [ "$g" = '"The answer is 42."' ] && ok=1 || ok=0
check T1 "$g" "fact text" "$ok"

# T2 table -> JSON (tolerate string/number scores; check name->score mapping)
g=$(ans ev2)
ok=$(printf '%s' "$g" | jq -e '
  (fromjson? // .) as $a |
  ($a|type=="array") and ($a|length==3) and
  (($a|map({(.Name|ascii_downcase):(.Score|tostring)})|add) ==
   {"alice":"90","bob":"75","carol":"88"})' >/dev/null 2>&1 && echo 1 || echo 0)
check T2 "$g" "table rows alice/90 bob/75 carol/88" "$ok"

# T3 click x3 -> count (answer is "3" or 3; also verify live #count)
g=$(ans ev3)
live=$("$H" eval ev3 "document.getElementById('count').textContent" 2>/dev/null)
{ [ "$g" = '"3"' ] || [ "$g" = '3' ]; } && [ "$live" = '"3"' ] && ok=1 || ok=0
check T3 "$g" "counter == 3 (live=$live)" "$ok"

# T4 React controlled input committed
g=$(ans ev4)
comm=$("$H" eval ev4 "window.__committed === undefined ? null : window.__committed" 2>/dev/null)
[ "$g" = '"hibrow"' ] && [ "$comm" = '"hibrow"' ] && ok=1 || ok=0
check T4 "$g" "input committed 'hibrow' (committed=$comm)" "$ok"

# T5 waited for #late
g=$(ans ev5); [ "$g" = '"loaded"' ] && ok=1 || ok=0
check T5 "$g" "delayed element text" "$ok"

# T6 captured network URL
g=$(ans ev6)
ok=$(printf '%s' "$g" | grep -q "data:application/json" && echo 1 || echo 0)
check T6 "$g" "captured fetch URL" "$ok"

echo "-----------------------------------------"
echo "PASS $pass / $total"
[ "$pass" = "$total" ]
