# DevFleet Decision Inbox + Commander Wake Implementation Plan (Plan 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn every escalation into a durable **decision record** that cannot scroll away, wake the Commander (day mode) or hold silently (night mode) when a mission needs judgment, and let an answer route back — including resuming a parked mission from where it stopped. Plus the three supervision fixes from the Plan 2 review.

**Architecture:** A new dual-use `fleet-decision` (sourced lib + CRUD entrypoint) owns decision records under `state/decisions/<id>.json`; a shared `fleet_escalate` helper creates a record and, in day mode, calls the new `fleet-wake` (inject a message into the Commander's terminal via the backend). `fleet-watch` and `fleet-advance` stop merely journaling `parked`/`blocked` — they escalate. Answering a decision routes synchronously: a `resume` answer un-parks the mission from `.last_stage`; any other answer wakes the Commander to apply judgment.

**Tech Stack:** Bash, `jq`, `git`, `bats-core` 1.12, `shellcheck`. Orca stubbed by the programmable fake `orca` on `PATH` (from Plan 2). `gum` is optional and absent here — the inbox works fully via records + CLI + footer + wake; the `gum` TUI is a single, availability-gated final task.

**Builds on:** Plans 1–2 (all scripts/libs/tests exist and pass). This plan **modifies** `bin/fleet-watch`, `bin/fleet-advance`, `bin/fleet-backend`, `bin/fleet-common`, `bin/fleet-status`, and **adds** `bin/fleet-decision`, `bin/fleet-wake`, and (optional) `bin/fleet-decide`.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md` — "Decision inbox", "Commander boundaries", the watcher's "wake Commander (day) / park + record (night)" rows, "Error handling". Predecessor reference: `~/repos/kenchenguid/firstmate` (`fm-decision-hold.sh`, `fm-wake-lib.sh`, `fm-x-*` inbox) — mirror the durable-record idiom, not the away-mode daemon.

**Out of scope (later plans):** the gum TUI's live-watch loop beyond a one-shot render (Plan 3 ships the render + answer path; the polling TUI daemon is optional); ship modes + forge (Plan 4); full night ops queue + morning debrief (Plan 5 — this plan only reads the `state/.night` mode flag); bunkers (Plan 6); axi (Plan 7).

## Global Constraints

- Same conventions as Plans 1–2: `#!/usr/bin/env bash`; entrypoints `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; `fleet_<area>_<verb>()`; `*_OVERRIDE` env roots; all JSON via `jq`; string writes via `fleet_json_set_str` (Finding F3); `shellcheck bin/*` + `bats tests/` green after every task.
- **Records are the source of truth, chat is not** (spec "Decision inbox"): every escalation writes a `state/decisions/<id>.json` before any wake. A lost or ignored wake never loses the decision.
- **Park, don't ping — mode-aware:** day mode escalates *and* wakes; night mode escalates *and holds* (no wake). Mode = `night` iff `state/.night` exists, else `day`.
- **Idempotency continues:** escalating an already-open decision for the same mission+stage must not create duplicates (dedup on mission+stage+open).

## Data model

Decision record `state/decisions/<did>.json` (spec schema):

```json
{
  "id": "d1", "mission": "m003", "project": "acme", "stage": "execute",
  "question": "executor blocked: need an API key",
  "context": "escalated: blocked:need creds",
  "options": [{"key":"resume","label":"resume from execute","description":"re-run the stage"}],
  "status": "open", "answer": null,
  "created_at": "<iso>", "answered_at": null
}
```

- `did` from `state/.decision-seq` (`d1`, `d2`, … — same pattern as mission ids).
- `status ∈ open | answered`. `options` may be empty (free-text answer).
- Commander terminal handle for wake: `state/.commander-terminal` (written by `fleet-session-start --commander-terminal <h>` or env `FLEET_COMMANDER_TERMINAL`); absent → `fleet-wake` degrades to appending `state/.wake-pending` + journal.

## File Structure (delta)

```
bin/
  fleet-decision       # NEW dual-use: create/list/answer/show/footer + fleet_escalate + fleet_decision_* fns
  fleet-wake           # NEW: inject a message into the Commander terminal (graceful fallback)
  fleet-decide         # NEW (optional, gum-gated): one-shot TUI render + answer
  fleet-watch          # MODIFIED: fix cycle wiring (A), park sets last_stage (B), kill old agent on restart (C), escalate on park
  fleet-advance        # MODIFIED: escalate on parked/blocked
  fleet-backend        # MODIFIED: add fleet_backend_terminal_stop (C)
  fleet-common         # MODIFIED: add fleet_mode
  fleet-status         # MODIFIED: append open-decision lines / footer
state/
  decisions/<did>.json # decision records (dir already created by fleet_roots)
  .decision-seq        # NEW: decision id counter
  .commander-terminal  # NEW: Commander terminal handle for wake
  .night               # (read-only here) night-mode flag
tests/
  fleet-watch.bats     # MODIFIED: cycle-fires + park-preserves-last_stage + restart-kills-old cases
  fleet-decision.bats  # NEW
  fleet-wake.bats      # NEW
  fleet-escalate.bats  # NEW (watcher/advance -> record + day/night wake)
  fleet-e2e.bats       # MODIFIED: block -> record -> answer(resume) -> back in flight
```

---

### Task 1: Fix cycle detection wiring + reset history (review A, D)

**Files:**
- Modify: `bin/fleet-watch` (`fleet_watch_check` hash section; `fleet_watch_anomaly` reset)
- Test: `tests/fleet-watch.bats`

**Interfaces:** unchanged externally. Internally, the cycle check now runs when the hash *changes* (that is when A→B→A can appear); stall runs when it is *unchanged*; a restart truncates the `hashes` history.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "cycle (A,B,A) across ticks triggers a restart" {
  mk c1; wt="$(jq -r .worktree_path "$(mj c1)")"; fleet_git_init "$wt"
  # three distinct working-tree states A,B,A on consecutive ticks
  echo A > "$wt/f"; "$REPO_ROOT/bin/fleet-watch" --tick
  echo B > "$wt/f"; "$REPO_ROOT/bin/fleet-watch" --tick
  echo A > "$wt/f"; "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj c1)")" = "1" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fleet-watch.bats -f "cycle"`
Expected: FAIL — `restarts` stays 0 (cycle unreachable, the confirmed bug).

- [ ] **Step 3: Rewrite the hash/stall/cycle/budget block in `fleet_watch_check`**

Replace the block from `# stall / cycle / budget` through the three trailing `if` checks (bin/fleet-watch:70-89) with:

```bash
  # progress vs stall/cycle/budget
  local old new last started hashes
  old="$(fleet_json_get "$mj" '.state_hash')"
  new="$(fleet_watch_hash "$wt")"
  last="$(fleet_json_get "$mj" '.last_progress_at')"
  started="$(fleet_json_get "$mj" '.stage_started_at')"
  hashes="$(fleet_mission_dir "$id")/hashes"
  if [ "$new" != "$old" ]; then
    # the tree changed: record progress AND test for an edit-revert loop
    fleet_json_set "$mj" ".state_hash=\"$new\" | .last_progress_at=$now"
    if fleet_watch_cycle "$hashes" "$new"; then
      fleet_watch_anomaly "$id" "$mj" "$stage" "cycle"; return 0
    fi
    return 0
  fi
  # tree unchanged: stall or budget
  if fleet_watch_stalled "$old" "$new" "$last" "$now" "$STALL_SECONDS"; then
    fleet_watch_anomaly "$id" "$mj" "$stage" "stalled"; return 0
  fi
  if fleet_watch_over_budget "$started" "$now" "$BUDGET_SECONDS"; then
    fleet_watch_anomaly "$id" "$mj" "$stage" "over-budget"; return 0
  fi
```

(The cycle check now lives on the hash-*changed* path — the only place A→B→A can occur. `fleet_watch_cycle` still appends `$new` and returns 0 on the `A,B,A` tail; the earlier duplicate append at the progress line is gone.)

- [ ] **Step 4: Truncate history on restart (review D)**

In `fleet_watch_anomaly`, in the restart branch (`restarts < 1`), reset the hashes file alongside the timers. Change that branch's body to:

```bash
    local now; now="$(date +%s)"
    fleet_json_set "$mj" ".restarts=1 | .stage_started_at=$now | .last_progress_at=$now | .state_hash=\"\""
    : > "$(fleet_mission_dir "$id")/hashes"
    fleet_journal watch-restart "$id $stage ($reason)"
    "$SCRIPT_DIR/fleet-spawn" --mission "$id" --stage "$stage" >/dev/null
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-watch.bats && bats tests/
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "fix: cycle detection fires on hash-change path + reset hashes on restart (review A,D)"
```

---

### Task 2: Watcher park preserves `.last_stage` (review B)

**Files:**
- Modify: `bin/fleet-watch` (`fleet_watch_anomaly` park branch)
- Test: `tests/fleet-watch.bats`

**Interfaces:** the park branch now records `.last_stage=<stage>` (via `fleet_json_set_str`, F3) before overwriting `.stage=parked`, so a watcher-parked mission reports where it stopped — which Task 7's resume reads.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "watcher park records last_stage as the stopped stage" {
  mk pk1; fleet_git_init "$(jq -r .worktree_path "$(mj pk1)")"
  "$REPO_ROOT/bin/fleet-done" pk1 done; "$REPO_ROOT/bin/fleet-advance" pk1 >/dev/null  # -> plan
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # restart
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # park
  [ "$(jq -r .stage "$(mj pk1)")" = "parked" ]
  [ "$(jq -r .last_stage "$(mj pk1)")" = "plan" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fleet-watch.bats -f "records last_stage"`
Expected: FAIL — `last_stage` is `spec` (the confirmed bug).

- [ ] **Step 3: Fix the park branch**

In `fleet_watch_anomaly`, change the `else` (park) branch to preserve the stage first:

```bash
  else
    fleet_json_set_str "$mj" '.last_stage' "$stage"
    fleet_json_set_str "$mj" '.stage' "parked"
    fleet_journal watch-park "$id $stage ($reason after restart)"
  fi
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-watch.bats
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "fix: watcher park preserves last_stage (review B) + F3 string writes"
```

---

### Task 3: Backend `terminal_stop` + restart kills the old agent (review C)

**Files:**
- Modify: `bin/fleet-backend` (add `fleet_backend_terminal_stop`)
- Modify: `bin/fleet-watch` (`fleet_watch_anomaly` restart branch stops the old terminal first)
- Test: `tests/fleet-backend.bats`, `tests/fleet-watch.bats`

**Interfaces:**
- Produces: `fleet_backend_terminal_stop <handle>` — best-effort `orca terminal stop`/close of the endpoint (a gone terminal is not an error, mirroring firstmate:bin/fm-backend.sh:570-582).

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-backend.bats`:

```bash
@test "terminal_stop calls orca and tolerates a gone terminal" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_stop term_1'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fstop'
}
```

Add to `tests/fleet-watch.bats`:

```bash
@test "restart stops the old terminal before respawning" {
  mk r1; fleet_git_init "$(jq -r .worktree_path "$(mj r1)")"
  "$REPO_ROOT/bin/fleet-done" r1 done; "$REPO_ROOT/bin/fleet-advance" r1 >/dev/null  # -> plan, terminal recorded
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # anomaly -> restart
  grep -q $'terminal\x1fstop' "$FLEET_ORCA_LOG"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-backend.bats tests/fleet-watch.bats -f "stop"`
Expected: FAIL — `fleet_backend_terminal_stop` missing; no `terminal stop` in the restart log.

- [ ] **Step 3: Implement**

Append to `bin/fleet-backend`:

```bash
fleet_backend_terminal_stop() {  # <handle>  (best-effort; gone == success)
  orca terminal stop --terminal "$1" --json >/dev/null 2>&1 || true
}
```

Note: the fake `orca`'s existing `"terminal send"|"terminal read"|"terminal stop"` arm already answers `terminal stop`; no helper change needed.

In `fleet-watch`'s `fleet_watch_anomaly` restart branch, stop the old terminal before respawning. Insert right after the `: > "$(fleet_mission_dir "$id")/hashes"` line:

```bash
    local old_term; old_term="$(fleet_json_get "$mj" '.terminal')"
    [ "$old_term" != null ] && [ -n "$old_term" ] && fleet_backend_terminal_stop "$old_term"
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-backend.bats tests/fleet-watch.bats
shellcheck bin/fleet-backend bin/fleet-watch
git add bin/fleet-backend bin/fleet-watch tests/fleet-backend.bats tests/fleet-watch.bats
git commit -m "fix: restart stops the stalled agent first (review C) via backend terminal_stop"
```

---

### Task 4: `fleet-decision` (records CRUD + footer)

**Files:**
- Create: `bin/fleet-decision`
- Modify: `bin/fleet-common` (add `fleet_mode`, `fleet_next_decision_id`)
- Test: `tests/fleet-decision.bats`

**Interfaces:**
- Produces (in `fleet-common`):
  - `fleet_mode` — prints `night` iff `$FLEET_STATE/.night` exists, else `day`.
  - `fleet_next_decision_id` — `d1`, `d2`, … from `$FLEET_STATE/.decision-seq`.
- Produces (dual-use `fleet-decision`, sourced functions + subcommand entrypoint):
  - `fleet_decision_create <mission> <project> <stage> <question> <context>` — dedups on an open record for the same mission+stage; prints the decision id.
  - `fleet_decision_list [--open]` — one line per record: `<did>\t<status>\t<mission>\t<question>`.
  - `fleet_decision_footer` — the open-decision footer string, e.g. `⏳ 2 pending: [d3] merge? [d5] executor blocked` (empty string if none).
  - Entrypoint subcommands: `create --mission <id> --stage <s> --question <q> [--context <c>] [--option key:label:desc]...`, `list [--open]`, `show <did> [--json]`, `answer <did> <answer>` (Task 7), `footer`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-decision.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m1 >/dev/null
}
teardown() { fleet_teardown_home; }

@test "create writes a record and returns an id" {
  run "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key"
  [ "$status" -eq 0 ]
  [[ "$output" == d1 ]]
  rec="$FLEET_STATE_OVERRIDE/decisions/d1.json"
  [ "$(jq -r .status "$rec")" = "open" ]
  [ "$(jq -r .mission "$rec")" = "m1" ]
  [ "$(jq -r .project "$rec")" = "acme" ]
  [ "$(jq -r .question "$rec")" = "need a key" ]
}

@test "create dedups an open record for the same mission+stage" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "x" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "x again"
  [ "$output" = "d1" ]   # same id, not d2
  [ ! -f "$FLEET_STATE_OVERRIDE/decisions/d2.json" ]
}

@test "list --open shows open records; footer summarizes them" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"d1"* ]]
  [[ "$output" == *"need a key"* ]]
  run "$REPO_ROOT/bin/fleet-decision" footer
  [[ "$output" == *"1 pending"* ]]
  [[ "$output" == *"[d1]"* ]]
}

@test "options parse into the record" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "merge?" \
    --option "yes:Merge:fast-forward" --option "no:Hold:leave it" >/dev/null
  rec="$FLEET_STATE_OVERRIDE/decisions/d1.json"
  [ "$(jq -r '.options[0].key' "$rec")" = "yes" ]
  [ "$(jq -r '.options[1].label' "$rec")" = "Hold" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-decision.bats`
Expected: FAIL — `bin/fleet-decision` missing.

- [ ] **Step 3: Add `fleet_mode` + `fleet_next_decision_id` to `bin/fleet-common`**

```bash
fleet_mode() {  # night iff the flag file exists, else day
  [ -f "$FLEET_STATE/.night" ] && printf 'night' || printf 'day'
}

fleet_next_decision_id() {
  local seq_file="$FLEET_STATE/.decision-seq" n
  n=$(( $(cat "$seq_file" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$seq_file"
  printf 'd%d' "$n"
}
```

- [ ] **Step 4: Write `bin/fleet-decision`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-decision - durable decision records (spec "Decision inbox"). Dual-use:
# sourceable (fleet_decision_* + fleet_escalate) and runnable (CRUD entrypoint).

fleet_decision_dir() { printf '%s/decisions' "$FLEET_STATE"; }
fleet_decision_file() { printf '%s/decisions/%s.json' "$FLEET_STATE" "$1"; }

# Find an existing OPEN record for mission+stage, print its id or nothing.
fleet_decision_open_for() {  # <mission> <stage>
  local f
  for f in "$(fleet_decision_dir)"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status' "$f")" = open ] || continue
    [ "$(jq -r '.mission' "$f")" = "$1" ] && [ "$(jq -r '.stage' "$f")" = "$2" ] \
      && { jq -r '.id' "$f"; return 0; }
  done
  return 1
}

fleet_decision_create() {  # <mission> <project> <stage> <question> <context> [options-json]
  local mission=$1 project=$2 stage=$3 question=$4 context=${5:-} opts=${6:-[]} did existing now
  existing="$(fleet_decision_open_for "$mission" "$stage" || true)"
  [ -n "$existing" ] && { printf '%s' "$existing"; return 0; }
  did="$(fleet_next_decision_id)"
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  mkdir -p "$(fleet_decision_dir)"
  jq -n --arg id "$did" --arg m "$mission" --arg p "$project" --arg s "$stage" \
        --arg q "$question" --arg c "$context" --argjson o "$opts" --arg now "$now" \
    '{id:$id,mission:$m,project:$p,stage:$s,question:$q,context:$c,options:$o,
      status:"open",answer:null,created_at:$now,answered_at:null}' \
    > "$(fleet_decision_file "$did")"
  printf '%s' "$did"
}

fleet_decision_list() {  # [--open]
  local only_open=0; [ "${1:-}" = "--open" ] && only_open=1
  local f
  for f in "$(fleet_decision_dir)"/*.json; do
    [ -e "$f" ] || continue
    [ "$only_open" -eq 1 ] && [ "$(jq -r '.status' "$f")" != open ] && continue
    jq -r '[.id,.status,.mission,.question] | @tsv' "$f"
  done | sort
}

fleet_decision_footer() {
  local n; n="$(fleet_decision_list --open | wc -l | tr -d ' ')"
  [ "$n" -eq 0 ] && return 0
  printf '⏳ %s pending:' "$n"
  fleet_decision_list --open | while IFS=$'\t' read -r id _ _ q; do printf ' [%s] %s' "$id" "$q"; done
  printf '\n'
}

# fleet_escalate: create a record and, in day mode, wake the Commander. Defined
# here so fleet-watch/fleet-advance share one escalation path. Needs the caller's
# $SCRIPT_DIR to reach fleet-wake.
fleet_escalate() {  # <mission> <stage> <reason> <question>
  local mission=$1 stage=$2 reason=$3 question=$4 project did
  project="$(fleet_json_get "$(fleet_mission_json "$mission")" '.project')"
  did="$(fleet_decision_create "$mission" "$project" "$stage" "$question" "escalated: $reason" \
        '[{"key":"resume","label":"resume from '"$stage"'","description":"re-run the stage"}]')"
  fleet_journal decision-open "$did $mission $stage ($reason)"
  if [ "$(fleet_mode)" = day ]; then
    "$SCRIPT_DIR/fleet-wake" "decision $did: $question" 2>/dev/null || true
  fi
  printf '%s' "$did"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  fleet_roots
  cmd="${1:-}"; shift || true
  case "$cmd" in
    create)
      mission="" stage="" question="" context="" opts="[]"
      while [ $# -gt 0 ]; do case "$1" in
        --mission) mission=$2; shift 2 ;;
        --stage) stage=$2; shift 2 ;;
        --question) question=$2; shift 2 ;;
        --context) context=$2; shift 2 ;;
        --option) IFS=: read -r k l d <<<"$2"
          opts="$(printf '%s' "$opts" | jq --arg k "$k" --arg l "$l" --arg d "$d" '. + [{key:$k,label:$l,description:$d}]')"; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$mission" ] && [ -n "$stage" ] && [ -n "$question" ] || fleet_die "need --mission --stage --question"
      project="$(fleet_json_get "$(fleet_mission_json "$mission")" '.project')"
      fleet_decision_create "$mission" "$project" "$stage" "$question" "$context" "$opts"
      echo ;;
    list) fleet_decision_list "${1:-}" ;;
    footer) fleet_decision_footer ;;
    show)
      f="$(fleet_decision_file "$1")"; [ -f "$f" ] || fleet_die "no decision $1"
      if [ "${2:-}" = "--json" ]; then cat "$f"; else jq -r '[.id,.status,.mission,.stage,.question]|@tsv' "$f"; fi ;;
    answer) fleet_die "answer routing added in Task 7" ;;
    *) fleet_die "usage: fleet-decision {create|list|footer|show|answer} ..." ;;
  esac
fi
```

- [ ] **Step 5: Run to verify pass; lint; commit**

```bash
bats tests/fleet-decision.bats
shellcheck bin/fleet-decision bin/fleet-common
git add bin/fleet-decision bin/fleet-common tests/fleet-decision.bats
git commit -m "feat: fleet-decision records (create/list/footer, dedup) + fleet_mode"
```

---

### Task 5: `fleet-wake` (inject into the Commander terminal)

**Files:**
- Create: `bin/fleet-wake`
- Test: `tests/fleet-wake.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-backend`.
- Produces: `fleet-wake <message>` — resolves the Commander terminal from `${FLEET_COMMANDER_TERMINAL:-$(cat state/.commander-terminal)}`; if found, `fleet_backend_terminal_send <handle> <message>` and journals `wake`; else appends the message to `state/.wake-pending` and journals `wake-pending` (no failure — the record already persists the decision). Always exits 0.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-wake.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "wakes the recorded Commander terminal via the backend" {
  echo "term_cmd" > "$FLEET_STATE_OVERRIDE/.commander-terminal"
  run "$REPO_ROOT/bin/fleet-wake" "decision d1: need a key"
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'
}

@test "no Commander terminal -> pending file, still exits 0" {
  run "$REPO_ROOT/bin/fleet-wake" "hello"
  [ "$status" -eq 0 ]
  grep -q "hello" "$FLEET_STATE_OVERRIDE/.wake-pending"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-wake.bats`
Expected: FAIL — `bin/fleet-wake` missing.

- [ ] **Step 3: Write `bin/fleet-wake`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-backend
. "$SCRIPT_DIR/fleet-backend"
fleet_roots

[ $# -ge 1 ] || fleet_die "usage: fleet-wake <message>"
MSG="$*"

handle="${FLEET_COMMANDER_TERMINAL:-}"
[ -n "$handle" ] || handle="$(cat "$FLEET_STATE/.commander-terminal" 2>/dev/null || true)"

if [ -n "$handle" ]; then
  fleet_backend_terminal_send "$handle" "$MSG"
  fleet_journal wake "$handle: $MSG"
else
  printf '%s\n' "$MSG" >> "$FLEET_STATE/.wake-pending"
  fleet_journal wake-pending "$MSG"
fi
exit 0
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-wake.bats
shellcheck bin/fleet-wake
git add bin/fleet-wake tests/fleet-wake.bats
git commit -m "feat: fleet-wake injects into the Commander terminal (pending fallback)"
```

---

### Task 6: Escalate on park/blocked (watcher + advance), mode-aware

**Files:**
- Modify: `bin/fleet-watch` (source `fleet-decision`; park calls `fleet_escalate`)
- Modify: `bin/fleet-advance` (source `fleet-decision`; parked/blocked call `fleet_escalate`)
- Test: `tests/fleet-escalate.bats`

**Interfaces:** no new functions. `fleet-watch`'s park and `fleet-advance`'s `parked`/`blocked` outcomes now create a decision record; in day mode they also wake the Commander; in night mode they hold. Wiring uses the shared `fleet_escalate` from Task 4.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-escalate.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  echo "term_cmd" > "$FLEET_STATE_OVERRIDE/.commander-terminal"
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "advance blocked creates a decision record" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id e1 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e1 "blocked:need creds"
  "$REPO_ROOT/bin/fleet-advance" e1 >/dev/null
  [ "$(jq -r .stage "$(mj e1)")" = "blocked" ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"e1"* ]]
}

@test "day mode wakes the Commander on escalation; night mode holds" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id e2 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e2 "blocked:x"; "$REPO_ROOT/bin/fleet-advance" e2 >/dev/null
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'   # day -> woke
  : > "$FLEET_ORCA_LOG"
  touch "$FLEET_STATE_OVERRIDE/.night"
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc y --id e3 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e3 "blocked:y"; "$REPO_ROOT/bin/fleet-advance" e3 >/dev/null
  ! orca_log_has $'terminal\x1fsend'   # night -> no wake, but record exists
  [ -n "$("$REPO_ROOT/bin/fleet-decision" list --open | grep e3)" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-escalate.bats`
Expected: FAIL — advance/watch don't escalate yet (no open record; no wake).

- [ ] **Step 3: Wire `fleet-advance`**

Add the source line with the other sources (after the `fleet-done` source):

```bash
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
```

In the `case "$verb"` block, replace the `blocked:*` and the review-exhausted `parked` arms so each escalates. For `blocked:*`:

```bash
  blocked:*) set_stage blocked; next_state=blocked; log "blocked: ${verb#blocked:}"
             fleet_escalate "$ID" "$STAGE" "blocked" "mission $ID blocked at $STAGE: ${verb#blocked:}" >/dev/null ;;
```

For the review-exhausted park (inside the review branch's `else`):

```bash
      else
        set_stage parked; next_state=parked; log "review FAIL, rounds exhausted -> parked"
        fleet_escalate "$ID" "$STAGE" "fix-rounds-exhausted" "mission $ID parked at $STAGE after $LIMIT fix rounds" >/dev/null
      fi
```

And the fail-closed `*)` park:

```bash
  *) set_stage parked; next_state=parked; log "unknown marker '$verb' -> parked (fail-closed)"
     fleet_escalate "$ID" "$STAGE" "unknown-marker" "mission $ID parked at $STAGE (unrecognized completion)" >/dev/null ;;
```

- [ ] **Step 4: Wire `fleet-watch`**

Add the source line (after the `fleet-watch-lib` source):

```bash
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
```

In `fleet_watch_anomaly`, in the park branch (after the `fleet_journal watch-park` line), escalate:

```bash
    fleet_escalate "$id" "$stage" "$reason" "mission $id parked at $stage ($reason after restart)" >/dev/null
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-escalate.bats && bats tests/
shellcheck bin/fleet-advance bin/fleet-watch
git add bin/fleet-advance bin/fleet-watch tests/fleet-escalate.bats
git commit -m "feat: escalate parked/blocked to decision records + day-mode wake"
```

---

### Task 7: Answer routing (`resume` + judgment wake)

**Files:**
- Modify: `bin/fleet-decision` (implement the `answer` subcommand + `fleet_decision_answer`, `fleet_decision_resume`)
- Test: `tests/fleet-decision.bats`

**Interfaces:**
- Produces:
  - `fleet_decision_answer <did> <answer>` — sets `.status=answered`, `.answer`, `.answered_at`; then routes: if `answer == resume`, `fleet_decision_resume <mission>`; else `fleet-wake "decision <did> answered: <answer>"` (day mode) so the Commander applies judgment.
  - `fleet_decision_resume <mission>` — un-parks: sets `.stage` back to `.last_stage`, resets `.restarts`/timers, and re-spawns that stage. Reads `.last_stage` (why Tasks 2 + the F5 fix matter).

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-decision.bats`:

```bash
@test "answer resume un-parks the mission from last_stage and respawns" {
  # drive m1 to parked at 'plan'
  jq '.stage="parked" | .last_stage="plan"' "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage plan --question "parked" >/dev/null
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-decision" answer d1 resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "answered" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m1/mission.json")" = "plan" ]   # back in flight
  orca_log_has $'orca\x1fterminal\x1fcreate'                                        # respawned
}

@test "a non-resume answer marks answered and wakes the Commander" {
  echo term_cmd > "$FLEET_STATE_OVERRIDE/.commander-terminal"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "merge?" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 "yes, merge"
  [ "$status" -eq 0 ]
  [ "$(jq -r .answer "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "yes, merge" ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-decision.bats -f "answer"`
Expected: FAIL — the `answer` subcommand dies with "added in Task 7".

- [ ] **Step 3: Implement the functions and wire the subcommand**

Add to `bin/fleet-decision` (sourced section, after `fleet_escalate`):

```bash
fleet_decision_answer() {  # <did> <answer>
  local did=$1 answer=$2 f mission stage now
  f="$(fleet_decision_file "$did")"; [ -f "$f" ] || { echo "error: no decision $did" >&2; return 1; }
  now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  jq --arg a "$answer" --arg now "$now" '.status="answered" | .answer=$a | .answered_at=$now' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  mission="$(jq -r '.mission' "$f")"
  fleet_journal decision-answered "$did $mission $answer"
  if [ "$answer" = resume ]; then
    fleet_decision_resume "$mission"
  elif [ "$(fleet_mode)" = day ]; then
    "$SCRIPT_DIR/fleet-wake" "decision $did answered: $answer" 2>/dev/null || true
  fi
}

fleet_decision_resume() {  # <mission>
  local mission=$1 mj ls now
  mj="$(fleet_mission_json "$mission")"
  ls="$(fleet_json_get "$mj" '.last_stage')"
  [ -n "$ls" ] && [ "$ls" != null ] || { echo "error: $mission has no last_stage to resume" >&2; return 1; }
  now="$(date +%s)"
  fleet_json_set_str "$mj" '.stage' "$ls"
  fleet_json_set "$mj" ".restarts=0 | .stage_started_at=$now | .last_progress_at=$now | .state_hash=\"\""
  fleet_journal decision-resume "$mission -> $ls"
  "$SCRIPT_DIR/fleet-spawn" --mission "$mission" --stage "$ls" >/dev/null
}
```

Replace the entrypoint `answer)` arm with:

```bash
    answer) [ $# -ge 2 ] || fleet_die "usage: fleet-decision answer <did> <answer>"
            fleet_decision_answer "$1" "$2" ;;
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-decision.bats
shellcheck bin/fleet-decision
git add bin/fleet-decision tests/fleet-decision.bats
git commit -m "feat: decision answer routing (resume from last_stage | wake for judgment)"
```

---

### Task 8: `fleet-status` shows open decisions + end-to-end

**Files:**
- Modify: `bin/fleet-status` (append the decision footer)
- Modify: `tests/fleet-e2e.bats`
- Test: `tests/fleet-status.bats` (add a case)

**Interfaces:** `fleet-status` prints the mission lines as before, then — if any decision is open — a trailing footer line from `fleet_decision_footer`. `--json` gains a top-level `{missions:[...], decisions:[...]}` shape.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fleet-status.bats`:

```bash
@test "status appends the open-decision footer" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m1 >/dev/null
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key" >/dev/null
  run "$REPO_ROOT/bin/fleet-status"
  [[ "$output" == *"pending"* ]]
  [[ "$output" == *"[d1]"* ]]
}
```

Add to `tests/fleet-e2e.bats`:

```bash
@test "block -> decision record -> answer(resume) -> back in flight" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id b1 >/dev/null
  fleet_git_init "$(wt_of b1)"
  "$REPO_ROOT/bin/fleet-done" b1 done; "$REPO_ROOT/bin/fleet-watch" --tick    # spec -> plan
  "$REPO_ROOT/bin/fleet-done" b1 "blocked:need creds"; "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of b1)" = "blocked" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | head -1 | cut -f1)"
  "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$(stage_of b1)" = "plan" ]   # resumed from last_stage
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-status.bats tests/fleet-e2e.bats -f "footer|resume"`
Expected: FAIL — status has no footer; the e2e resume path is not yet exercised end to end.

- [ ] **Step 3: Wire `fleet-status`**

Source `fleet-decision` and append the footer. Add after the existing `. "$SCRIPT_DIR/fleet-common"`:

```bash
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
```

At the very end of the text-output path (after the mission loop), add:

```bash
footer="$(fleet_decision_footer || true)"
[ -n "$footer" ] && printf '%s' "$footer"
```

For `--json`, replace the `jq -s ...` line with the combined shape:

```bash
  missions="$(jq -s 'map({id,type,project,stage,last_stage})' "${files[@]}" 2>/dev/null || echo '[]')"
  decisions="$(fleet_decision_list --open | jq -R 'split("\t") | {id:.[0],mission:.[2],question:.[3]}' | jq -s '.')"
  jq -n --argjson m "${missions:-[]}" --argjson d "$decisions" '{missions:$m,decisions:$d}'
  exit 0
```

(Keep the empty-fleet guard: if there are no mission files, still emit `{"missions":[],"decisions":[...]}`.)

- [ ] **Step 4: Run to verify pass; full suite; make check; commit**

```bash
bats tests/
make check
git add bin/fleet-status tests/fleet-status.bats tests/fleet-e2e.bats
git commit -m "feat: fleet-status open-decision footer + e2e block->record->resume"
```

- [ ] **Step 5 (optional, gum-gated): `bin/fleet-decide` one-shot TUI**

Only if `command -v gum` succeeds (it is absent in the current environment — skip otherwise and note it). Create `bin/fleet-decide` that renders open records via `fleet_decision_list --open` and, for a chosen record, calls `fleet-decision answer <did> <choice>`. Because the inbox is fully usable via `fleet-decision`/footer/chat, this is a convenience surface, not a dependency. Add `tests/fleet-decide.bats` guarded by `command -v gum || skip`. Commit separately:

```bash
git add bin/fleet-decide tests/fleet-decide.bats
git commit -m "feat: fleet-decide gum TUI (optional, availability-gated)"
```

---

## Self-Review

**Spec coverage (Decision inbox slice):**
- Durable record per escalation (schema: id/mission/project/question/context/options/status/answer/timestamps) → Task 4 ✓
- `fleet-decision` create/list/answer → Tasks 4,7 ✓
- Both the Commander and `fleet-advance`/`fleet-watch` create records → Tasks 4,6 ✓
- Answer routing: mechanical (`resume` applied directly) vs judgment (wake Commander) → Task 7 ✓
- Footer rule (`⏳ N pending: [d3] … [d5] …`) + `fleet-status` open decisions → Tasks 4,8 ✓
- Day/night: day wakes, night holds (`park, don't ping`) → Tasks 4,6 (reads `state/.night`) ✓
- `fleet-wake` injects into the Commander terminal → Task 5 ✓
- No re-ping nagging (footer + record cover visibility; dedup prevents duplicate records) → Tasks 4 (dedup), 8 (footer) ✓

**Plan 2 review fixes carried:** A (cycle wiring) → Task 1; D (hashes reset/bound) → Task 1; B (park last_stage) → Task 2; C (restart stops old agent + backend `terminal_stop`) → Task 3. E (F3 in the watcher) is applied where those tasks touch `.stage`/`.last_stage` (Tasks 1–2 use `fleet_json_set_str`); the remaining safe numeric writes stay `fleet_json_set`.

**Deferred (later plans):** gum TUI live-poll loop (only the one-shot render ships, gated); mechanical *ship*-on-approval application (Plan 4 — Task 7 handles `resume`, ship answers come with `fleet-ship`); full night queue + morning debrief (Plan 5 — this plan only reads the mode flag).

**Type consistency:** decision record fields (`id,mission,project,stage,question,context,options,status,answer,created_at,answered_at`) are written by `fleet_decision_create` (Task 4) and read with identical names by `fleet_decision_list`/`footer`/`answer` (Tasks 4,7) and `fleet-status` (Task 8). `fleet_escalate` (Task 4) is called with the same signature `<mission> <stage> <reason> <question>` from `fleet-advance` and `fleet-watch` (Task 6). `fleet_decision_resume` (Task 7) reads `.last_stage`, which Tasks 2 + the F5 fix guarantee is the true stopped stage. `fleet_mode`/`fleet_next_decision_id` (Task 4, in `fleet-common`) are consumed by `fleet-decision` only. `fleet_backend_terminal_stop` (Task 3) is called in `fleet-watch` (Task 3) with the recorded `.terminal` handle.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every non-optional code step carries complete, runnable code. Task 8 Step 5 (gum TUI) is explicitly optional and availability-gated, not a placeholder.

**Idempotency & dedup:** `fleet_decision_create` returns the existing open record's id for the same mission+stage rather than creating a duplicate, so repeated ticks that re-detect the same park don't spawn record spam. `fleet-wake` always exits 0 and never blocks the escalation path. Answering is a one-shot state transition (`open`→`answered`); re-answering an already-answered record overwrites the answer and re-routes — acceptable and non-destructive.
