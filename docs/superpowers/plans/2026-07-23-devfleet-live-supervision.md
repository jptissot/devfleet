# DevFleet Live Supervision Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Phase-1 pipeline run *unattended* — a zero-token bash watcher that reacts to completion markers, detects dead/stuck/stalled/looping local agents, restarts a stage once then parks, keeps a liveness beacon, and reconciles state on restart.

**Architecture:** A new sourced lib `fleet-watch-lib` (worktree hashing + stall/cycle/budget predicates, all pure and time-parameterized) plus three entrypoints: `fleet-watch` (a poll loop of idempotent *ticks*), `fleet-session-start` (reconcile missions vs live terminals, restart the watcher), and `fleet-turnend-guard` (a Stop-hook that refuses to end the Commander's turn while missions are in flight but the beacon is dead). The watcher never advances stages itself — it calls the Phase-1 `fleet-advance`, which is hardened here to be idempotent via a per-mission marker cursor.

**Tech Stack:** Bash, `jq`, `git` (worktree state hashing), `bats-core` 1.12, `shellcheck`. Orca is stubbed by an upgraded, response-programmable fake `orca` on `PATH`. No real Orca, LLM, or containers in tests.

**Builds on:** Plan 1 (`docs/superpowers/plans/2026-07-23-devfleet-core-pipeline.md`) — all its scripts/libs/tests exist and pass. This plan **modifies** `bin/fleet-mission`, `bin/fleet-done`, `bin/fleet-advance`, `bin/fleet-spawn`, `bin/fleet-backend`, `bin/fleet-pipeline`, and `tests/helpers/common.bash`, and **adds** `bin/fleet-watch-lib`, `bin/fleet-watch`, `bin/fleet-session-start`, `bin/fleet-turnend-guard`.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md` — sections "Supervision: `fleet-watch`", "Loop/stall monitoring", "Turn-end guard", "Error handling". Reference predecessor: `~/repos/kenchenguid/firstmate` (`fm-watch.sh`, `fm-supervise-daemon.sh` for the poll+hash idiom — but DevFleet's is far smaller; do NOT port the away-mode daemon tree, a spec non-goal).

**Out of scope (later plans):** decision inbox + `fleet-decide` + day-mode Commander `fleet-wake` (Plan 3 — this plan uses "park, don't ping" for every anomaly, no wake); ship, night, bunkers, axi.

## Global Constraints

- Same conventions as Plan 1 (see its Global Constraints): `#!/usr/bin/env bash`; entrypoints `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; `fleet_<area>_<verb>()` names; `*_OVERRIDE` env roots; all JSON via `jq`; `shellcheck bin/*` and `bats tests/` green after every task.
- **Idempotency is the law of this plan:** every tick and every `fleet-advance` call must be safe to repeat. A tick that finds nothing new must mutate nothing.
- **Time is injectable:** stall/budget thresholds come from `${FLEET_STALL_SECONDS:-900}` and `${FLEET_BUDGET_SECONDS:-2700}` (spec defaults: stall 15 min, execute budget 45 min). "Now" is read once per tick via `date +%s`; tests inject timestamps into mission state, never sleep real minutes.
- **Zero tokens idle:** the watcher only runs bash + `jq` + `git` + `orca` reads. No LLM calls anywhere in this plan.
- **Anomaly policy (spec "Loop/stall monitoring"):** first anomaly on a stage → restart that stage once (fresh spawn), bump `restarts`. Second anomaly (already restarted) → `parked`. Restarts reset to 0 when a mission enters a new stage.

## Data model additions (mission.json)

Added by Task 1/2, written by `fleet-mission` and maintained by `fleet-advance`/`fleet-watch`:

- `marker_cursor` (int, default 0) — number of marker lines `fleet-advance` has consumed.
- `stage_started_at` (epoch int) — when the current stage began (budget clock).
- `last_progress_at` (epoch int) — last time the worktree hash changed (stall clock).
- `state_hash` (string) — last observed worktree hash.
- `restarts` (int, already present) — restarts of the *current* stage; reset to 0 on stage entry.
- `last_stage` (string, default `""`) — the last *pipeline* stage the mission actually ran, recorded by `fleet-advance` before any transition. Because a terminal outcome overwrites `.stage` with `ready`/`parked`/`blocked`/`done`/`failed` (spec's combined mission-state field), `.last_stage` is what preserves *where* the mission stopped, for the Commander/resume in Plan 3 (review Finding 5).

**JSON write safety (review Finding 3):** string values written into `mission.json` go through a new `fleet_json_set_str <file> <jq-path> <value>` helper that passes the value as a jq `--arg` (data, never program text) — so a value containing `"` or `\` can never break the filter. Numeric/computed assignments (integers, epoch, ISO dates — all quote-free and trusted) keep using `fleet_json_set`.

Per-mission files (in `state/missions/<id>/`): `hashes` (append-only worktree-hash history, for cycle detection).

## File Structure (delta from Plan 1)

```
bin/
  fleet-watch-lib      # NEW sourced lib: hash, stall, cycle, budget predicates
  fleet-watch          # NEW entrypoint: tick (one pass) + daemon loop + beacon
  fleet-session-start  # NEW entrypoint: reconcile missions vs live terminals, (re)start watcher
  fleet-turnend-guard  # NEW entrypoint: Stop-hook decision (in-flight + dead beacon -> block)
  fleet-mission        # MODIFIED: init marker_cursor/timers
  fleet-done           # MODIFIED: add fleet_done_count
  fleet-advance        # MODIFIED: honor marker_cursor (idempotent); set stage timers/reset restarts
  fleet-spawn          # MODIFIED: safe brief rendering (no sed injection); quote brief path
  fleet-backend        # MODIFIED: add terminal_exists + terminal_state (satisfied/blocked/exit)
  fleet-pipeline       # MODIFIED: add fleet_pipeline_is_stage
state/
  .watch-beacon        # NEW: watcher heartbeat (epoch, rewritten each tick)
tests/
  helpers/common.bash  # MODIFIED: programmable fake orca (terminal wait/read env-driven) + git-worktree helper
  fleet-spawn.bats     # MODIFIED: add metachar-in-desc case
  fleet-advance.bats   # MODIFIED: add idempotency case
  fleet-watch-lib.bats # NEW
  fleet-watch.bats     # NEW
  fleet-session-start.bats # NEW
  fleet-turnend-guard.bats # NEW
  fleet-e2e.bats       # MODIFIED: add watcher-driven + stall->restart->park scenarios
```

---

### Task 1: Fix brief rendering (review Finding 2)

**Files:**
- Modify: `bin/fleet-spawn:44-52`
- Test: `tests/fleet-spawn.bats` (add a case)

**Interfaces:** unchanged. `fleet-spawn` still renders `<worktree>/.devfleet/<id>.<stage>.brief`; it must now survive any characters in the description/worktree path.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-spawn.bats`:

```bash
@test "brief renders safely with shell/sed metacharacters in --desc" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc 'add a|b & c\d' --id m9 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission m9 --stage spec --dry-run
  [ "$status" -eq 0 ]
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m9/mission.json")"
  grep -qF 'add a|b & c\d' "$wt/.devfleet/m9.spec.brief"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/fleet-spawn.bats -f "metacharacters"`
Expected: FAIL — spawn exits non-zero / the literal `add a|b & c\d` is not found (sed mangled it).

- [ ] **Step 3: Replace the sed render with a literal, injection-proof substitution**

In `bin/fleet-spawn`, replace lines 44-52 (the `sed -e ... > "$brief"` block and the footer append) with a `jq`-based literal substitution (jq treats values as data, never as a program):

```bash
# Render brief with LITERAL substitution (no sed program injection): jq reads the
# template as raw text and gsubs each placeholder with an --arg value verbatim.
brief="$WT/.devfleet/$MISSION.$STAGE.brief"
mkdir -p "$(dirname "$brief")"
jq -rn --rawfile tmpl "$tmpl" \
  --arg mid "$MISSION" --arg desc "$DESC" --arg wt "$WT" \
  '$tmpl
   | gsub("\\{mission_id\\}"; $mid)
   | gsub("\\{description\\}"; $desc)
   | gsub("\\{worktree\\}"; $wt)' > "$brief"
{
  printf '\nWhen finished, run: fleet-done %s <status>\n' "$MISSION"
  printf '  status is one of: done | blocked:<question> | failed:<reason>\n'
} >> "$brief"
```

Also quote the brief path in the launch command (review Finding 4) — change the `LAUNCH=` line to:

```bash
LAUNCH="$CMD \"\$(cat \"$brief\")\""
```

- [ ] **Step 4: Run the spawn suite**

Run: `bats tests/fleet-spawn.bats`
Expected: PASS (all prior cases + the new one). `gsub` with a literal `--arg` cannot be broken by `|`, `&`, `\`, or newlines in the value.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-spawn
git add bin/fleet-spawn tests/fleet-spawn.bats
git commit -m "fix: injection-proof brief rendering (jq gsub, not sed)"
```

---

### Task 2: `fleet-advance` idempotency via marker cursor (review Finding 1)

**Files:**
- Modify: `bin/fleet-mission` (init new fields)
- Modify: `bin/fleet-done` (add `fleet_done_count`)
- Modify: `bin/fleet-advance` (honor cursor; set stage timers; reset restarts on stage entry)
- Test: `tests/fleet-advance.bats` (add idempotency case)

**Interfaces:**
- Produces: `fleet_done_count <id>` — number of lines in the mission's `.status` marker (0 if absent).
- Produces: `fleet_json_set_str <file> <jq-path> <value>` (in `fleet-common`) — set a string field safely via jq `--arg` (review Finding 3).
- `fleet-advance <id>` is now a **no-op** (prints the unchanged stage, exits 0) when `fleet_done_count <= .marker_cursor`. On a real transition it records `.last_stage` = the stage it just processed (review Finding 5), sets `.marker_cursor` to the current count, and — whenever it enters a new pipeline stage — sets `.stage_started_at`/`.last_progress_at` to now, `.restarts` to 0, `.state_hash` to `""`. All string writes use `fleet_json_set_str`.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-advance.bats`:

```bash
@test "advance is idempotent: second call with no new marker is a no-op" {
  mk campaign m010
  "$REPO_ROOT/bin/fleet-done" m010 done
  run "$REPO_ROOT/bin/fleet-advance" m010
  [ "$(stage_of m010)" = "plan" ]
  run "$REPO_ROOT/bin/fleet-advance" m010     # no new marker
  [ "$status" -eq 0 ]
  [ "$(stage_of m010)" = "plan" ]             # MUST NOT jump to execute
}

@test "entering a stage resets restarts and sets timers" {
  mk campaign m011
  jq '.restarts=2' "$FLEET_STATE_OVERRIDE/missions/m011/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  "$REPO_ROOT/bin/fleet-done" m011 done
  "$REPO_ROOT/bin/fleet-advance" m011 >/dev/null
  mj="$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  [ "$(jq -r .restarts "$mj")" = "0" ]
  [ "$(jq -r .stage_started_at "$mj")" != "null" ]
  [ "$(jq -r .marker_cursor "$mj")" = "1" ]
}

@test "last_stage preserves where the mission stopped (Finding 5)" {
  mk campaign m012
  "$REPO_ROOT/bin/fleet-done" m012 done
  "$REPO_ROOT/bin/fleet-advance" m012 >/dev/null        # spec done -> plan
  [ "$(jq -r .last_stage "$FLEET_STATE_OVERRIDE/missions/m012/mission.json")" = "spec" ]
  # jump to review, PASS -> ready; last_stage must remember "review"
  jq '.stage="review"' "$FLEET_STATE_OVERRIDE/missions/m012/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m012/mission.json"
  echo '{"result":"PASS","findings":[]}' > "$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m012/mission.json")/findings.json"
  "$REPO_ROOT/bin/fleet-done" m012 done
  "$REPO_ROOT/bin/fleet-advance" m012 >/dev/null
  mj="$FLEET_STATE_OVERRIDE/missions/m012/mission.json"
  [ "$(jq -r .stage "$mj")" = "ready" ]
  [ "$(jq -r .last_stage "$mj")" = "review" ]
}

@test "fleet_json_set_str is injection-proof for values with quotes (Finding 3)" {
  f="$FLEET_TMP/j.json"; echo '{}' > "$f"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_json_set_str "'"$f"'" ".x" "a\"b\\c"; jq -r .x "'"$f"'"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'a"b\c' ]]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats tests/fleet-advance.bats -f "idempotent"`
Expected: FAIL — the second advance jumps to `execute` (the reproduced Finding 1).

- [ ] **Step 3: Add `fleet_done_count` to `bin/fleet-done` and `fleet_json_set_str` to `bin/fleet-common`**

In `bin/fleet-done`, insert after `fleet_done_latest` (before the entrypoint guard):

```bash
fleet_done_count() {  # <id> -> number of marker lines (0 if none)
  local marker
  marker="$(fleet_done_marker "$1")"
  [ -f "$marker" ] || { printf '0'; return 0; }
  wc -l < "$marker" | tr -d ' '
}
```

In `bin/fleet-common`, add next to `fleet_json_set` (review Finding 3 — string values via `--arg`, never interpolated into the jq program):

```bash
fleet_json_set_str() {  # <file> <jq-path> <string-value>
  local f=$1 path=$2 val=$3 tmp
  tmp="$(mktemp)"
  jq --arg v "$val" "$path=\$v" "$f" > "$tmp" && mv "$tmp" "$f"
}
```

- [ ] **Step 4: Init the new fields in `bin/fleet-mission`**

In the `jq -n` object (bin/fleet-mission:43-47), add the four fields. Replace the object body so it reads:

```bash
  '{id:$id,type:$type,project:$project,repo:$repo,description:$desc,stage:$stage,last_stage:$stage,
    fix_round:0,restarts:0,marker_cursor:0,
    stage_started_at:($now_epoch|tonumber),last_progress_at:($now_epoch|tonumber),state_hash:"",
    worktree_path:$wt,orca_worktree_id:$wtid,terminal:null,
    artifacts:({} + (if $spec!="" then {spec:$spec} else {} end)
                  + (if $issue!="" then {issue:$issue} else {} end)),
    created_at:$now,updated_at:$now}' \
```

and add `--arg now_epoch "$(date +%s)"` to the `jq -n` arg list (next to `--arg now`).

- [ ] **Step 5: Make `bin/fleet-advance` honor the cursor and set stage timers**

After the `fleet_roots` line and the mission reads, add the cursor guard. Insert right before `verb="$(fleet_done_latest ...)"`:

```bash
COUNT="$(fleet_done_count "$ID")"
CURSOR="$(fleet_json_get "$mj" '.marker_cursor')"
if [ "$COUNT" -le "$CURSOR" ]; then
  printf '%s\n' "$STAGE"     # no new marker -> no-op (idempotent for the watcher)
  exit 0
fi
fleet_json_set_str "$mj" '.last_stage' "$STAGE"   # preserve where we stopped (Finding 5)
```

Change the `set_stage` helper to write `.stage` via the safe setter (review Finding 3) — replace its definition with:

```bash
set_stage() { fleet_json_set_str "$mj" '.stage' "$1"; fleet_json_set "$mj" ".updated_at=\"$now\""; }
```

Change `spawn()` to also stamp stage-entry state (new stage begins => reset restarts, timers, hash):

```bash
spawn() {  # <stage>
  local now_epoch; now_epoch="$(date +%s)"
  fleet_json_set "$mj" ".restarts=0 | .stage_started_at=$now_epoch | .last_progress_at=$now_epoch | .state_hash=\"\""
  "$SCRIPT_DIR/fleet-spawn" --mission "$ID" --stage "$1" >/dev/null
}
```

At the very end (before the final `printf`), record the consumed cursor:

```bash
fleet_json_set "$mj" ".marker_cursor=$COUNT"
```

- [ ] **Step 6: Run the advance suite and the whole suite**

Run: `bats tests/fleet-advance.bats && bats tests/`
Expected: PASS. Existing tests still pass (they call advance once per marker); the new idempotency + timer cases pass.

- [ ] **Step 7: Lint and commit**

```bash
shellcheck bin/fleet-advance bin/fleet-mission bin/fleet-done bin/fleet-common
git add bin/fleet-advance bin/fleet-mission bin/fleet-done bin/fleet-common tests/fleet-advance.bats
git commit -m "fix: advance idempotency + last_stage (F5) + json_set_str safe writes (F3)"
```

---

### Task 3: Backend + pipeline read extensions

**Files:**
- Modify: `bin/fleet-backend` (add `fleet_backend_terminal_exists`, `fleet_backend_terminal_state`)
- Modify: `bin/fleet-pipeline` (add `fleet_pipeline_is_stage`)
- Modify: `tests/helpers/common.bash` (programmable fake orca; git-worktree helper)
- Test: `tests/fleet-backend.bats` (add cases)

**Interfaces:**
- Produces:
  - `fleet_backend_terminal_exists <handle>` — returns 0 iff `orca terminal read` succeeds for the handle (endpoint present). Mirrors firstmate:bin/fm-backend.sh:683-686 (orca arm uses a bounded read).
  - `fleet_backend_terminal_state <handle> <timeout-ms>` — prints `<satisfied>\t<blockedReason>\t<exitCode>` from `orca terminal wait --for tui-idle`.
  - `fleet_pipeline_is_stage <type> <stage>` — returns 0 iff `<stage>` is a `.stages[].name` in the type's graph (i.e., an in-flight pipeline stage, not a terminal mission state like `ready`/`parked`).

- [ ] **Step 1: Upgrade the fake orca and add a git-worktree helper**

In `tests/helpers/common.bash`, replace the `terminal wait`/`terminal read` arms of the fake `orca` heredoc so they honor env overrides, and add a git-worktree helper. Change the two lines inside the `case` for wait/read to:

```bash
  "terminal wait")
    printf '{"result":{"wait":{"satisfied":%s,"status":"running","blockedReason":%s,"exitCode":%s}}}\n' \
      "${FLEET_FAKE_SAT:-true}" "${FLEET_FAKE_BLOCKED:-null}" "${FLEET_FAKE_EXIT:-null}" ;;
  "terminal read")
    if [ "${FLEET_FAKE_TERM_GONE:-0}" = "1" ]; then exit 1; fi
    printf '{"result":{"terminal":{"tail":[]}}}\n' ;;
```

(`FLEET_FAKE_BLOCKED`/`FLEET_FAKE_EXIT` must be valid JSON — a test sets e.g. `FLEET_FAKE_BLOCKED='"codex-trust-workspace"'` or `FLEET_FAKE_EXIT=0`.)

Append a git-worktree helper (real git repo so hashing is faithful):

```bash
# Make $1 a real git repo with one commit; echo nothing. Used for hash tests.
fleet_git_init() {  # <dir>
  git -C "$1" init -q
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  echo seed > "$1/seed.txt"; git -C "$1" add -A; git -C "$1" commit -qm seed
}
```

- [ ] **Step 2: Write the failing test**

Add to `tests/fleet-backend.bats`:

```bash
@test "terminal_exists reflects the fake gone flag" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_1'
  [ "$status" -eq 0 ]
  FLEET_FAKE_TERM_GONE=1 run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_1'
  [ "$status" -ne 0 ]
}

@test "terminal_state emits satisfied/blocked/exit" {
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"codex-trust-workspace"' \
    run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_state term_1 5000'
  [ "$status" -eq 0 ]
  [[ "$output" == "false"$'\t'"codex-trust-workspace"$'\t'"null" ]]
}
```

Add to `tests/fleet-pipeline.bats`:

```bash
@test "is_stage recognizes graph stages, rejects terminal states" {
  run pl 'fleet_pipeline_is_stage campaign execute'; [ "$status" -eq 0 ]
  run pl 'fleet_pipeline_is_stage campaign ready';   [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bats tests/fleet-backend.bats tests/fleet-pipeline.bats`
Expected: FAIL — the three functions don't exist.

- [ ] **Step 4: Implement**

Append to `bin/fleet-backend`:

```bash
fleet_backend_terminal_exists() {  # <handle>
  orca terminal read --terminal "$1" --json >/dev/null 2>&1
}

fleet_backend_terminal_state() {  # <handle> <timeout-ms> -> "<satisfied>\t<blocked>\t<exit>"
  local out
  out="$(orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$2" --json)" || return 1
  printf '%s\t%s\t%s' \
    "$(printf '%s' "$out" | jq -r '.result.wait.satisfied')" \
    "$(printf '%s' "$out" | jq -r '.result.wait.blockedReason')" \
    "$(printf '%s' "$out" | jq -r '.result.wait.exitCode')"
}
```

Append to `bin/fleet-pipeline`:

```bash
fleet_pipeline_is_stage() {  # <type> <stage>  -> 0 if stage is a graph stage
  local hit
  hit="$(jq -r --arg s "$2" 'any(.stages[]; .name==$s)' "$(fleet_pipeline_file "$1")")"
  [ "$hit" = "true" ]
}
```

- [ ] **Step 5: Run to verify pass; lint; commit**

```bash
bats tests/fleet-backend.bats tests/fleet-pipeline.bats
shellcheck bin/fleet-backend bin/fleet-pipeline
git add bin/fleet-backend bin/fleet-pipeline tests/helpers/common.bash tests/fleet-backend.bats tests/fleet-pipeline.bats
git commit -m "feat: backend terminal_exists/terminal_state + pipeline is_stage + programmable fake orca"
```

---

### Task 4: `fleet-watch-lib` (hash + stall/cycle/budget predicates)

**Files:**
- Create: `bin/fleet-watch-lib`
- Test: `tests/fleet-watch-lib.bats`

**Interfaces:**
- Produces (all pure; no mutation; time passed in as args):
  - `fleet_watch_hash <worktree>` — prints a stable hash of `git status --porcelain` + `git diff` (empty-but-deterministic for a non-git dir).
  - `fleet_watch_stalled <old_hash> <new_hash> <last_progress_epoch> <now_epoch> <stall_seconds>` — returns 0 (stalled) iff `new==old` and `now-last_progress >= stall_seconds`.
  - `fleet_watch_cycle <hashes_file> <new_hash>` — appends `<new_hash>` to `<hashes_file>`, then returns 0 iff the last three form `A,B,A` (edit-revert loop): new equals the entry two-back and differs from the entry one-back.
  - `fleet_watch_over_budget <stage_started_epoch> <now_epoch> <budget_seconds>` — returns 0 iff `now-stage_started >= budget_seconds`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-watch-lib.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

wl() { bash -c '. "$REPO_ROOT/bin/fleet-watch-lib"; '"$1"; }

@test "hash is stable and changes with content" {
  d="$FLEET_TMP/wt"; mkdir -p "$d"; fleet_git_init "$d"
  h1="$(wl 'fleet_watch_hash "'"$d"'"')"
  h2="$(wl 'fleet_watch_hash "'"$d"'"')"
  [ "$h1" = "$h2" ]
  echo change >> "$d/seed.txt"
  h3="$(wl 'fleet_watch_hash "'"$d"'"')"
  [ "$h1" != "$h3" ]
}

@test "stalled only when unchanged AND past the threshold" {
  run wl 'fleet_watch_stalled A A 100 1000 900'; [ "$status" -eq 0 ]   # 900s elapsed, same hash
  run wl 'fleet_watch_stalled A A 100 200 900';  [ "$status" -ne 0 ]   # only 100s
  run wl 'fleet_watch_stalled A B 100 1000 900'; [ "$status" -ne 0 ]   # hash changed
}

@test "cycle detects A,B,A edit-revert" {
  f="$FLEET_TMP/h"
  wl 'fleet_watch_cycle "'"$f"'" A' || true
  wl 'fleet_watch_cycle "'"$f"'" B' || true
  run wl 'fleet_watch_cycle "'"$f"'" A'      # A,B,A
  [ "$status" -eq 0 ]
}

@test "over_budget past the cap" {
  run wl 'fleet_watch_over_budget 0 2700 2700'; [ "$status" -eq 0 ]
  run wl 'fleet_watch_over_budget 0 100 2700';  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-watch-lib.bats`
Expected: FAIL — `bin/fleet-watch-lib` missing.

- [ ] **Step 3: Write `bin/fleet-watch-lib`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-watch-lib - pure predicates for effect-level loop/stall detection
# (spec "Loop/stall monitoring"). No mutation except cycle's history append.
# Time is always passed in; nothing here reads the clock.

fleet_watch_hash() {  # <worktree> -> stable hash of working-tree state
  { git -C "$1" status --porcelain 2>/dev/null; git -C "$1" diff 2>/dev/null; } \
    | sha256sum | cut -d' ' -f1
}

fleet_watch_stalled() {  # <old> <new> <last_progress_epoch> <now_epoch> <stall_seconds>
  [ "$2" = "$1" ] || return 1
  [ "$(( $4 - $3 ))" -ge "$5" ]
}

fleet_watch_cycle() {  # <hashes_file> <new_hash>  (appends; detects A,B,A tail)
  printf '%s\n' "$2" >> "$1"
  local n a b c
  n="$(wc -l < "$1")"
  [ "$n" -ge 3 ] || return 1
  c="$2"
  b="$(sed -n "$((n-1))p" "$1")"
  a="$(sed -n "$((n-2))p" "$1")"
  [ "$c" = "$a" ] && [ "$c" != "$b" ]
}

fleet_watch_over_budget() {  # <stage_started_epoch> <now_epoch> <budget_seconds>
  [ "$(( $2 - $1 ))" -ge "$3" ]
}
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-watch-lib.bats
shellcheck bin/fleet-watch-lib
git add bin/fleet-watch-lib tests/fleet-watch-lib.bats
git commit -m "feat: fleet-watch-lib hash/stall/cycle/budget predicates"
```

---

### Task 5: `fleet-watch` tick (one supervision pass)

**Files:**
- Create: `bin/fleet-watch`
- Test: `tests/fleet-watch.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-backend`, `fleet-pipeline`, `fleet-done`, `fleet-watch-lib`, `fleet-advance`, `fleet-spawn`.
- Produces: `fleet-watch --tick` runs exactly one pass over `state/missions/*` and exits. For each mission whose `.stage` is an in-flight pipeline stage (`fleet_pipeline_is_stage`):
  1. **New marker?** `fleet_done_count > .marker_cursor` → `fleet-advance <id>` and continue (advance owns the transition; the tick does not also inspect liveness this pass).
  2. **No new marker** → inspect liveness/progress:
     - terminal gone (`! fleet_backend_terminal_exists`) or `exitCode != null` → **dead** anomaly.
     - `blockedReason` matches `*trust*`/`*permission*`/`*approval*` → **stuck-on-prompt** anomaly.
     - else compute hash; `stalled` / `cycle` / `over_budget` → **stall** anomaly; if the hash changed, record progress (`.state_hash`, `.last_progress_at`) and continue.
  3. **On any anomaly:** `restarts == 0` → restart the stage once (re-`fleet-spawn` the same stage, `.restarts=1`, reset timers/hash, append journal); `restarts >= 1` → `parked` (`.stage=parked`, journal).
- Always rewrites the beacon (`state/.watch-beacon` = `date +%s`) at the end of the tick.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-watch.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
stage_of() { jq -r .stage "$(mj "$1")"; }
mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }
gitify() { fleet_git_init "$(jq -r .worktree_path "$(mj "$1")")"; }

@test "tick advances a mission with a fresh marker" {
  mk w1; gitify w1
  "$REPO_ROOT/bin/fleet-done" w1 done
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ "$(stage_of w1)" = "plan" ]
}

@test "tick writes the beacon" {
  mk w2; gitify w2
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
  [ -n "$(cat "$FLEET_STATE_OVERRIDE/.watch-beacon")" ]
}

@test "dead terminal with no marker restarts the stage once, then parks" {
  mk w3; gitify w3
  # first anomaly: terminal gone -> restart (restarts 0 -> 1), stage stays spec
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of w3)" = "spec" ]
  [ "$(jq -r .restarts "$(mj w3)")" = "1" ]
  # second anomaly: now parks
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of w3)" = "parked" ]
}

@test "stuck-on-trust-prompt is an anomaly -> restart" {
  mk w4; gitify w4
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"codex-trust-workspace"' run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w4)")" = "1" ]
}

@test "over-budget stage restarts" {
  mk w5; gitify w5
  jq '.stage_started_at=0' "$(mj w5)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj w5)"
  FLEET_BUDGET_SECONDS=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w5)")" = "1" ]
}

@test "progress (hash changed) is recorded, no restart" {
  mk w6; gitify w6
  "$REPO_ROOT/bin/fleet-watch" --tick   # records initial hash, restarts stays 0-ish
  wt="$(jq -r .worktree_path "$(mj w6)")"; echo work >> "$wt/seed.txt"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w6)")" = "0" ]
  [ "$(jq -r .stage "$(mj w6)")" = "spec" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-watch.bats`
Expected: FAIL — `bin/fleet-watch` missing.

- [ ] **Step 3: Write `bin/fleet-watch` (tick only for now)**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-backend
. "$SCRIPT_DIR/fleet-backend"
# shellcheck source=bin/fleet-pipeline
. "$SCRIPT_DIR/fleet-pipeline"
# shellcheck source=bin/fleet-done
. "$SCRIPT_DIR/fleet-done"
# shellcheck source=bin/fleet-watch-lib
. "$SCRIPT_DIR/fleet-watch-lib"
fleet_roots

STALL_SECONDS="${FLEET_STALL_SECONDS:-900}"
BUDGET_SECONDS="${FLEET_BUDGET_SECONDS:-2700}"

fleet_watch_beacon() { date +%s > "$FLEET_STATE/.watch-beacon"; }

# Restart-once-then-park on any anomaly (spec "Loop/stall monitoring" action).
fleet_watch_anomaly() {  # <id> <mj> <stage> <reason>
  local id=$1 mj=$2 stage=$3 reason=$4 restarts
  restarts="$(fleet_json_get "$mj" '.restarts')"
  if [ "$restarts" -lt 1 ]; then
    local now; now="$(date +%s)"
    fleet_json_set "$mj" ".restarts=1 | .stage_started_at=$now | .last_progress_at=$now | .state_hash=\"\""
    fleet_journal watch-restart "$id $stage ($reason)"
    "$SCRIPT_DIR/fleet-spawn" --mission "$id" --stage "$stage" >/dev/null
  else
    fleet_json_set "$mj" ".stage=\"parked\""
    fleet_journal watch-park "$id $stage ($reason after restart)"
  fi
}

fleet_watch_check() {  # <id>
  local id=$1 mj type stage term wt count cursor
  mj="$(fleet_mission_json "$id")"
  type="$(fleet_json_get "$mj" '.type')"
  stage="$(fleet_json_get "$mj" '.stage')"
  fleet_pipeline_is_stage "$type" "$stage" || return 0   # not in flight

  count="$(fleet_done_count "$id")"; cursor="$(fleet_json_get "$mj" '.marker_cursor')"
  if [ "$count" -gt "$cursor" ]; then
    "$SCRIPT_DIR/fleet-advance" "$id" >/dev/null
    return 0
  fi

  term="$(fleet_json_get "$mj" '.terminal')"; wt="$(fleet_json_get "$mj" '.worktree_path')"
  local now; now="$(date +%s)"

  # dead?
  if [ "$term" != null ] && [ -n "$term" ]; then
    if ! fleet_backend_terminal_exists "$term"; then
      fleet_watch_anomaly "$id" "$mj" "$stage" "terminal-gone"; return 0
    fi
    local state exit_code blocked
    state="$(fleet_backend_terminal_state "$term" 2000 || true)"
    exit_code="$(printf '%s' "$state" | cut -f3)"
    blocked="$(printf '%s' "$state" | cut -f2)"
    if [ -n "$exit_code" ] && [ "$exit_code" != null ]; then
      fleet_watch_anomaly "$id" "$mj" "$stage" "exit:$exit_code"; return 0
    fi
    case "$blocked" in
      *trust*|*permission*|*approval*)
        fleet_watch_anomaly "$id" "$mj" "$stage" "blocked:$blocked"; return 0 ;;
    esac
  fi

  # stall / cycle / budget
  local old new last started
  old="$(fleet_json_get "$mj" '.state_hash')"
  new="$(fleet_watch_hash "$wt")"
  last="$(fleet_json_get "$mj" '.last_progress_at')"
  started="$(fleet_json_get "$mj" '.stage_started_at')"
  if [ "$new" != "$old" ]; then
    fleet_json_set "$mj" ".state_hash=\"$new\" | .last_progress_at=$now"
    printf '%s\n' "$new" >> "$(fleet_mission_dir "$id")/hashes"
    return 0
  fi
  if fleet_watch_stalled "$old" "$new" "$last" "$now" "$STALL_SECONDS"; then
    fleet_watch_anomaly "$id" "$mj" "$stage" "stalled"; return 0
  fi
  if fleet_watch_cycle "$(fleet_mission_dir "$id")/hashes" "$new"; then
    fleet_watch_anomaly "$id" "$mj" "$stage" "cycle"; return 0
  fi
  if fleet_watch_over_budget "$started" "$now" "$BUDGET_SECONDS"; then
    fleet_watch_anomaly "$id" "$mj" "$stage" "over-budget"; return 0
  fi
}

fleet_watch_tick() {
  local mj id
  for mj in "$FLEET_STATE"/missions/*/mission.json; do
    [ -e "$mj" ] || continue
    id="$(fleet_json_get "$mj" '.id')"
    fleet_watch_check "$id"
  done
  fleet_watch_beacon
}

case "${1:-}" in
  --tick) fleet_watch_tick ;;
  *) fleet_die "usage: fleet-watch --tick   (daemon mode added in Task 6)" ;;
esac
```

- [ ] **Step 4: Run to verify pass**

Run: `bats tests/fleet-watch.bats`
Expected: PASS (6 tests). If "over-budget" also trips "stalled" first, note the order: the tick checks dead → stall → cycle → budget; the budget test sets a fresh hash each run so `stalled` is false (hash changed vs empty initial), reaching the budget check. Confirm by reading the journal if a case misfires.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "feat: fleet-watch tick (marker->advance, dead/stuck/stall/cycle/budget -> restart|park)"
```

---

### Task 6: `fleet-watch` daemon loop + beacon

**Files:**
- Modify: `bin/fleet-watch` (add daemon mode)
- Test: `tests/fleet-watch.bats` (add bounded-loop case)

**Interfaces:**
- Produces: `fleet-watch [--interval <s>] [--ticks <n>]` — runs the tick loop. `--ticks n` runs exactly `n` ticks then exits (test/one-shot mode); without it, loops forever. Default interval `${FLEET_WATCH_INTERVAL:-5}` seconds. Refreshes the beacon every tick. Zero tokens.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "daemon --ticks runs a bounded number of passes and drives the pipeline" {
  mk d1; gitify d1
  "$REPO_ROOT/bin/fleet-done" d1 done
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  [ "$(stage_of d1)" = "plan" ]
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-watch.bats -f "daemon"`
Expected: FAIL — `--ticks` unknown (hits the `fleet_die` usage arm).

- [ ] **Step 3: Add daemon mode to `bin/fleet-watch`**

Replace the final `case "${1:-}"` block with an arg parser + loop:

```bash
INTERVAL="${FLEET_WATCH_INTERVAL:-5}"; TICKS=""; ONE_TICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tick) ONE_TICK=1; shift ;;
    --ticks) TICKS=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    *) fleet_die "usage: fleet-watch [--tick | --ticks <n>] [--interval <s>]" ;;
  esac
done

if [ "$ONE_TICK" -eq 1 ]; then
  fleet_watch_tick
  exit 0
fi

fleet_journal watch-start "interval=${INTERVAL}s ticks=${TICKS:-inf}"
count=0
while :; do
  fleet_watch_tick
  count=$((count + 1))
  [ -n "$TICKS" ] && [ "$count" -ge "$TICKS" ] && break
  [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-watch.bats
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "feat: fleet-watch daemon loop (bounded --ticks, beacon each tick)"
```

---

### Task 7: `fleet-session-start` (reconcile + restart watcher)

**Files:**
- Create: `bin/fleet-session-start`
- Test: `tests/fleet-session-start.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-backend`, `fleet-pipeline`.
- Produces: `fleet-session-start [--no-watch]` — for each in-flight mission (`fleet_pipeline_is_stage`), checks whether its recorded terminal still exists (`fleet_backend_terminal_exists`); a missing terminal is journaled as `session-drift <id> <stage> terminal-gone` (the next watcher tick handles recovery — this script only *observes and records*, never mutates mission stage). It writes a fresh beacon and, unless `--no-watch`, launches `fleet-watch &` in the background. Prints a one-line summary (`reconciled <n> missions, <d> drifted`).

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-session-start.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }

@test "reconcile journals drift for a gone terminal and writes a beacon" {
  mk s1
  jq '.terminal="term_dead"' "$FLEET_STATE_OVERRIDE/missions/s1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/s1/mission.json"
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
  grep -q "session-drift s1" "$FLEET_STATE_OVERRIDE/journal.log"
  # observe-only: stage unchanged
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/s1/mission.json")" = "spec" ]
}

@test "no drift when terminals exist" {
  mk s2
  jq '.terminal="term_live"' "$FLEET_STATE_OVERRIDE/missions/s2/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/s2/mission.json"
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  ! grep -q "session-drift s2" "$FLEET_STATE_OVERRIDE/journal.log"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-session-start.bats`
Expected: FAIL — `bin/fleet-session-start` missing.

- [ ] **Step 3: Write `bin/fleet-session-start`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-backend
. "$SCRIPT_DIR/fleet-backend"
# shellcheck source=bin/fleet-pipeline
. "$SCRIPT_DIR/fleet-pipeline"
fleet_roots

NO_WATCH=0
[ "${1:-}" = "--no-watch" ] && NO_WATCH=1

reconciled=0 drifted=0
for mj in "$FLEET_STATE"/missions/*/mission.json; do
  [ -e "$mj" ] || continue
  type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
  fleet_pipeline_is_stage "$type" "$stage" || continue
  reconciled=$((reconciled + 1))
  id="$(fleet_json_get "$mj" '.id')"; term="$(fleet_json_get "$mj" '.terminal')"
  if [ "$term" != null ] && [ -n "$term" ] && ! fleet_backend_terminal_exists "$term"; then
    fleet_journal session-drift "$id $stage terminal-gone"
    drifted=$((drifted + 1))
  fi
done

date +%s > "$FLEET_STATE/.watch-beacon"
fleet_journal session-start "reconciled=$reconciled drifted=$drifted"

if [ "$NO_WATCH" -eq 0 ]; then
  "$SCRIPT_DIR/fleet-watch" >/dev/null 2>&1 &
  fleet_journal watch-spawn "pid=$!"
fi

printf 'reconciled %d missions, %d drifted\n' "$reconciled" "$drifted"
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-session-start.bats
shellcheck bin/fleet-session-start
git add bin/fleet-session-start tests/fleet-session-start.bats
git commit -m "feat: fleet-session-start reconcile (drift journaling) + watcher relaunch"
```

---

### Task 8: `fleet-turnend-guard` (Stop-hook decision)

**Files:**
- Create: `bin/fleet-turnend-guard`
- Test: `tests/fleet-turnend-guard.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-pipeline`.
- Produces: `fleet-turnend-guard [--beacon-max-age <s>]` — a Claude Code `Stop` hook run on the Commander. If there is at least one in-flight mission (`fleet_pipeline_is_stage`) **and** the beacon is missing or older than `${FLEET_BEACON_MAX_AGE:-60}` seconds, it prints a block reason to stdout and exits **2** (Stop hooks block on non-zero). Otherwise exits 0. It never mutates state — it only reads.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-turnend-guard.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }
fresh_beacon() { date +%s > "$FLEET_STATE_OVERRIDE/.watch-beacon"; }
stale_beacon() { echo 0 > "$FLEET_STATE_OVERRIDE/.watch-beacon"; }

@test "blocks when a mission is in flight and the beacon is stale" {
  mk g1; stale_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 2 ]
  [[ "$output" == *"watcher"* ]]
}

@test "allows when the beacon is fresh" {
  mk g2; fresh_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 0 ]
}

@test "allows when no mission is in flight (even with stale beacon)" {
  stale_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-turnend-guard.bats`
Expected: FAIL — `bin/fleet-turnend-guard` missing.

- [ ] **Step 3: Write `bin/fleet-turnend-guard`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-pipeline
. "$SCRIPT_DIR/fleet-pipeline"
fleet_roots

MAX_AGE="${FLEET_BEACON_MAX_AGE:-60}"
[ "${1:-}" = "--beacon-max-age" ] && MAX_AGE="$2"

in_flight=0
for mj in "$FLEET_STATE"/missions/*/mission.json; do
  [ -e "$mj" ] || continue
  type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
  if fleet_pipeline_is_stage "$type" "$stage"; then in_flight=1; break; fi
done
[ "$in_flight" -eq 1 ] || exit 0

beacon="$FLEET_STATE/.watch-beacon"
now="$(date +%s)"
age=$(( now - $(cat "$beacon" 2>/dev/null || echo 0) ))
if [ ! -f "$beacon" ] || [ "$age" -ge "$MAX_AGE" ]; then
  echo "fleet: missions in flight but the watcher beacon is dead/stale (age ${age}s). Restart it with: fleet-session-start" >&2
  exit 2
fi
exit 0
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-turnend-guard.bats
shellcheck bin/fleet-turnend-guard
git add bin/fleet-turnend-guard tests/fleet-turnend-guard.bats
git commit -m "feat: fleet-turnend-guard Stop-hook (in-flight + dead beacon -> block)"
```

---

### Task 9: End-to-end — watcher drives the pipeline; stall → restart → park

**Files:**
- Modify: `tests/fleet-e2e.bats` (add two scenarios)

**Interfaces:** no new production code. Proves the watcher (not manual `fleet-advance`) drives a campaign to `ready`, and that a persistently dead agent restarts once then parks. Any failure implicates a specific script; fix it and its unit test.

- [ ] **Step 1: Write the end-to-end scenarios**

Add to `tests/fleet-e2e.bats`:

```bash
@test "watcher ticks drive campaign spec->plan->execute->review(PASS)->ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id t1 >/dev/null
  wt="$(wt_of t1)"; fleet_git_init "$wt"
  tick() { "$REPO_ROOT/bin/fleet-watch" --tick; }
  fin() { "$REPO_ROOT/bin/fleet-done" t1 done; }
  fin; tick; [ "$(stage_of t1)" = "plan" ]
  fin; tick; [ "$(stage_of t1)" = "execute" ]
  fin; tick; [ "$(stage_of t1)" = "review" ]
  echo '{"result":"PASS","findings":[]}' > "$wt/findings.json"; fin; tick
  [ "$(stage_of t1)" = "ready" ]
}

@test "persistently dead agent restarts once then parks" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id t2 >/dev/null
  fleet_git_init "$(wt_of t2)"
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$FLEET_STATE_OVERRIDE/missions/t2/mission.json")" = "1" ]
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of t2)" = "parked" ]
  grep -q "watch-park t2" "$FLEET_STATE_OVERRIDE/journal.log"
}
```

(`wt_of` and `stage_of` already exist in `tests/fleet-e2e.bats` from Plan 1; if not, add `wt_of() { jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }`.)

- [ ] **Step 2: Run the whole suite**

Run: `bats tests/`
Expected: all suites PASS.

- [ ] **Step 3: Full lint + make check**

Run: `make check`
Expected: `shellcheck bin/*` clean, all bats green.

- [ ] **Step 4: Commit**

```bash
git add tests/fleet-e2e.bats
git commit -m "test: e2e watcher-driven pipeline + stall->restart->park"
```

---

## Self-Review

**Spec coverage (Supervision slice):**
- Watcher daemon, sleeps + reacts to markers, zero tokens idle → Tasks 5,6 (`fleet-watch`) ✓
- Marker → `fleet-advance` (and advance made idempotent so repeated ticks are safe) → Tasks 2,5 ✓
- Stall (worktree hash unchanged past threshold) → Task 4 `fleet_watch_stalled` + Task 5 ✓
- Cycle (A→B→A edit-revert) → Task 4 `fleet_watch_cycle` + Task 5 ✓
- Budget (per-stage wall-clock cap) → Task 4 `fleet_watch_over_budget` + Task 5 ✓
- Fold Orca `tui-idle` `blockedReason`/`exitCode` into the poll (trust/approval → stuck, exit → dead) → Task 3 `terminal_state` + Task 5 ✓
- Action: restart stage once (fresh spawn, bump `restarts`), then park → Task 5 `fleet_watch_anomaly` ✓
- Heartbeat beacon → Tasks 5,6 (`state/.watch-beacon`) ✓
- Turn-end guard (in-flight + dead beacon → block) → Task 8 ✓
- Session-start reconcile vs live terminals, restart watcher, journal drift → Task 7 ✓
- Error handling: dead terminal without marker → detected & restarted/parked (Task 5); watcher death → guard blocks + session-start relaunches (Tasks 7,8) ✓

**Review-finding fixes carried in this plan (all five):** Finding 1 (advance idempotency) → Task 2; Finding 2 (sed injection) → Task 1; Finding 3 (`--arg`-safe JSON string writes via `fleet_json_set_str`) → Task 2, applied to every string write this plan adds/touches; Finding 4 (unquoted brief path) → Task 1; Finding 5 (preserve the stopped stage) → Task 2 via `.last_stage`. Finding 5 keeps the spec's combined `.stage` field (so Phase-1 tests are undisturbed) and adds `.last_stage` alongside it rather than splitting into a separate `.state` — the lighter fold that records *where* a mission stopped without destabilizing the implemented pipeline.

**Deliberately deferred (later plans):** day-mode Commander **wake** on anomaly (this plan parks every anomaly — "park, don't ping"; wake belongs with the decision inbox in Plan 3); decision records for parked missions (Plan 3); ship/night/bunkers/axi.

**Type consistency:** new `mission.json` fields (`marker_cursor, stage_started_at, last_progress_at, state_hash, last_stage`) are initialized by `fleet-mission` (Task 2) and read/written with identical names by `fleet-advance` (Task 2) and `fleet-watch` (Task 5). `fleet_json_set_str` (defined in `fleet-common`, Task 2) is used for all string writes in `fleet-advance`; numeric writes keep `fleet_json_set`. `restarts` semantics (reset on stage entry, bumped by anomaly) are consistent between `fleet-advance`'s `spawn()` (Task 2) and `fleet-watch`'s `fleet_watch_anomaly` (Task 5). Backend names `fleet_backend_terminal_exists/terminal_state` (Task 3) are called with those exact names in Tasks 5,7. `fleet_pipeline_is_stage` (Task 3) is called in Tasks 5,7,8. `fleet_done_count` (Task 2) is called in Tasks 2,5. The `terminal_state` output contract (`satisfied\tblocked\texit`, cut fields 1/2/3) matches its consumers in Task 5.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every code step carries complete, runnable code. The one ordering caveat (stall-vs-budget check order) is called out explicitly in Task 5 Step 4 with how to confirm it.

**Idempotency check:** a tick with no new marker and unchanged worktree either records nothing (progress path when hash differs) or evaluates pure predicates and, absent an anomaly, mutates nothing but the beacon. `fleet-advance` no-ops below its cursor. Running `fleet-watch --tick` repeatedly on a healthy in-progress mission is safe — the property the whole plan depends on.
