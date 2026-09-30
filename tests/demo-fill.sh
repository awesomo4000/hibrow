#!/usr/bin/env bash
#
# hibrow demo — automated form filling
# Shows push (data injection) and screenshot (capture) capabilities
#
set -e

PROFILE="demo"
HIBROW="./zig-out/bin/hibrow"
DELAY=1.5

# --- Setup: create the form page ---
$HIBROW eval $PROFILE "
document.title = 'Acme Corp - New Employee Onboarding';
document.body.innerHTML = '<style>* { box-sizing: border-box; margin: 0; padding: 0; } body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f0f2f5; padding: 40px; } .container { max-width: 700px; margin: 0 auto; } h1 { color: #1a1a2e; margin-bottom: 8px; font-size: 28px; } .subtitle { color: #666; margin-bottom: 32px; font-size: 14px; } .card { background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); margin-bottom: 24px; } .card h2 { font-size: 18px; color: #333; margin-bottom: 20px; border-bottom: 2px solid #4361ee; padding-bottom: 8px; display: inline-block; } .form-row { display: flex; gap: 16px; margin-bottom: 16px; } .form-group { flex: 1; } label { display: block; font-size: 13px; font-weight: 600; color: #444; margin-bottom: 6px; } input, select, textarea { width: 100%; padding: 10px 14px; border: 1.5px solid #ddd; border-radius: 8px; font-size: 14px; transition: border-color 0.2s; } input:focus, select:focus, textarea:focus { outline: none; border-color: #4361ee; box-shadow: 0 0 0 3px rgba(67,97,238,0.1); } textarea { resize: vertical; min-height: 80px; } .status-bar { background: #1a1a2e; color: #4ade80; font-family: monospace; padding: 12px 20px; border-radius: 8px; font-size: 13px; margin-top: 24px; } .badge { display: inline-block; background: #4361ee; color: white; font-size: 11px; padding: 3px 8px; border-radius: 4px; margin-left: 8px; vertical-align: middle; }</style><div class=\"container\"><h1>New Employee Onboarding <span class=\"badge\">INTERNAL</span></h1><p class=\"subtitle\">HR Portal - Fill out all sections to complete onboarding</p><div class=\"card\"><h2>Personal Information</h2><div class=\"form-row\"><div class=\"form-group\"><label>First Name</label><input id=\"firstName\" placeholder=\"Enter first name\"></div><div class=\"form-group\"><label>Last Name</label><input id=\"lastName\" placeholder=\"Enter last name\"></div></div><div class=\"form-row\"><div class=\"form-group\"><label>Email</label><input id=\"email\" type=\"email\" placeholder=\"name@acmecorp.com\"></div><div class=\"form-group\"><label>Phone</label><input id=\"phone\" placeholder=\"(555) 000-0000\"></div></div></div><div class=\"card\"><h2>Role and Department</h2><div class=\"form-row\"><div class=\"form-group\"><label>Department</label><select id=\"department\"><option value=\"\">Select department...</option><option>Engineering</option><option>Design</option><option>Marketing</option><option>Sales</option><option>Operations</option></select></div><div class=\"form-group\"><label>Job Title</label><input id=\"jobTitle\" placeholder=\"e.g. Senior Software Engineer\"></div></div><div class=\"form-row\"><div class=\"form-group\"><label>Start Date</label><input id=\"startDate\" type=\"date\"></div><div class=\"form-group\"><label>Manager</label><input id=\"manager\" placeholder=\"Manager name\"></div></div></div><div class=\"card\"><h2>Additional Notes</h2><div class=\"form-group\"><label>Equipment / Access Requests</label><textarea id=\"notes\" placeholder=\"List any special equipment needs, software access, etc.\"></textarea></div></div><div class=\"status-bar\" id=\"statusBar\">hibrow :: ready - waiting for automation...</div></div>';
'ok'
" > /dev/null

status() {
    $HIBROW eval $PROFILE "document.getElementById('statusBar').textContent = 'hibrow :: $1'; 'ok'" > /dev/null
}

echo "=== hibrow Demo: Automated Form Filling ==="
echo ""
echo "Filling out employee onboarding form..."
echo ""

sleep 1

# --- Personal Information ---
status "filling: firstName"
echo "  -> First Name: Sarah"
$HIBROW push $PROFILE "#firstName" "Sarah"
sleep $DELAY

status "filling: lastName"
echo "  -> Last Name: Chen"
$HIBROW push $PROFILE "#lastName" "Chen"
sleep $DELAY

status "filling: email"
echo "  -> Email: sarah.chen@acmecorp.com"
$HIBROW push $PROFILE "#email" "sarah.chen@acmecorp.com"
sleep $DELAY

status "filling: phone"
echo "  -> Phone: (415) 555-0142"
$HIBROW push $PROFILE "#phone" "(415) 555-0142"
sleep $DELAY

# --- Role & Department ---
status "filling: department"
echo "  -> Department: Engineering"
$HIBROW eval $PROFILE "var s = document.getElementById('department'); s.value = 'Engineering'; s.dispatchEvent(new Event('change', {bubbles:true})); 'ok'" > /dev/null
sleep $DELAY

status "filling: jobTitle"
echo "  -> Job Title: Senior Platform Engineer"
$HIBROW push $PROFILE "#jobTitle" "Senior Platform Engineer"
sleep $DELAY

status "filling: startDate"
echo "  -> Start Date: 2026-05-12"
$HIBROW push $PROFILE "#startDate" "2026-05-12"
sleep $DELAY

status "filling: manager"
echo "  -> Manager: David Park"
$HIBROW push $PROFILE "#manager" "David Park"
sleep $DELAY

# --- Notes (multiline via stdin) ---
status "filling: notes (multiline)"
echo "  -> Notes: (multiline equipment request)"
cat <<'EOF' | $HIBROW push $PROFILE "#notes" -f-
- MacBook Pro 16" M4 Max
- 2x 32" 4K monitors
- Standing desk
- GitHub Enterprise access
- AWS IAM role: platform-eng
- Slack channels: #eng, #platform, #oncall
EOF
sleep $DELAY

# --- Final status ---
status "form complete - all fields populated"
echo ""
echo "=== Form filled! ==="
echo ""

# --- Screenshot the result ---
echo "Taking screenshot..."
$HIBROW screenshot $PROFILE -o /tmp/demo-filled-form.png
echo "  Saved: /tmp/demo-filled-form.png"
echo ""

# --- Read data back ---
echo "=== Reading back values (hibrow eval) ==="
echo ""
echo "  firstName:  $($HIBROW eval $PROFILE "document.getElementById('firstName').value")"
echo "  email:      $($HIBROW eval $PROFILE "document.getElementById('email').value")"
echo "  department: $($HIBROW eval $PROFILE "document.getElementById('department').value")"
echo "  jobTitle:   $($HIBROW eval $PROFILE "document.getElementById('jobTitle').value")"
echo "  startDate:  $($HIBROW eval $PROFILE "document.getElementById('startDate').value")"
echo "  manager:    $($HIBROW eval $PROFILE "document.getElementById('manager').value")"
echo "  notes:      $($HIBROW eval $PROFILE "document.getElementById('notes').value.split('\\n')[0]") ..."
echo ""
echo "=== Demo complete ==="
