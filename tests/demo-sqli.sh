#!/usr/bin/env bash
#
# hibrow demo — SQL injection security testing
# Automated pen-test against a (simulated) vulnerable internal tool
#
set -e

PROFILE="demo"
HIBROW="./zig-out/bin/hibrow"
DELAY=2

# --- Setup: inject the app ---
$HIBROW eval $PROFILE "
document.title = 'Acme Corp - User Lookup (Internal Tool)';
document.body.innerHTML = '<style>* { box-sizing: border-box; margin: 0; padding: 0; } body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #1a1a2e; padding: 40px; color: #eee; } .container { max-width: 800px; margin: 0 auto; } h1 { color: #fff; margin-bottom: 4px; } .subtitle { color: #888; margin-bottom: 32px; font-size: 13px; } .card { background: #16213e; border: 1px solid #0f3460; border-radius: 12px; padding: 28px; margin-bottom: 20px; } .card h2 { font-size: 16px; color: #4cc9f0; margin-bottom: 16px; } .form-row { display: flex; gap: 12px; margin-bottom: 12px; align-items: end; } .form-group { flex: 1; } label { display: block; font-size: 12px; color: #aaa; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.5px; } input { width: 100%; padding: 10px 14px; background: #0f3460; border: 1px solid #1a4080; border-radius: 6px; color: #fff; font-size: 14px; font-family: monospace; } input:focus { outline: none; border-color: #4361ee; } button { padding: 10px 24px; background: #4361ee; color: white; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; font-weight: 600; } .response { background: #0a0a1a; border: 1px solid #333; border-radius: 8px; padding: 16px; font-family: monospace; font-size: 13px; white-space: pre-wrap; margin-top: 16px; display: none; max-height: 300px; overflow-y: auto; } .response.error { border-color: #e74c3c; color: #ff6b6b; } .response.success { border-color: #27ae60; color: #4ade80; } .log { background: #0a0a1a; border: 1px solid #333; border-radius: 8px; padding: 12px; font-family: monospace; font-size: 11px; color: #666; margin-top: 16px; max-height: 150px; overflow-y: auto; } .log-entry { margin-bottom: 4px; } .log-entry .time { color: #555; } .log-entry .query { color: #f0ad4e; } .badge { background: #e74c3c; color: white; font-size: 10px; padding: 2px 6px; border-radius: 3px; margin-left: 8px; }</style><div class=\"container\"><h1>User Lookup Tool <span class=\"badge\">STAGING</span></h1><p class=\"subtitle\">internal-tools.acmecorp.dev -- Connected to staging DB (PostgreSQL 14.2)</p><div class=\"card\"><h2>Search Users</h2><div class=\"form-row\"><div class=\"form-group\"><label>Username</label><input id=\"username\" placeholder=\"Enter username\"></div><div class=\"form-group\"><label>Email Filter</label><input id=\"emailFilter\" placeholder=\"Optional\"></div><div class=\"form-group\" style=\"flex:0\"><button id=\"searchBtn\" onclick=\"doSearch()\">Search</button></div></div><div class=\"response\" id=\"response\"></div></div><div class=\"card\"><h2>Query Log</h2><div class=\"log\" id=\"queryLog\"></div></div></div>';
'ok'
" > /dev/null

# Register the doSearch function (scripts in innerHTML don't execute)
$HIBROW eval $PROFILE "
window.doSearch = function() {
  var username = document.getElementById('username').value;
  var resp = document.getElementById('response');
  var log = document.getElementById('queryLog');
  var query = \"SELECT id, username, email, role FROM users WHERE username = '\" + username + \"'\";
  var now = new Date().toISOString().split('T')[1].split('.')[0];
  log.innerHTML += '<div class=\"log-entry\"><span class=\"time\">[' + now + ']</span> <span class=\"query\">' + query.replace(/</g,'&lt;') + '</span></div>';
  log.scrollTop = log.scrollHeight;
  resp.style.display = 'block';
  if (username.includes(\"'\")) {
    resp.className = 'response error';
    if (username.includes(\"' OR '\") || username.includes(\"' OR 1=1\")) {
      resp.textContent = 'ERROR: Query returned 847 rows (expected 0 or 1)\\nDETAIL: Unparameterized query detected. Full result set returned.\\n\\n id  | username      | email                    | role\\n-----+---------------+--------------------------+------------\\n   1 | admin         | admin@acmecorp.com       | superadmin\\n   2 | sarah.chen    | sarah@acmecorp.com       | admin\\n   3 | david.park    | dpark@acmecorp.com       | admin\\n   4 | jsmith        | jsmith@acmecorp.com      | user\\n   5 | test_account  | test@test.com            | user\\n ... | (842 more)    |                          |\\n\\nWARNING: Full table scan performed. No row-level security applied.';
    } else if (username.toUpperCase().includes('UNION')) {
      resp.textContent = 'ERROR: each UNION query must have the same number of columns\\nLINE 1: ' + query.substring(0,70) + '...\\nDETAIL: UNION target has 4 columns but subquery returns different count\\nHINT: Schema info exposed via information_schema\\nWARNING: pg_hba.conf allows cleartext password transmission';
    } else if (username.includes('--') || username.includes(';')) {
      resp.textContent = 'ERROR: unterminated quoted string at or near...\\nSTATEMENT: ' + query.substring(0,80) + '\\n\\nNOTICE: current transaction is aborted, commands ignored until end of transaction\\nWARNING: Multiple statements detected in single query execution';
    } else {
      resp.textContent = 'ERROR: syntax error at or near \"' + username.split(\"'\")[1].substring(0,20) + '\"\\nLINE 1: ' + query.substring(0,70) + '...';
    }
  } else if (username === 'admin') {
    resp.className = 'response success';
    resp.textContent = ' id | username | email              | role\\n----+----------+--------------------+------------\\n  1 | admin    | admin@acmecorp.com | superadmin\\n\\n(1 row)';
  } else if (username) {
    resp.className = 'response success';
    resp.textContent = '(0 rows)\\n\\nNo user found matching: ' + username;
  } else {
    resp.className = 'response error';
    resp.textContent = 'ERROR: username parameter is required';
  }
};
'ready'
" > /dev/null

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  hibrow Security Test — SQL Injection Detection         ║"
echo "║  Target: internal-tools.acmecorp.dev (staging)          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Test 1: Normal query (baseline)
echo "━━━ Test 1: Baseline — normal lookup ━━━"
$HIBROW push $PROFILE "#username" "admin"
RESULT=$($HIBROW eval $PROFILE "doSearch(); document.getElementById('response').textContent.split('\\n')[0]")
echo "  Input:    admin"
echo "  Response: $RESULT"
echo "  Status:   ✓ Normal — single row returned"
echo ""
sleep $DELAY

# Test 2: Basic SQL injection — tautology
echo "━━━ Test 2: Tautology attack ( ' OR '1'='1 ) ━━━"
$HIBROW push $PROFILE "#username" "' OR '1'='1"
RESULT=$($HIBROW eval $PROFILE "doSearch(); document.getElementById('response').textContent.split('\\n')[0]")
echo "  Input:    ' OR '1'='1"
echo "  Response: $RESULT"
echo "  Status:   ⚠️  VULNERABLE — dumped entire users table!"
echo ""
sleep $DELAY

# Test 3: UNION-based injection
echo "━━━ Test 3: UNION injection (schema extraction) ━━━"
PAYLOAD="' UNION SELECT table_name,null,null,null FROM information_schema.tables--"
$HIBROW push $PROFILE "#username" "$PAYLOAD"
RESULT=$($HIBROW eval $PROFILE "doSearch(); document.getElementById('response').textContent.split('\\n')[0]")
echo "  Input:    $PAYLOAD"
echo "  Response: $RESULT"
echo "  Status:   ⚠️  VULNERABLE — schema leakage via UNION"
echo ""
sleep $DELAY

# Test 4: Statement termination / DROP TABLE
echo "━━━ Test 4: Statement termination (DROP TABLE) ━━━"
$HIBROW push $PROFILE "#username" "admin'; DROP TABLE users;--"
RESULT=$($HIBROW eval $PROFILE "doSearch(); document.getElementById('response').textContent.split('\\n')[0]")
echo "  Input:    admin'; DROP TABLE users;--"
echo "  Response: $RESULT"
echo "  Status:   ⚠️  VULNERABLE — multi-statement execution"
echo ""
sleep $DELAY

# Screenshot the evidence
echo "━━━ Capturing Evidence ━━━"
$HIBROW screenshot $PROFILE -o /tmp/demo-sqli-evidence.png
echo "  Screenshot: /tmp/demo-sqli-evidence.png"
echo ""

# Print the query log
echo "━━━ Executed Queries (from app log) ━━━"
$HIBROW eval $PROFILE "document.getElementById('queryLog').innerText"
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  RESULTS: 3/3 injection vectors SUCCESSFUL              ║"
echo "║  SEVERITY: CRITICAL                                     ║"
echo "║                                                         ║"
echo "║  Issues found:                                          ║"
echo "║   • String concatenation in SQL (no parameterization)   ║"
echo "║   • Full table dump via tautology                       ║"
echo "║   • Schema exposure via UNION                           ║"
echo "║   • Multi-statement execution (DROP TABLE possible)     ║"
echo "║                                                         ║"
echo "║  Remediation:                                           ║"
echo "║   • Use prepared statements / parameterized queries     ║"
echo "║   • Add input validation (reject special chars)         ║"
echo "║   • Enable WAF SQL injection rules                      ║"
echo "║   • Apply principle of least privilege to DB user        ║"
echo "╚══════════════════════════════════════════════════════════╝"
