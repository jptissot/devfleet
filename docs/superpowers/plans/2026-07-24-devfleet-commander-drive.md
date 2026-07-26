# Commander-Driven Missions (Drive Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second mission driver in which the Commander (a frontier LLM session) owns the orchestration loop, while the bash watcher keeps supervising at zero token cost by emitting events instead of advancing stages.

**Architecture:** A mission type declares `"driver": "commander"`; missions of that type skip `fleet-advance` entirely. The watcher branches once into `fleet_drive_check`, which detects markers and anomalies exactly as before but appends to a per-mission append-only event log and wakes the Commander instead of restarting or transitioning. The Commander acts through `fleet-drive` (`brief` / `spawn` / `state` / `ack`). Two hard caps — spawn count and mission wall clock — park fail-closed regardless of Commander intent.

**Tech Stack:** bash (`set -euo pipefail` in entrypoints, `# shellcheck shell=bash` in libraries), `jq` for all JSON, `bats-core` ≥ 1.12 for tests, `shellcheck` for lint. Orca is the session backend, reached only through `bin/fleet-backend`.

**Source spec:** [`docs/superpowers/specs/2026-07-24-devfleet-commander-drive-design.md`](../specs/2026-07-24-devfleet-commander-drive-design.md)

## Global Constraints

- Entrypoints start with `set -euo pipefail`; libraries are `# shellcheck shell=bash` with **no side effects on source**.
- Every function is named `fleet_<area>_<verb>`.
- All JSON reads and writes go through `jq` (use `fleet_json_get` / `fleet_json_set` / `fleet_json_set_str` from `bin/fleet-common`).
- All Orca calls go through `bin/fleet-backend`. No new direct `orca` invocations.
- `make check` (= `shellcheck bin/*` then `bats tests/`) must be green at the end of every task. The suite starts at 129 tests and only grows.
- Machine-driven behavior must not change. `driver` is absent from `campaign`/`strike`/`recon`/`fortify` and defaults to `machine`.
- Tests run offline against the fakes in `tests/helpers/common.bash` (`fleet_install_fake_orca` etc.). Never call the network or the real `orca`.
- Commit after every task with a Conventional Commits subject.

---

### Task 1: Mission-type driver, palette, and cap readers

`bin/fleet-pipeline` is the only reader of mission-type JSON. It gains driver/palette/cap accessors, and the reference drive type ships alongside them.

**Files:**
- Create: `config/missions/sortie.json`
- Modify: `bin/fleet-pipeline`
- Test: `tests/fleet-pipeline.bats`

**Interfaces:**
- Consumes: `fleet_pipeline_file <type>`, `fleet_die` (existing).
- Produces: `fleet_pipeline_driver <type>` → `machine|commander`; `fleet_pipeline_has_palette <type> <name>` → exit 0/1; `fleet_pipeline_palette_field <type> <name> <role|prompt>` → string; `fleet_pipeline_palette_names <type>` → one name per line; `fleet_pipeline_cap <type> <max_spawns|max_mission_seconds>` → integer.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-pipeline.bats`:

```bash
@test "driver defaults to machine; sortie is commander-driven" {
  run pl 'fleet_pipeline_driver campaign'; [ "$output" = "machine" ]
  run pl 'fleet_pipeline_driver sortie';   [ "$output" = "commander" ]
}

@test "palette lookup resolves role and prompt" {
  run pl 'fleet_pipeline_has_palette sortie execute'; [ "$status" -eq 0 ]
  run pl 'fleet_pipeline_has_palette sortie nope';    [ "$status" -ne 0 ]
  run pl 'fleet_pipeline_palette_field sortie execute role';   [ "$output" = "executor" ]
  run pl 'fleet_pipeline_palette_field sortie execute prompt'; [ "$output" = "execute.txt" ]
  run pl 'fleet_pipeline_palette_field sortie review role';    [ "$output" = "frontier" ]
}

@test "palette names list every entry in order" {
  run pl 'fleet_pipeline_palette_names sortie | tr "\n" " "'
  [ "$output" = "spec plan execute review fix audit recon " ]
}

@test "caps come from the type, with built-in defaults" {
  run pl 'fleet_pipeline_cap sortie max_spawns';            [ "$output" = "12" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds';   [ "$output" = "14400" ]
  run pl 'fleet_pipeline_cap campaign max_spawns';          [ "$output" = "12" ]
  run pl 'fleet_pipeline_cap campaign max_mission_seconds'; [ "$output" = "14400" ]
}

@test "unknown cap name dies" {
  run pl 'fleet_pipeline_cap sortie max_bananas'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-pipeline.bats`
Expected: FAIL — `fleet_pipeline_driver: command not found` and `unknown mission type 'sortie'`.

- [ ] **Step 3: Create the sortie mission type**

Create `config/missions/sortie.json`:

```json
{
  "type": "sortie",
  "driver": "commander",
  "palette": [
    { "name": "spec",    "role": "frontier", "prompt": "spec.txt" },
    { "name": "plan",    "role": "frontier", "prompt": "plan.txt" },
    { "name": "execute", "role": "executor", "prompt": "execute.txt" },
    { "name": "review",  "role": "frontier", "prompt": "review.txt" },
    { "name": "fix",     "role": "executor", "prompt": "fix.txt" },
    { "name": "audit",   "role": "frontier", "prompt": "audit.txt" },
    { "name": "recon",   "role": "frontier", "prompt": "recon.txt" }
  ],
  "max_spawns": 12,
  "max_mission_seconds": 14400
}
```

- [ ] **Step 4: Add the readers**

Append to `bin/fleet-pipeline`:

```bash
fleet_pipeline_driver() {  # <type> -> machine | commander
  jq -r '.driver // "machine"' "$(fleet_pipeline_file "$1")"
}

fleet_pipeline_has_palette() {  # <type> <name> -> 0 if the palette has that entry
  local hit
  hit="$(jq -r --arg s "$2" 'any(.palette[]?; .name==$s)' "$(fleet_pipeline_file "$1")")"
  [ "$hit" = "true" ]
}

fleet_pipeline_palette_field() {  # <type> <name> <role|prompt> -> value or ""
  jq -r --arg s "$2" --arg k "$3" \
    '(.palette[]? | select(.name==$s) | .[$k]) // ""' "$(fleet_pipeline_file "$1")"
}

fleet_pipeline_palette_names() {  # <type> -> one palette entry name per line
  jq -r '.palette[]?.name' "$(fleet_pipeline_file "$1")"
}

fleet_pipeline_cap() {  # <type> <max_spawns|max_mission_seconds> -> integer
  local def
  case "$2" in
    max_spawns)          def=12 ;;
    max_mission_seconds) def=14400 ;;
    *) fleet_die "unknown cap '$2'" ;;
  esac
  jq -r --arg k "$2" --argjson d "$def" '(.[$k] // $d)' "$(fleet_pipeline_file "$1")"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-pipeline.bats`
Expected: PASS, all tests.

- [ ] **Step 6: Full check and commit**

```bash
make check
git add config/missions/sortie.json bin/fleet-pipeline tests/fleet-pipeline.bats
git commit -m "feat: mission-type driver, palette, and cap readers + sortie type"
```

---

### Task 2: `fleet_mission_in_flight` and its four call sites

`fleet_pipeline_is_stage` is currently used to mean "this mission occupies a slot". A drive mission has no stage graph, so that test returns false and drive missions would be invisible to the watcher, the turn-end guard, session reconciliation, and the night active count.

**Files:**
- Modify: `bin/fleet-common`, `bin/fleet-watch:45`, `bin/fleet-turnend-guard:14-17`, `bin/fleet-session-start:19-20`, `bin/fleet-night` (`fleet_night_active_count`)
- Test: `tests/fleet-in-flight.bats` (create)

**Interfaces:**
- Consumes: `fleet_mission_json`, `fleet_json_get` (fleet-common); `fleet_pipeline_is_stage` (fleet-pipeline, sourced by every caller).
- Produces: `fleet_mission_in_flight <id>` → exit 0 when in flight, 1 otherwise.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-in-flight.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
inflight() {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_mission_in_flight '"$1"
}
set_stage() { jq --arg s "$2" '.stage=$s' "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }

@test "machine mission: graph stage is in flight, terminal state is not" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id f1 >/dev/null
  run inflight f1; [ "$status" -eq 0 ]
  set_stage f1 ready
  run inflight f1; [ "$status" -ne 0 ]
  set_stage f1 done
  run inflight f1; [ "$status" -ne 0 ]
}

@test "drive mission: driving is in flight, terminal states are not" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id f2 >/dev/null
  jq '.driver="commander" | .stage="driving"' "$(mj f2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj f2)"
  run inflight f2; [ "$status" -eq 0 ]
  set_stage f2 execute          # a free-text label is still in flight
  run inflight f2; [ "$status" -eq 0 ]
  for s in ready done parked blocked failed; do
    set_stage f2 "$s"
    run inflight f2; [ "$status" -ne 0 ]
  done
}

@test "unknown mission is not in flight" {
  run inflight nope; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-in-flight.bats`
Expected: FAIL — `fleet_mission_in_flight: command not found`.

- [ ] **Step 3: Add the predicate**

Append to `bin/fleet-common`:

```bash
# In-flight = occupies a stage/agent slot. Machine missions ask the stage graph;
# commander-driven missions have no graph, so any non-terminal stage counts.
fleet_mission_in_flight() {  # <id>
  local mj type stage driver
  mj="$(fleet_mission_json "$1")"
  [ -f "$mj" ] || return 1
  driver="$(fleet_json_get "$mj" '.driver // "machine"')"
  stage="$(fleet_json_get "$mj" '.stage')"
  if [ "$driver" = commander ]; then
    case "$stage" in ready|done|parked|blocked|failed) return 1 ;; *) return 0 ;; esac
  fi
  type="$(fleet_json_get "$mj" '.type')"
  fleet_pipeline_is_stage "$type" "$stage"
}
```

- [ ] **Step 4: Switch the four call sites**

In `bin/fleet-watch`, inside `fleet_watch_check`, replace:

```bash
  fleet_pipeline_is_stage "$type" "$stage" || return 0   # not in flight
```

with:

```bash
  fleet_mission_in_flight "$id" || return 0   # not in flight
```

In `bin/fleet-turnend-guard`, replace the loop body:

```bash
  type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
  if fleet_pipeline_is_stage "$type" "$stage"; then in_flight=1; break; fi
```

with:

```bash
  if fleet_mission_in_flight "$(fleet_json_get "$mj" '.id')"; then in_flight=1; break; fi
```

In `bin/fleet-session-start`, replace:

```bash
  type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
  fleet_pipeline_is_stage "$type" "$stage" || continue
  reconciled=$((reconciled + 1))
  id="$(fleet_json_get "$mj" '.id')"; term="$(fleet_json_get "$mj" '.terminal')"
```

with:

```bash
  id="$(fleet_json_get "$mj" '.id')"; stage="$(fleet_json_get "$mj" '.stage')"
  fleet_mission_in_flight "$id" || continue
  reconciled=$((reconciled + 1))
  term="$(fleet_json_get "$mj" '.terminal')"
```

In `bin/fleet-night`, inside `fleet_night_active_count`, replace:

```bash
    type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
    fleet_pipeline_is_stage "$type" "$stage" || continue
```

with:

```bash
    fleet_mission_in_flight "$(fleet_json_get "$mj" '.id')" || continue
```

- [ ] **Step 5: Run the new test and the whole suite**

Run: `bats tests/fleet-in-flight.bats && make check`
Expected: new file PASS; all pre-existing tests still PASS (129 + new); `shellcheck` clean. If `shellcheck` reports an unused `type` variable at a call site you edited, delete that assignment.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-common bin/fleet-watch bin/fleet-turnend-guard bin/fleet-session-start bin/fleet-night tests/fleet-in-flight.bats
git commit -m "feat: fleet_mission_in_flight covers driver-aware supervision"
```

---

### Task 3: Drive fields on `mission.json`

**Files:**
- Modify: `bin/fleet-mission`
- Test: `tests/fleet-mission.bats`

**Interfaces:**
- Consumes: `fleet_pipeline_driver` (Task 1).
- Produces: every `mission.json` carries `driver`, `spawn_count`, `mission_started_at`, `event_cursor`, `extends`, `last_anomaly_key`. Drive missions start at `stage="driving"`.

`last_anomaly_key` is an implementation detail the spec does not name: it holds the last emitted `<stage>:<reason>:<spawn_count>` so a stalled agent produces one event, not one per tick. It is written here so mission creation stays the single source of the record shape.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-mission.bats`:

```bash
@test "machine missions record driver=machine and zeroed drive fields" {
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m010
  [ "$status" -eq 0 ]
  mj="$FLEET_STATE_OVERRIDE/missions/m010/mission.json"
  [ "$(jq -r .driver "$mj")" = "machine" ]
  [ "$(jq -r .stage "$mj")" = "spec" ]
  [ "$(jq -r .spawn_count "$mj")" = "0" ]
  [ "$(jq -r .event_cursor "$mj")" = "0" ]
  [ "$(jq -r .extends "$mj")" = "0" ]
  [ "$(jq -r .last_anomaly_key "$mj")" = "" ]
  [ "$(jq -r .mission_started_at "$mj")" -gt 0 ]
}

@test "sortie missions are commander-driven and start at driving" {
  run "$REPO_ROOT/bin/fleet-mission" --type sortie --project acme --repo id:r --desc "rate limit" --id m011
  [ "$status" -eq 0 ]
  mj="$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  [ "$(jq -r .driver "$mj")" = "commander" ]
  [ "$(jq -r .stage "$mj")" = "driving" ]
  [ "$(jq -r .terminal "$mj")" = "null" ]
  [ -d "$(jq -r .worktree_path "$mj")" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-mission.bats`
Expected: FAIL — `.driver` is `null`, and the sortie case dies with `jq: error` / empty `entry`.

- [ ] **Step 3: Implement**

In `bin/fleet-mission`, replace:

```bash
[ -n "$ID" ] || ID="$(fleet_next_id)"
STAGE="$(fleet_pipeline_entry "$TYPE")"
# Artifact-skip rule: a provided spec skips the campaign spec stage.
if [ "$TYPE" = campaign ] && [ -n "$SPEC" ]; then STAGE="plan"; fi
```

with:

```bash
[ -n "$ID" ] || ID="$(fleet_next_id)"
DRIVER="$(fleet_pipeline_driver "$TYPE")"
if [ "$DRIVER" = commander ]; then
  STAGE="driving"          # no entry stage: the Commander picks the first step
else
  STAGE="$(fleet_pipeline_entry "$TYPE")"
  # Artifact-skip rule: a provided spec skips the campaign spec stage.
  if [ "$TYPE" = campaign ] && [ -n "$SPEC" ]; then STAGE="plan"; fi
fi
```

Then in the `jq -n` record, add `--arg driver "$DRIVER"` to the argument list and extend the object literal:

```bash
  '{id:$id,type:$type,project:$project,repo:$repo,description:$desc,stage:$stage,last_stage:$stage,
    driver:$driver,fix_round:0,restarts:0,marker_cursor:0,
    spawn_count:0,event_cursor:0,extends:0,last_anomaly_key:"",
    mission_started_at:($now_epoch|tonumber),
    stage_started_at:($now_epoch|tonumber),last_progress_at:($now_epoch|tonumber),state_hash:"",
    worktree_path:$wt,orca_worktree_id:$wtid,terminal:null,
    artifacts:({} + (if $spec!="" then {spec:$spec} else {} end)
                  + (if $issue!="" then {issue:$issue} else {} end)),
    created_at:$now,updated_at:$now}' \
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-mission.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-mission tests/fleet-mission.bats
git commit -m "feat: record driver and drive-mode counters on mission creation"
```

---

### Task 4: `fleet-events` — the durable event log

**Files:**
- Create: `bin/fleet-events`, `tests/fleet-events.bats`

**Interfaces:**
- Consumes: `fleet_mission_dir`, `fleet_mission_json`, `fleet_json_get`, `fleet_json_set` (fleet-common).
- Produces: `fleet_events_file <id>`; `fleet_events_append <id> <kind> <detail>`; `fleet_events_count <id>` → integer; `fleet_events_unread <id>` → JSONL; `fleet_events_ack <id> [count]`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-events.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id e1 >/dev/null
}
teardown() { fleet_teardown_home; }

ev() {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; '"$1"
}
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "append writes one JSON object per line" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 anomaly stalled'
  f="$FLEET_STATE_OVERRIDE/missions/e1/events"
  [ "$(wc -l < "$f" | tr -d ' ')" = "2" ]
  [ "$(head -n1 "$f" | jq -r .kind)" = "marker" ]
  [ "$(head -n1 "$f" | jq -r .detail)" = "done" ]
  [ "$(tail -n1 "$f" | jq -r .detail)" = "stalled" ]
  [ -n "$(head -n1 "$f" | jq -r .ts)" ]
}

@test "count is 0 before any event" {
  run ev 'fleet_events_count e1'
  [ "$output" = "0" ]
}

@test "unread respects the cursor and ack advances it" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 marker blocked:why'
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "2" ]
  ev 'fleet_events_ack e1'
  [ "$(jq -r .event_cursor "$(mj e1)")" = "2" ]
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "0" ]
  ev 'fleet_events_append e1 anomaly stalled'
  run ev 'fleet_events_unread e1 | jq -r .detail'; [ "$output" = "stalled" ]
}

@test "ack with an explicit count is honored" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_ack e1 1'
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "1" ]
}

@test "unread on a mission with no events prints nothing" {
  run ev 'fleet_events_unread e1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-events.bats`
Expected: FAIL — `bin/fleet-events: No such file or directory`.

- [ ] **Step 3: Implement**

Create `bin/fleet-events`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-events - append-only per-mission event log for commander-driven missions
# (spec "Drive mode"). Records are the source of truth; wakes are only nudges.
# The read cursor lives in mission.json, mirroring marker_cursor, so a replayed
# watcher tick emits nothing twice. Sourced only; no side effects on source.

fleet_events_file() {  # <id>
  printf '%s/events' "$(fleet_mission_dir "$1")"
}

fleet_events_append() {  # <id> <kind> <detail>
  local f; f="$(fleet_events_file "$1")"
  mkdir -p "$(dirname "$f")"
  jq -nc --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg k "$2" --arg d "${3:-}" \
    '{ts:$ts,kind:$k,detail:$d}' >> "$f"
}

fleet_events_count() {  # <id> -> total events ever appended
  local f; f="$(fleet_events_file "$1")"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else printf '0'; fi
}

fleet_events_unread() {  # <id> -> JSONL past .event_cursor
  local f cur; f="$(fleet_events_file "$1")"
  [ -f "$f" ] || return 0
  cur="$(fleet_json_get "$(fleet_mission_json "$1")" '.event_cursor // 0')"
  tail -n "+$((cur + 1))" "$f"
}

fleet_events_ack() {  # <id> [count]  (default: everything appended so far)
  local n=${2:-}
  [ -n "$n" ] || n="$(fleet_events_count "$1")"
  fleet_json_set "$(fleet_mission_json "$1")" ".event_cursor=$n"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-events.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-events tests/fleet-events.bats
git commit -m "feat: fleet-events append-only mission event log"
```

---

### Task 5: Extract anomaly detection into `fleet-detect`

Both lanes need identical detection (dead terminal, trust prompt, stall, edit-revert cycle, per-stage budget) but act differently on it. Extract it once, with the existing `tests/fleet-watch.bats` as the regression net.

**Files:**
- Create: `bin/fleet-detect`, `tests/fleet-detect.bats`
- Modify: `bin/fleet-watch` (source it; `fleet_watch_check` delegates)

**Interfaces:**
- Consumes: `fleet_watch_hash`, `fleet_watch_stalled`, `fleet_watch_cycle`, `fleet_watch_over_budget` (fleet-watch-lib); `fleet_backend_terminal_exists`, `fleet_backend_terminal_state` (fleet-backend).
- Produces: `fleet_detect_anomaly <id> <now_epoch> <stall_seconds> <budget_seconds>` → prints one of `terminal-gone`, `exit:<code>`, `blocked:<reason>`, `cycle`, `stalled`, `over-budget`, or nothing. It also performs the progress bookkeeping both lanes share (`state_hash`, `last_progress_at`, the `hashes` history file).

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-detect.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id d1 >/dev/null
  fleet_git_init "$(jq -r .worktree_path "$(mj d1)")"
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
setj() { jq "$2" "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }
detect() {  # <id> <now> <stall> <budget>
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-backend"; . "$REPO_ROOT/bin/fleet-watch-lib"; . "$REPO_ROOT/bin/fleet-detect"; fleet_roots; fleet_detect_anomaly '"$*"
}

@test "no terminal yet: never an anomaly" {
  run detect d1 999999999 1 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gone terminal reports terminal-gone" {
  setj d1 '.terminal="term_x"'
  FLEET_FAKE_TERM_GONE=1 run detect d1 100 900 2700
  [ "$output" = "terminal-gone" ]
}

@test "non-null exit code reports exit:<code>" {
  setj d1 '.terminal="term_x"'
  FLEET_FAKE_EXIT=3 run detect d1 100 900 2700
  [ "$output" = "exit:3" ]
}

@test "trust prompt reports blocked:<reason>" {
  setj d1 '.terminal="term_x"'
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"codex-trust-workspace"' run detect d1 100 900 2700
  [ "$output" = "blocked:codex-trust-workspace" ]
}

@test "unchanged tree past the stall window reports stalled" {
  setj d1 '.terminal="term_x" | .last_progress_at=0'
  run detect d1 100 900 2700          # first call records the hash
  run detect d1 100000 900 2700       # second call: unchanged, way past the window
  [ "$output" = "stalled" ]
}

@test "changed tree records progress and reports nothing" {
  setj d1 '.terminal="term_x"'
  run detect d1 100 900 2700
  echo work >> "$(jq -r .worktree_path "$(mj d1)")/seed.txt"
  run detect d1 200 900 2700
  [ -z "$output" ]
  [ "$(jq -r .last_progress_at "$(mj d1)")" = "200" ]
}

@test "over-budget reported once the tree is quiet" {
  setj d1 '.terminal="term_x" | .stage_started_at=0'
  run detect d1 100 900 2700
  run detect d1 100 900 1             # budget of 1s, elapsed 100s
  [ "$output" = "over-budget" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-detect.bats`
Expected: FAIL — `bin/fleet-detect: No such file or directory`.

- [ ] **Step 3: Implement `bin/fleet-detect`**

Create `bin/fleet-detect` — this is the body of today's `fleet_watch_check` with the marker branch and every mutation-of-stage removed:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-detect - shared effect-level anomaly detection for both mission drivers.
# Detection is identical in machine and drive mode; only the response differs
# (machine restarts once then parks; drive emits an event and wakes). Progress
# bookkeeping (state_hash, last_progress_at, hashes history) happens here because
# both lanes need it. Sourced only; no side effects on source.

fleet_detect_anomaly() {  # <id> <now_epoch> <stall_seconds> <budget_seconds> -> reason or ""
  local id=$1 now=$2 stall=$3 budget=$4 mj term wt
  mj="$(fleet_mission_json "$id")"
  term="$(fleet_json_get "$mj" '.terminal')"
  wt="$(fleet_json_get "$mj" '.worktree_path')"

  if [ "$term" != null ] && [ -n "$term" ]; then
    if ! fleet_backend_terminal_exists "$term"; then
      printf 'terminal-gone'; return 0
    fi
    local state exit_code blocked
    state="$(fleet_backend_terminal_state "$term" 2000 || true)"
    exit_code="$(printf '%s' "$state" | cut -f3)"
    blocked="$(printf '%s' "$state" | cut -f2)"
    if [ -n "$exit_code" ] && [ "$exit_code" != null ]; then
      printf 'exit:%s' "$exit_code"; return 0
    fi
    case "$blocked" in
      *trust*|*permission*|*approval*) printf 'blocked:%s' "$blocked"; return 0 ;;
    esac
  fi

  local old new last started hashes
  old="$(fleet_json_get "$mj" '.state_hash')"
  new="$(fleet_watch_hash "$wt")"
  last="$(fleet_json_get "$mj" '.last_progress_at')"
  started="$(fleet_json_get "$mj" '.stage_started_at')"
  hashes="$(fleet_mission_dir "$id")/hashes"
  if [ "$new" != "$old" ]; then
    fleet_json_set "$mj" ".state_hash=\"$new\" | .last_progress_at=$now"
    if fleet_watch_cycle "$hashes" "$new"; then printf 'cycle'; fi
    return 0
  fi
  # queued, never started: the pump owns kickoff, not the stall detector
  { [ "$term" = null ] || [ -z "$term" ]; } && return 0
  if fleet_watch_stalled "$old" "$new" "$last" "$now" "$stall"; then printf 'stalled'; return 0; fi
  if fleet_watch_over_budget "$started" "$now" "$budget"; then printf 'over-budget'; return 0; fi
  return 0
}
```

- [ ] **Step 4: Rewrite `fleet_watch_check` to use it**

In `bin/fleet-watch`, add the source line after the `fleet-watch-lib` one:

```bash
# shellcheck source=bin/fleet-detect
. "$SCRIPT_DIR/fleet-detect"
```

Then replace the whole `fleet_watch_check` function with:

```bash
fleet_watch_check() {  # <id>
  local id=$1 mj stage count cursor now reason
  mj="$(fleet_mission_json "$id")"
  fleet_mission_in_flight "$id" || return 0
  stage="$(fleet_json_get "$mj" '.stage')"

  count="$(fleet_done_count "$id")"; cursor="$(fleet_json_get "$mj" '.marker_cursor')"
  if [ "$count" -gt "$cursor" ]; then
    "$SCRIPT_DIR/fleet-advance" "$id" >/dev/null
    return 0
  fi

  now="$(date +%s)"
  reason="$(fleet_detect_anomaly "$id" "$now" "$STALL_SECONDS" "$BUDGET_SECONDS")"
  [ -n "$reason" ] && fleet_watch_anomaly "$id" "$mj" "$stage" "$reason"
  return 0
}
```

- [ ] **Step 5: Run the new test and the existing watcher suite**

Run: `bats tests/fleet-detect.bats tests/fleet-watch.bats && make check`
Expected: PASS everywhere. `tests/fleet-watch.bats` is unmodified — it proves the refactor preserved machine behavior.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-detect bin/fleet-watch tests/fleet-detect.bats
git commit -m "refactor: extract shared anomaly detection into fleet-detect"
```

---

### Task 6: `fleet-spawn` palette resolution and ad-hoc briefs

**Files:**
- Modify: `bin/fleet-spawn`
- Test: `tests/fleet-spawn.bats`

**Interfaces:**
- Consumes: `fleet_pipeline_driver`, `fleet_pipeline_has_palette`, `fleet_pipeline_palette_field` (Task 1).
- Produces: `fleet-spawn --mission <id> --stage <name>` resolves from `palette` on commander-driven types; `fleet-spawn --mission <id> --role <r> --prompt-text <t> --label <l>` renders an ad-hoc brief. `--dry-run` still prints the launch line and brief path.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-spawn.bats`:

```bash
@test "sortie stage resolves role and prompt from the palette" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s1 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi "* ]] || [[ "$output" == *"pi\""* ]]
  brief="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s1/mission.json")/.devfleet/s1.execute.brief"
  [ -f "$brief" ]
  grep -q "fleet-done s1" "$brief"
}

@test "sortie stage outside the palette dies" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s2 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s2 --stage nonsense --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"palette"* ]]
}

@test "ad-hoc brief uses the given text, role, and label" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s3 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s3 --role executor \
      --prompt-text "Run the benchmark in {worktree} for {mission_id}" --label bench --dry-run
  [ "$status" -eq 0 ]
  brief="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s3/mission.json")/.devfleet/s3.bench.brief"
  [ -f "$brief" ]
  grep -q "Run the benchmark in" "$brief"
  grep -q "s3" "$brief"
  grep -q "fleet-done s3" "$brief"
}

@test "ad-hoc flags must come as a complete set" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s4 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s4 --role executor --dry-run
  [ "$status" -ne 0 ]
  run "$REPO_ROOT/bin/fleet-spawn" --mission s4 --stage plan --role executor \
      --prompt-text x --label l --dry-run
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-spawn.bats`
Expected: FAIL — `unknown flag: --role`, and the palette case dies with `stage execute has no role in sortie`.

- [ ] **Step 3: Implement flag parsing and resolution**

In `bin/fleet-spawn`, replace the argument block:

```bash
MISSION="" STAGE="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) MISSION=$2; shift 2 ;;
    --stage) STAGE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) fleet_die "unknown flag: $1" ;;
  esac
done
[ -n "$MISSION" ] && [ -n "$STAGE" ] || fleet_die "need --mission and --stage"
```

with:

```bash
MISSION="" STAGE="" DRY=0 ROLE_ARG="" PROMPT_TEXT="" LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) MISSION=$2; shift 2 ;;
    --stage) STAGE=$2; shift 2 ;;
    --role) ROLE_ARG=$2; shift 2 ;;
    --prompt-text) PROMPT_TEXT=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) fleet_die "unknown flag: $1" ;;
  esac
done
[ -n "$MISSION" ] || fleet_die "need --mission"
ADHOC=0
if [ -n "$ROLE_ARG" ] || [ -n "$PROMPT_TEXT" ] || [ -n "$LABEL" ]; then
  [ -n "$ROLE_ARG" ] && [ -n "$PROMPT_TEXT" ] && [ -n "$LABEL" ] \
    || fleet_die "ad-hoc spawn needs all of --role --prompt-text --label"
  [ -z "$STAGE" ] || fleet_die "--stage cannot be combined with an ad-hoc brief"
  ADHOC=1; STAGE="$LABEL"
fi
[ -n "$STAGE" ] || fleet_die "need --stage or an ad-hoc brief (--role --prompt-text --label)"
```

Then replace the role/prompt resolution block:

```bash
ROLE="$(fleet_pipeline_field "$TYPE" "$STAGE" role)"
[ -n "$ROLE" ] || fleet_die "stage $STAGE has no role in $TYPE"
CMD="$(fleet_json_get "$FLEET_CONFIG/roles.json" ".$ROLE.cmd")"
[ -n "$CMD" ] && [ "$CMD" != null ] || fleet_die "no cmd for role $ROLE in roles.json"

PROMPT_FILE="$(fleet_pipeline_field "$TYPE" "$STAGE" prompt)"
[ -n "$PROMPT_FILE" ] || fleet_die "stage $STAGE has no prompt"
tmpl="$FLEET_HOME/prompts/$PROMPT_FILE"
[ -f "$tmpl" ] || tmpl="$FLEET_ROOT/prompts/$PROMPT_FILE"
[ -f "$tmpl" ] || fleet_die "missing prompt template $PROMPT_FILE"
```

with:

```bash
DRIVER="$(fleet_pipeline_driver "$TYPE")"
if [ "$ADHOC" -eq 1 ]; then
  ROLE="$ROLE_ARG"
  tmpl="$(mktemp)"; printf '%s\n' "$PROMPT_TEXT" > "$tmpl"
elif [ "$DRIVER" = commander ]; then
  fleet_pipeline_has_palette "$TYPE" "$STAGE" || fleet_die "stage $STAGE is not in the $TYPE palette"
  ROLE="$(fleet_pipeline_palette_field "$TYPE" "$STAGE" role)"
  [ -n "$ROLE" ] || fleet_die "palette entry $STAGE has no role in $TYPE"
  PROMPT_FILE="$(fleet_pipeline_palette_field "$TYPE" "$STAGE" prompt)"
  [ -n "$PROMPT_FILE" ] || fleet_die "palette entry $STAGE has no prompt"
  tmpl="$FLEET_HOME/prompts/$PROMPT_FILE"
  [ -f "$tmpl" ] || tmpl="$FLEET_ROOT/prompts/$PROMPT_FILE"
  [ -f "$tmpl" ] || fleet_die "missing prompt template $PROMPT_FILE"
else
  ROLE="$(fleet_pipeline_field "$TYPE" "$STAGE" role)"
  [ -n "$ROLE" ] || fleet_die "stage $STAGE has no role in $TYPE"
  PROMPT_FILE="$(fleet_pipeline_field "$TYPE" "$STAGE" prompt)"
  [ -n "$PROMPT_FILE" ] || fleet_die "stage $STAGE has no prompt"
  tmpl="$FLEET_HOME/prompts/$PROMPT_FILE"
  [ -f "$tmpl" ] || tmpl="$FLEET_ROOT/prompts/$PROMPT_FILE"
  [ -f "$tmpl" ] || fleet_die "missing prompt template $PROMPT_FILE"
fi
CMD="$(fleet_json_get "$FLEET_CONFIG/roles.json" ".$ROLE.cmd")"
[ -n "$CMD" ] && [ "$CMD" != null ] || fleet_die "no cmd for role $ROLE in roles.json"
```

The brief-rendering block below is unchanged: it reads `$tmpl` with `jq --rawfile` and appends the `fleet-done` contract footer, so ad-hoc briefs get the same placeholder substitution and the same completion contract.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-spawn.bats && make check`
Expected: PASS, including the pre-existing spawn tests.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-spawn tests/fleet-spawn.bats
git commit -m "feat: fleet-spawn resolves palettes and renders ad-hoc briefs"
```

---

### Task 7: `fleet-drive spawn` with caps

**Files:**
- Create: `bin/fleet-drive`, `tests/fleet-drive-spawn.bats`

**Interfaces:**
- Consumes: `fleet_events_append` (Task 4), `fleet_pipeline_cap`/`fleet_pipeline_driver` (Task 1), `fleet_decision_create`, `fleet_journal`, `fleet_repo_field`.
- Produces: `fleet_drive_require <id>`; `fleet_drive_in_flight <id>`; `fleet_drive_cap_park <id> <cap-name>`; the runnable `fleet-drive spawn` subcommand. Later tasks add `brief`, `ack`, `state`, and `fleet_drive_check` to this same file.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-drive-spawn.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id v1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
setj() { jq "$2" "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }

@test "spawn launches a palette stage and counts it" {
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "plan" ]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
  [ "$(jq -r .terminal "$(mj v1)")" != "null" ]
  orca_log_has "terminal"
}

@test "spawn refuses while an agent is in flight" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage execute
  [ "$status" -ne 0 ]
  [[ "$output" == *"in flight"* ]]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
}

@test "spawn refuses on a machine-driven mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id v2 >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v2 --stage plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
}

@test "hitting max_spawns parks the mission and opens an extend decision" {
  setj v1 '.spawn_count=12'
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "parked" ]
  [ "$(grep -c cap "$FLEET_STATE_OVERRIDE/missions/v1/events")" -ge 1 ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"v1"* ]]
  [[ "$output" == *"extend"* ]] || grep -ql extend "$FLEET_STATE_OVERRIDE"/decisions/*.json
}

@test "ad-hoc spawn is counted and labels the stage" {
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --role executor \
      --prompt-text "benchmark {mission_id}" --label bench
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "bench" ]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-drive-spawn.bats`
Expected: FAIL — `bin/fleet-drive: No such file or directory`.

- [ ] **Step 3: Implement**

Create `bin/fleet-drive`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-drive - commander-driven mission lane (spec "Drive mode"). The Commander
# owns sequencing; the machine owns caps and supervision. Dual-use: sourceable
# (fleet_drive_*) and runnable (the Commander's API). Sourced section has no
# side effects on source.

fleet_drive_require() {  # <id> - die unless the mission is commander-driven
  local mj
  mj="$(fleet_mission_json "$1")"
  [ -f "$mj" ] || fleet_die "no mission $1"
  [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ] \
    || fleet_die "mission $1 is machine-driven"
}

fleet_drive_in_flight() {  # <id> -> 0 if an agent is running for this mission
  local mj stage term
  mj="$(fleet_mission_json "$1")"
  stage="$(fleet_json_get "$mj" '.stage')"
  term="$(fleet_json_get "$mj" '.terminal')"
  case "$stage" in
    driving|ready|done|parked|blocked|failed) ;;
    *) return 0 ;;
  esac
  [ "$term" != null ] && [ -n "$term" ]
}

# A cap the Commander cannot argue with: park fail-closed and ask the user.
fleet_drive_cap_park() {  # <id> <cap-name>
  local id=$1 cap=$2 mj project did
  mj="$(fleet_mission_json "$id")"
  project="$(fleet_json_get "$mj" '.project')"
  fleet_json_set_str "$mj" '.last_stage' "$(fleet_json_get "$mj" '.stage')"
  fleet_json_set_str "$mj" '.stage' "parked"
  fleet_events_append "$id" cap "$cap"
  fleet_journal drive-cap "$id $cap"
  did="$(fleet_decision_create "$id" "$project" "cap" \
    "mission $id hit the $cap cap — extend?" "drive cap reached" \
    '[{"key":"extend","label":"extend","description":"grant one more cap allowance and hand back to the Commander"},{"key":"hold","label":"hold","description":"leave the mission parked"}]')"
  [ "$(fleet_mode)" = day ] && "$SCRIPT_DIR/fleet-wake" "decision $did: mission $id hit the $cap cap" 2>/dev/null || true
  printf '%s' "$did"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  # shellcheck source=bin/fleet-backend
  . "$SCRIPT_DIR/fleet-backend"
  # shellcheck source=bin/fleet-pipeline
  . "$SCRIPT_DIR/fleet-pipeline"
  # shellcheck source=bin/fleet-events
  . "$SCRIPT_DIR/fleet-events"
  # shellcheck source=bin/fleet-project
  . "$SCRIPT_DIR/fleet-project"
  # shellcheck source=bin/fleet-decision
  . "$SCRIPT_DIR/fleet-decision"
  fleet_roots

  cmd="${1:-}"; shift || true
  case "$cmd" in
    spawn)
      MISSION="" STAGE="" ROLE="" PROMPT_TEXT="" LABEL=""
      while [ $# -gt 0 ]; do case "$1" in
        --mission) MISSION=$2; shift 2 ;;
        --stage) STAGE=$2; shift 2 ;;
        --role) ROLE=$2; shift 2 ;;
        --prompt-text) PROMPT_TEXT=$2; shift 2 ;;
        --label) LABEL=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$MISSION" ] || fleet_die "need --mission"
      fleet_drive_require "$MISSION"
      fleet_drive_in_flight "$MISSION" && fleet_die "mission $MISSION already has an agent in flight"

      mj="$(fleet_mission_json "$MISSION")"
      type="$(fleet_json_get "$mj" '.type')"
      count="$(fleet_json_get "$mj" '.spawn_count')"
      max="$(fleet_pipeline_cap "$type" max_spawns)"
      if [ "$count" -ge "$max" ]; then
        fleet_drive_cap_park "$MISSION" max_spawns >/dev/null
        fleet_die "mission $MISSION reached max_spawns ($max) — parked, answer the decision with 'extend'"
      fi

      if [ -n "$PROMPT_TEXT" ]; then
        "$SCRIPT_DIR/fleet-spawn" --mission "$MISSION" --role "$ROLE" \
          --prompt-text "$PROMPT_TEXT" --label "$LABEL" >/dev/null
        new_stage="$LABEL"
      else
        "$SCRIPT_DIR/fleet-spawn" --mission "$MISSION" --stage "$STAGE" >/dev/null
        new_stage="$STAGE"
      fi

      now_epoch="$(date +%s)"
      fleet_json_set_str "$mj" '.stage' "$new_stage"
      fleet_json_set "$mj" ".spawn_count=$((count + 1)) | .restarts=0 | .last_anomaly_key=\"\" \
        | .stage_started_at=$now_epoch | .last_progress_at=$now_epoch | .state_hash=\"\""
      : > "$(fleet_mission_dir "$MISSION")/hashes"
      fleet_events_ack "$MISSION"
      fleet_journal drive-spawn "$MISSION $new_stage (spawn $((count + 1))/$max)"
      printf '%s\n' "$new_stage" ;;
    *) fleet_die "usage: fleet-drive {spawn} ..." ;;
  esac
fi
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x bin/fleet-drive
bats tests/fleet-drive-spawn.bats
```
Expected: PASS.

- [ ] **Step 5: Full check and commit**

```bash
make check
git add bin/fleet-drive tests/fleet-drive-spawn.bats
git commit -m "feat: fleet-drive spawn with fail-closed spawn cap"
```

---

### Task 8: `fleet-drive brief` and `ack`

One command per Commander turn: state, palette, unread events, open decisions, remaining caps.

**Files:**
- Modify: `bin/fleet-drive`
- Test: `tests/fleet-drive-brief.bats` (create)

**Interfaces:**
- Consumes: `fleet_events_unread`, `fleet_events_ack`, `fleet_pipeline_palette_names`, `fleet_pipeline_cap`, `fleet_decision_list`.
- Produces: `fleet-drive brief --mission <id> [--json]`; `fleet-drive ack --mission <id>`. JSON keys: `mission`, `stage`, `description`, `worktree`, `palette` (array), `unread` (array of event objects), `spawns_left` (int), `seconds_left` (int), `open_decisions` (array of ids).

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-drive-brief.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "add cache" --id b1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "json brief carries state, palette and caps" {
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .mission)" = "b1" ]
  [ "$(echo "$output" | jq -r .stage)" = "driving" ]
  [ "$(echo "$output" | jq -r .description)" = "add cache" ]
  [ "$(echo "$output" | jq -r '.palette | length')" = "7" ]
  [ "$(echo "$output" | jq -r .spawns_left)" = "12" ]
  [ "$(echo "$output" | jq -r '.unread | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.open_decisions | length')" = "0" ]
  [ "$(echo "$output" | jq -r .seconds_left)" -gt 0 ]
}

@test "unread events appear in the brief and ack clears them" {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; fleet_events_append b1 marker done'
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$(echo "$output" | jq -r '.unread | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.unread[0].detail')" = "done" ]
  "$REPO_ROOT/bin/fleet-drive" ack --mission b1
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$(echo "$output" | jq -r '.unread | length')" = "0" ]
}

@test "text brief is human readable" {
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1
  [ "$status" -eq 0 ]
  [[ "$output" == *"b1"* ]]
  [[ "$output" == *"driving"* ]]
  [[ "$output" == *"palette:"* ]]
}

@test "brief refuses a machine-driven mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id b2 >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b2
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-drive-brief.bats`
Expected: FAIL — `error: usage: fleet-drive {spawn} ...`.

- [ ] **Step 3: Implement the brief builder**

Add to the sourced section of `bin/fleet-drive`, after `fleet_drive_cap_park`:

```bash
fleet_drive_brief_json() {  # <id>
  local id=$1 mj type unread palette decisions spawns max_spawns max_seconds started now
  mj="$(fleet_mission_json "$id")"
  type="$(fleet_json_get "$mj" '.type')"
  unread="$(fleet_events_unread "$id" | jq -sc '.')"
  palette="$(fleet_pipeline_palette_names "$type" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  decisions="$(fleet_decision_list --open | awk -F'\t' -v id="$id" '$3 == id { print $1 }' \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
  spawns="$(fleet_json_get "$mj" '.spawn_count')"
  max_spawns="$(fleet_pipeline_cap "$type" max_spawns)"
  max_seconds="$(fleet_pipeline_cap "$type" max_mission_seconds)"
  started="$(fleet_json_get "$mj" '.mission_started_at')"
  now="$(date +%s)"
  jq -nc --slurpfile m "$mj" --argjson unread "$unread" --argjson palette "$palette" \
     --argjson decisions "$decisions" \
     --argjson spawns_left "$((max_spawns - spawns))" \
     --argjson seconds_left "$((max_seconds - (now - started)))" \
    '{mission: $m[0].id, stage: $m[0].stage, description: $m[0].description,
      worktree: $m[0].worktree_path, palette: $palette, unread: $unread,
      spawns_left: $spawns_left, seconds_left: $seconds_left, open_decisions: $decisions}'
}

fleet_drive_brief_text() {  # <id>
  local j; j="$(fleet_drive_brief_json "$1")"
  printf '%s' "$j" | jq -r '
    "mission: \(.mission)  stage: \(.stage)",
    "task: \(.description)",
    "worktree: \(.worktree)",
    "palette: \(.palette | join(" "))",
    "budget: \(.spawns_left) spawns, \(.seconds_left)s left",
    "open decisions: \(if (.open_decisions | length) == 0 then "none" else (.open_decisions | join(" ")) end)",
    "unread events: \(.unread | length)",
    (.unread[] | "  [\(.kind)] \(.detail)")'
}
```

Add the subcommands to the `case "$cmd"` block, before the `*)` arm:

```bash
    brief)
      MISSION="" AS_JSON=0
      while [ $# -gt 0 ]; do case "$1" in
        --mission) MISSION=$2; shift 2 ;;
        --json) AS_JSON=1; shift ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$MISSION" ] || fleet_die "need --mission"
      fleet_drive_require "$MISSION"
      if [ "$AS_JSON" -eq 1 ]; then fleet_drive_brief_json "$MISSION"; printf '\n'
      else fleet_drive_brief_text "$MISSION"; fi ;;
    ack)
      MISSION=""
      while [ $# -gt 0 ]; do case "$1" in
        --mission) MISSION=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$MISSION" ] || fleet_die "need --mission"
      fleet_drive_require "$MISSION"
      fleet_events_ack "$MISSION" ;;
```

Update the usage line in the `*)` arm to `usage: fleet-drive {spawn|brief|ack} ...`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-drive-brief.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-drive tests/fleet-drive-brief.bats
git commit -m "feat: fleet-drive brief and ack"
```

---

### Task 9: `fleet-drive state` and the ship gate

**Files:**
- Modify: `bin/fleet-drive`
- Test: `tests/fleet-drive-state.bats` (create)

**Interfaces:**
- Consumes: `fleet_repo_field` (fleet-project), `fleet_decision_create`, `fleet_mode`, `bin/fleet-ship`, `bin/fleet-wake`.
- Produces: `fleet-drive state --mission <id> --set <ready|done|parked|blocked|failed> [--reason <r>]`. On `ready`: auto-ship when the repo is `unattended`, else open a `ship`/`hold` decision — mirroring `fleet-advance`'s review-PASS branch.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-drive-state.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
mk() { "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id "$1" >/dev/null; }

@test "terminal states are recorded with a reason" {
  mk t1
  run "$REPO_ROOT/bin/fleet-drive" state --mission t1 --set blocked --reason "needs a key"
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t1)")" = "blocked" ]
  grep -q "needs a key" "$FLEET_STATE_OVERRIDE/missions/t1/events"
}

@test "an unknown state is refused" {
  mk t2
  run "$REPO_ROOT/bin/fleet-drive" state --mission t2 --set shipping
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj t2)")" = "driving" ]
}

@test "ready opens a ship decision when the repo is attended" {
  mk t3
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode report-only >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" state --mission t3 --set ready
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t3)")" = "ready" ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"t3"* ]]
  [[ "$output" == *"ship"* ]]
}

@test "ready auto-ships an unattended repo" {
  mk t4
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree t4)"
  jq --arg wt "$wt" '.worktree_path=$wt' "$(mj t4)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj t4)"
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$repo" \
    --default-branch main --forge github --ship-mode local-merge --unattended >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" state --mission t4 --set ready
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t4)")" = "done" ]
  [ "$(jq -r '.ship.mode' "$(mj t4)")" = "local-merge" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-drive-state.bats`
Expected: FAIL — `error: usage: fleet-drive {spawn|brief|ack} ...`.

- [ ] **Step 3: Implement**

Add to the `case "$cmd"` block of `bin/fleet-drive`, before the `*)` arm:

```bash
    state)
      MISSION="" NEW="" REASON=""
      while [ $# -gt 0 ]; do case "$1" in
        --mission) MISSION=$2; shift 2 ;;
        --set) NEW=$2; shift 2 ;;
        --reason) REASON=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$MISSION" ] && [ -n "$NEW" ] || fleet_die "need --mission and --set"
      fleet_drive_require "$MISSION"
      case "$NEW" in
        ready|done|parked|blocked|failed) ;;
        *) fleet_die "state must be one of: ready done parked blocked failed" ;;
      esac
      mj="$(fleet_mission_json "$MISSION")"
      now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
      fleet_json_set_str "$mj" '.last_stage' "$(fleet_json_get "$mj" '.stage')"
      fleet_json_set_str "$mj" '.stage' "$NEW"
      fleet_json_set "$mj" ".updated_at=\"$now\""
      fleet_events_append "$MISSION" note "state=$NEW${REASON:+ ($REASON)}"
      fleet_journal drive-state "$MISSION -> $NEW${REASON:+ ($REASON)}"
      if [ "$NEW" = ready ]; then
        project="$(fleet_json_get "$mj" '.project')"; repo="$(fleet_json_get "$mj" '.repo')"
        if [ "$(fleet_repo_field "$project" "$repo" unattended)" = "true" ]; then
          "$SCRIPT_DIR/fleet-ship" "$MISSION" >/dev/null
          fleet_json_set_str "$mj" '.stage' "done"
          fleet_journal drive-state "$MISSION unattended -> shipped"
        else
          did="$(fleet_decision_create "$MISSION" "$project" "ready" \
            "mission $MISSION is ready — ship?" "commander declared ready" \
            '[{"key":"ship","label":"ship","description":"apply the repo ship mode"},{"key":"hold","label":"hold","description":"leave in ready"}]')"
          [ "$(fleet_mode)" = day ] && "$SCRIPT_DIR/fleet-wake" "decision $did: mission $MISSION ready — ship?" 2>/dev/null || true
        fi
      fi
      printf '%s\n' "$(fleet_json_get "$mj" '.stage')" ;;
```

Update the usage line to `usage: fleet-drive {spawn|brief|ack|state} ...`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-drive-state.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-drive tests/fleet-drive-state.bats
git commit -m "feat: fleet-drive state with gated ship path"
```

---

### Task 10: `fleet_drive_check`, the watcher branch, and the `fleet-advance` refusal

The load-bearing task: supervision reports instead of deciding.

**Files:**
- Modify: `bin/fleet-drive` (add `fleet_drive_check`), `bin/fleet-watch` (source `fleet-drive`, branch), `bin/fleet-advance` (refuse)
- Test: `tests/fleet-drive-watch.bats` (create)

**Interfaces:**
- Consumes: `fleet_detect_anomaly` (Task 5), `fleet_done_count`/`fleet_done_latest`, `fleet_events_append`, `fleet_drive_cap_park`, `fleet_backend_terminal_stop`.
- Produces: `fleet_drive_check <id>` — called by `fleet_watch_check` for commander-driven missions and by nothing else.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-drive-watch.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id k1 >/dev/null
  fleet_git_init "$(jq -r .worktree_path "$(mj k1)")"
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
events() { cat "$FLEET_STATE_OVERRIDE/missions/$1/events" 2>/dev/null; }
spawns() { grep -cF $'orca\x1fterminal\x1fcreate' "$FLEET_ORCA_LOG"; }

@test "a marker becomes an event and hands back to the Commander" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage plan >/dev/null
  "$REPO_ROOT/bin/fleet-done" k1 done
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
  [ "$(jq -r .terminal "$(mj k1)")" = "null" ]
  [ "$(events k1 | jq -r 'select(.kind=="marker") | .detail')" = "done" ]
  [ "$(spawns)" = "$before" ]
}

@test "an anomaly emits an event and never respawns" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  before="$(spawns)"
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(spawns)" = "$before" ]
  [ "$(jq -r .stage "$(mj k1)")" = "execute" ]
  [ "$(jq -r .restarts "$(mj k1)")" = "0" ]
  [ "$(events k1 | jq -r 'select(.kind=="anomaly") | .detail')" = "terminal-gone" ]
}

@test "the same anomaly is not re-emitted every tick" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(events k1 | jq -r 'select(.kind=="anomaly")' | jq -s 'length')" = "1" ]
}

@test "an idle drive mission is never an anomaly" {
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ -z "$(events k1)" ]
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
}

@test "the wall-clock cap parks the mission and stops the terminal" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  jq '.mission_started_at=0' "$(mj k1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj k1)"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .stage "$(mj k1)")" = "parked" ]
  [ "$(events k1 | jq -r 'select(.kind=="cap") | .detail')" = "max_mission_seconds" ]
  orca_log_has "terminal"
}

@test "an unrecognized marker is reported, not parked" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage plan >/dev/null
  # fleet-done's format: "<epoch>\t<status>" appended to <worktree>/.devfleet/<id>.status
  printf '%s\t%s\n' "$(date +%s)" weird >> "$(jq -r .worktree_path "$(mj k1)")/.devfleet/k1.status"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
  [[ "$(events k1 | jq -r 'select(.kind=="marker") | .detail')" == unrecognized:* ]]
}

@test "fleet-advance refuses a drive mission" {
  run "$REPO_ROOT/bin/fleet-advance" k1
  [ "$status" -ne 0 ]
  [[ "$output" == *"commander-driven"* ]]
}
```

> The marker file path in the unrecognized-marker test must match what `bin/fleet-done` writes. Open `bin/fleet-done` and use its exact path and format; adjust that one line if it differs.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-drive-watch.bats`
Expected: FAIL — the watcher still calls `fleet-advance`, which parks the mission on an unknown stage, and no `events` file appears.

- [ ] **Step 3: Add `fleet_drive_check` to `bin/fleet-drive`**

Append to the sourced section, after `fleet_drive_brief_text`:

```bash
# The drive lane's per-tick logic: detect, record, wake. Never advances a stage,
# never restarts an agent. Called only from fleet_watch_check.
fleet_drive_check() {  # <id>
  local id=$1 mj type stage count cursor verb now started max_sec reason key term
  mj="$(fleet_mission_json "$id")"
  fleet_mission_in_flight "$id" || return 0
  type="$(fleet_json_get "$mj" '.type')"
  stage="$(fleet_json_get "$mj" '.stage')"

  # 1. new marker -> event + hand back
  count="$(fleet_done_count "$id")"; cursor="$(fleet_json_get "$mj" '.marker_cursor')"
  if [ "$count" -gt "$cursor" ]; then
    verb="$(fleet_done_latest "$id" || true)"
    fleet_json_set "$mj" ".marker_cursor=$count | .terminal=null"
    fleet_json_set_str "$mj" '.last_stage' "$stage"
    fleet_json_set_str "$mj" '.stage' "driving"
    case "$verb" in
      done|blocked:*|failed:*) fleet_events_append "$id" marker "$verb" ;;
      *)                       fleet_events_append "$id" marker "unrecognized:$verb" ;;
    esac
    fleet_journal drive-marker "$id $stage $verb"
    "$SCRIPT_DIR/fleet-wake" "mission $id: $stage -> $verb" 2>/dev/null || true
    return 0
  fi

  # 2. wall-clock cap: the one place the machine overrides the Commander mid-agent
  now="$(date +%s)"
  started="$(fleet_json_get "$mj" '.mission_started_at')"
  max_sec="$(fleet_pipeline_cap "$type" max_mission_seconds)"
  if fleet_watch_over_budget "$started" "$now" "$max_sec"; then
    term="$(fleet_json_get "$mj" '.terminal')"
    [ "$term" != null ] && [ -n "$term" ] && fleet_backend_terminal_stop "$term"
    fleet_drive_cap_park "$id" max_mission_seconds >/dev/null
    return 0
  fi

  # 3. nothing spawned -> nothing to detect
  [ "$stage" = driving ] && return 0

  # 4. anomaly -> event + wake, deduped per (stage, reason, spawn_count).
  # The thresholds come from the watcher that sources this file; the defaults
  # keep the function usable (and shellcheck-clean) on its own.
  reason="$(fleet_detect_anomaly "$id" "$now" "${STALL_SECONDS:-900}" "${BUDGET_SECONDS:-2700}")"
  [ -n "$reason" ] || return 0
  key="$stage:$reason:$(fleet_json_get "$mj" '.spawn_count')"
  [ "$key" = "$(fleet_json_get "$mj" '.last_anomaly_key')" ] && return 0
  fleet_json_set_str "$mj" '.last_anomaly_key' "$key"
  fleet_events_append "$id" anomaly "$reason"
  fleet_journal drive-anomaly "$id $stage ($reason)"
  "$SCRIPT_DIR/fleet-wake" "mission $id: $stage $reason" 2>/dev/null || true
}
```

- [ ] **Step 4: Branch the watcher and refuse in `fleet-advance`**

In `bin/fleet-watch`, add the source line after `fleet-decision`:

```bash
# shellcheck source=bin/fleet-drive
. "$SCRIPT_DIR/fleet-drive"
```

and add the branch as the first statement of `fleet_watch_check`, immediately after `mj="$(fleet_mission_json "$id")"`:

```bash
  if [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ]; then
    fleet_drive_check "$id"
    return 0
  fi
```

In `bin/fleet-advance`, immediately after the `mj`/`TYPE` lookups near the top, add:

```bash
[ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ] \
  && fleet_die "mission $ID is commander-driven — use fleet-drive"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-drive-watch.bats tests/fleet-watch.bats tests/fleet-advance.bats && make check`
Expected: PASS. Machine-mode watcher and advance suites are unmodified and must stay green.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-drive bin/fleet-watch bin/fleet-advance tests/fleet-drive-watch.bats
git commit -m "feat: drive-lane supervision reports instead of deciding"
```

---

### Task 11: `extend` and driver-aware `resume`

**Files:**
- Modify: `bin/fleet-decision`
- Test: `tests/fleet-drive-decision.bats` (create)

**Interfaces:**
- Consumes: `fleet_mission_json`, `fleet_json_get/set`, `fleet_backend_terminal_stop`, `fleet_journal`, `bin/fleet-wake`.
- Produces: `fleet_decision_extend <mission>`; `fleet_decision_resume` gains a commander branch. `answer extend` becomes the fourth mechanical answer.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-drive-decision.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id x1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
setj() { jq "$2" "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }
spawns() { grep -cF $'orca\x1fterminal\x1fcreate' "$FLEET_ORCA_LOG"; }

@test "extend clears the caps, un-parks, and does not spawn" {
  setj x1 '.spawn_count=12'
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission x1 --stage plan
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "parked" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | awk -F'\t' '{print $1}' | head -n1)"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" extend
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "driving" ]
  [ "$(jq -r .spawn_count "$(mj x1)")" = "0" ]
  [ "$(jq -r .extends "$(mj x1)")" = "1" ]
  [ "$(jq -r .mission_started_at "$(mj x1)")" -gt 0 ]
  [ "$(spawns)" = "$before" ]
}

@test "resume on a drive mission hands back without spawning" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission x1 --stage plan >/dev/null
  setj x1 '.stage="parked"'
  did="$("$REPO_ROOT/bin/fleet-decision" create --mission x1 --stage plan --question "resume?")"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "driving" ]
  [ "$(jq -r .terminal "$(mj x1)")" = "null" ]
  [ "$(spawns)" = "$before" ]
}

@test "resume on a machine mission still re-spawns the last stage" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc y --id x2 >/dev/null
  setj x2 '.stage="parked" | .last_stage="plan"'
  did="$("$REPO_ROOT/bin/fleet-decision" create --mission x2 --stage plan --question "resume?")"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x2)")" = "plan" ]
  [ "$(spawns)" -gt "$before" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-drive-decision.bats`
Expected: FAIL — `extend` falls through to the generic wake branch and changes nothing; `resume` re-spawns the drive mission.

- [ ] **Step 3: Implement**

In `bin/fleet-decision`, add the `extend` branch to `fleet_decision_answer`, right after the `ship` branch:

```bash
  elif [ "$answer" = extend ]; then
    fleet_decision_extend "$mission"
```

Add the two functions next to `fleet_decision_resume`:

```bash
# Lifting a hard cap is the user's call, not the Commander's: grant one fresh
# allowance of both drive caps and hand the mission back.
fleet_decision_extend() {  # <mission>
  local mission=$1 mj now
  mj="$(fleet_mission_json "$mission")"
  [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ] \
    || { echo "error: $mission is machine-driven; 'extend' does not apply" >&2; return 1; }
  now="$(date +%s)"
  fleet_json_set "$mj" ".spawn_count=0 | .mission_started_at=$now | .extends=(.extends + 1) | .last_anomaly_key=\"\""
  fleet_json_set_str "$mj" '.stage' "driving"
  fleet_journal decision-extend "$mission (extend #$(fleet_json_get "$mj" '.extends'))"
  "$SCRIPT_DIR/fleet-wake" "mission $mission extended — caps reset, it is yours again" 2>/dev/null || true
}
```

And make `fleet_decision_resume` driver-aware by inserting this immediately after its `mj=` assignment:

```bash
  if [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ]; then
    old_term="$(fleet_json_get "$mj" '.terminal')"
    [ "$old_term" != null ] && [ -n "$old_term" ] && fleet_backend_terminal_stop "$old_term"
    fleet_json_set "$mj" '.terminal=null'
    fleet_json_set_str "$mj" '.stage' "driving"
    fleet_json_set_str "$mj" '.last_anomaly_key' ""
    fleet_journal decision-resume "$mission -> driving (commander-driven, no respawn)"
    "$SCRIPT_DIR/fleet-wake" "mission $mission un-parked — it is yours again" 2>/dev/null || true
    return 0
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-drive-decision.bats tests/fleet-decision.bats && make check`
Expected: PASS, including the existing decision suite.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-decision tests/fleet-drive-decision.bats
git commit -m "feat: extend answer and driver-aware resume"
```

---

### Task 12: Night-queue admission gate

**Files:**
- Modify: `bin/fleet-night` (`fleet_night_admits`)
- Test: `tests/fleet-night.bats`

**Interfaces:**
- Consumes: `fleet_json_get`.
- Produces: `fleet_night_admits` rejects `driver=commander` with an explicit message.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-night.bats`:

```bash
@test "commander-driven missions are never admitted to the night queue" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id n9 >/dev/null
  run "$REPO_ROOT/bin/fleet-night" queue --mission n9
  [ "$status" -ne 0 ]
  [[ "$output" == *"commander-driven"* ]]
  [ ! -s "$FLEET_STATE_OVERRIDE/queue" ] || ! grep -q n9 "$FLEET_STATE_OVERRIDE/queue"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-night.bats`
Expected: FAIL — the message says `unknown type sortie`, not `commander-driven`.

- [ ] **Step 3: Implement**

In `bin/fleet-night`, inside `fleet_night_admits`, insert immediately after the `type=` assignment:

```bash
  if [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ]; then
    echo "mission $1 is commander-driven — a mission whose driver is asleep cannot run unattended" >&2
    return 1
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-night.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-night tests/fleet-night.bats
git commit -m "feat: night queue rejects commander-driven missions"
```

---

### Task 13: `AGENTS.md`, status surfacing, and README

**Files:**
- Create: `AGENTS.md`
- Modify: `bin/fleet-status`, `README.md`
- Test: `tests/fleet-status.bats`

**Interfaces:**
- Consumes: `fleet_events_unread` (Task 4), `fleet_json_get`.
- Produces: `fleet-status` prints a `drive` marker and unread-event count for commander-driven missions.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-status.bats`:

```bash
@test "status flags drive missions and their unread events" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id q1 >/dev/null
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; fleet_events_append q1 marker done'
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"q1"* ]]
  [[ "$output" == *"drive"* ]]
  [[ "$output" == *"1 unread"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-status.bats`
Expected: FAIL — no `drive` or `unread` in the output.

- [ ] **Step 3: Implement the status line**

In `bin/fleet-status`, source the events library alongside the others:

```bash
# shellcheck source=bin/fleet-events
. "$SCRIPT_DIR/fleet-events"
```

and, in the per-mission loop, append a drive suffix to the line it already prints:

```bash
  suffix=""
  if [ "$(fleet_json_get "$mj" '.driver // "machine"')" = commander ]; then
    suffix=" drive $(fleet_events_unread "$id" | wc -l | tr -d ' ') unread"
  fi
```

Append `$suffix` to the printed line. Keep the existing columns and the open-decision footer untouched.

- [ ] **Step 4: Write `AGENTS.md`**

Create `AGENTS.md`:

```markdown
# DevFleet — Commander instructions

You are the **Commander** of this fleet. The pipeline machine (`bin/fleet-*`) does the
management; you are the interface. Two rules hold in every mode:

- **Never poll.** Do not loop, sleep, or re-run `fleet-status` waiting for something. End your
  turn. The watcher wakes you.
- **Records beat chat.** Every open question is a decision record and every drive event is a log
  line. If a message is lost, the record still stands.

Run `bin/fleet-session-start` when a session begins: it reconciles state and relaunches the
watcher.

## Machine-driven missions (`campaign`, `strike`, `recon`, `fortify`)

The machine advances stages from the type's graph. You:

- create missions (`fleet-mission`), and start them (`fleet-spawn --mission <id> --stage <entry>`)
- answer or route decisions (`fleet-decision list --open`, `fleet-decision answer <id> <answer>`)
- report outcomes to the user and maintain project memory

You never call `fleet-advance`. You never restart a stage by hand.

## Commander-driven missions (`sortie`, or any type with `"driver": "commander"`)

You own the loop. The machine supervises and reports; it will not pick your next step.

1. On wake, or on session start with unread events: `fleet-drive brief --mission <id>`.
2. Decide, then act exactly once:
   - `fleet-drive spawn --mission <id> --stage <palette-name>`
   - `fleet-drive spawn --mission <id> --role <role> --prompt-text <text> --label <label>` for a
     step the palette does not cover
   - `fleet-drive state --mission <id> --set ready|done|parked|blocked|failed [--reason <r>]`
3. End your turn.

Notes:

- After a `review` spawn, read `findings.json` in the mission worktree yourself. In drive mode
  nothing else reads it.
- An anomaly event (`stalled`, `cycle`, `terminal-gone`, `exit:<n>`, `blocked:<reason>`,
  `over-budget`) is a report, not an action. The agent is still running. Decide whether to let
  it continue, spawn a different step, or park.
- One agent per mission at a time. Spawning while one is in flight is refused.
- You may not lift a cap. A cap-parked mission needs the user to answer `extend`, and
  `config/fleet.json` is not yours to edit.
- Drive missions are never admitted to the night queue.
```

- [ ] **Step 5: Update the README**

In `README.md`:

- Add a `sortie` row to the mission-type table: `| \`sortie\` | commander-driven, any order | palette: spec, plan, execute, review, fix, audit, recon |`
- Add `extend` to the mechanical-answer table: `| \`extend\` | grant one fresh drive-cap allowance and hand the mission back to the Commander |`
- Add a **Drive mode** section after *Mission types*, describing the `driver` field, the
  `fleet-drive` commands, the event log, and the caps, linking to `AGENTS.md`.
- Add `fleet-drive {brief|spawn|state|ack}` to the command-reference table, and
  `fleet-events`, `fleet-detect`, `fleet-drive` to the libraries line.

- [ ] **Step 6: Run everything and commit**

Run: `make check`
Expected: PASS, `shellcheck` clean.

```bash
git add AGENTS.md bin/fleet-status README.md tests/fleet-status.bats
git commit -m "docs: AGENTS.md commander contract, drive mode in README and status"
```

---

## Definition of done

- `make check` green: `shellcheck bin/*` clean, all bats tests passing (129 pre-existing + the new files).
- A sortie can be created, driven through several spawns, ended with `state --set ready`, and shipped by answering `ship` — all without `fleet-advance` running once.
- `tests/fleet-watch.bats`, `tests/fleet-advance.bats`, and `tests/fleet-night.bats` machine-mode cases are unmodified except for the added drive cases, proving machine behavior is untouched.
- Follow-up plan: `2026-07-24-devfleet-config-authority.md` (Commander-writable config, ceilings clamping the caps this plan introduces).
