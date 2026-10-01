# hibrow skill — test battery

Deterministic eval suite for the hibrow skill. Each task is run by a fresh small
model (Haiku) that knows hibrow only from `hibrow --skill`, acting against the
local `fixture.html`. Every task stores its result in `window.__answer`; the
grader (`grade.sh`) reads it back and compares — objective pass/fail.

Metrics: **pass rate** (target 100%) and **tool calls per task** (minimize).

| id | profile | tests | task | expected `window.__answer` |
|----|---------|-------|------|----------------------------|
| T1 | ev1 | scrape text | Store the text of `#fact` in `window.__answer`. | `"The answer is 42."` |
| T2 | ev2 | table → JSON | Store the `#data` table as an array of `{Name, Score}` objects in `window.__answer`. | `[{Name:alice,Score:90},{bob,75},{carol,88}]` |
| T3 | ev3 | click + state | Click `#inc` exactly 3 times, then store the text of `#count` in `window.__answer`. | `"3"` (and `#count` reads `3`) |
| T4 | ev4 | React input gotcha | Put the text `hibrow` into the `#name` input so it commits, then store `window.__committed` in `window.__answer`. | `"hibrow"` (naive `.value=` fails) |
| T5 | ev5 | wait for element | Wait for `#late` to appear, then store its text in `window.__answer`. | `"loaded"` |
| T6 | ev6 | network capture | Install network capture, click `#load`, then store the captured request URL in `window.__answer`. | contains `data:application/json` |

Run: launch one headless Haiku per task against
`file://<repo>/evals/skill/fixture.html`, then `./grade.sh`.
