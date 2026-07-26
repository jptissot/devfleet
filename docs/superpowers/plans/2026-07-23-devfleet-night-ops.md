# DevFleet Night Ops (queue + pump + debrief) Implementation Plan (Plan 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the fleet unattended overnight: `fleet-night start` sets night mode and a bounded run **queue**; only missions with no pending interactive stage are admitted; a **pump** keeps at most `cap` missions running at once, kicking off the next when one frees a slot (parks/blocks/reaches ready/done); `fleet-night end` compiles a **morning debrief** (shipped / awaiting approval / parked / blocked / failed). Plus the two code fixes from the Plan 4 review.

**Architecture:** A new dual-use `fleet-night` (sourced helpers + subcommand entrypoint) owns `state/queue` (FIFO of mission ids), the `state/.night` flag (already read by `fleet_mode`, Plan 3), and `state/.night-cap`. The **pump** is the missing kickoff mechanism — nothing spawns a freshly-created mission's entry stage today; the pump does, gated by a concurrency cap. `fleet-watch`'s tick calls `fleet-night pump` when night mode is on, so every heartbeat tops running missions back up to `cap` — that is how "park, don't ping → queue pulls next" (spec Night ops) happens with zero LLM tokens. The debrief is a deterministic scan of `state/missions/*` bucketed by stage.

**Tech Stack:** Bash, `jq`, `git`, `bats-core` 1.12, `shellcheck`. Orca stubbed by the programmable fake `orca` on `PATH` (Plan 2). `lavish-axi` (richer debrief formatting) is optional and absent here — the debrief ships as plain text, `lavish-axi` is a gated enhancement.

**Builds on:** Plans 1–4 (all scripts/libs/tests exist; 93 bats green after the Plan 4 review fix). This plan **modifies** `bin/fleet-project`, `bin/fleet-ship`, `bin/fleet-watch`, and **adds** `bin/fleet-night`. It reuses `fleet_mode`/`fleet_pipeline_is_stage`/`fleet-spawn` unchanged.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md` — "Night ops" (`fleet-night start`/`end`, `state/queue`, admission rules, park-pulls-next, completions held per ship mode, morning debrief), "State layout" (`state/queue`, `state/.night`), "Components" (`bin/fleet-night`), "Fleet home … night-queue caps". Predecessor reference: `~/repos/kenchenguid/firstmate` — night ops is the one area the design deliberately does **not** port firstmate's away-mode daemon; this is a tick-driven pump, not a standalone supervisor.

**Out of scope (later plans):** bunkers / loadouts (Plan 6); the `tea-axi`/`gh-axi`/`lavish-axi` wrappers themselves (this plan calls plain tools behind gates); per-project `night_cap` *enforcement* — v1 uses one global cap from `start --cap` (the `project.json night_cap` field stays read-only groundwork, enforcement noted as deferred); a real cron/systemd night trigger (the operator runs `fleet-night start`; the existing watcher daemon does the rest).

## Global Constraints

- Same conventions as Plans 1–4: `#!/usr/bin/env bash`; entrypoints `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; `fleet_<area>_<verb>()`; `*_OVERRIDE` env roots; all JSON via `jq`; string writes via `fleet_json_set_str`; `shellcheck bin/*` + `bats tests/` green after every task.
- **No unattended brainstorming** (spec Night ops): a mission is admitted to the queue only if it has no pending interactive stage — campaign needs `artifacts.spec`, strike needs `artifacts.issue`, recon/fortify need a non-empty `description` (always set at creation). Rejected missions never enter the queue.
- **Park, don't ping** (spec, Plans 2–3): night escalations already park + record without waking (Plan 3 `fleet_mode`-aware `fleet_escalate`). This plan adds only the *pull-next* half — a freed slot starts the next queued mission.
- **Completions held per ship mode** (spec, Plan 4): the pump never ships. A mission reaching `ready` at night stays `ready` (attended repos) or was already shipped by `fleet-advance` (unattended repos). The debrief reports both.

## Data model (delta)

```
state/
  queue        # NEW: FIFO, one mission id per line (dequeue = pop first line)
  .night       # night-mode flag (created by start, removed by end) — read by fleet_mode
  .night-cap   # NEW: integer max concurrently-running missions (from `start --cap`, default 1)
```

- A mission's `.terminal` (set by `fleet-spawn`) + an in-flight `.stage` (a pipeline stage) mark it as occupying a run slot. `parked`/`blocked`/`failed`/`ready`/`done` are not pipeline stages, so they free the slot automatically.
- No new mission.json fields.

## File Structure (delta)

```
bin/
  fleet-night    # NEW dual-use: start/queue/pump/debrief/end + fleet_night_* helpers
  fleet-watch    # MODIFIED: tick calls `fleet-night pump` in night mode (pull-next)
  fleet-project  # MODIFIED: `show` error path uses $name not $project (review P4-2)
  fleet-ship     # MODIFIED: local-merge verifies the repo is on its default branch (review P4-3)
tests/
  fleet-night.bats     # NEW (start/end flag, admission gate, queue FIFO, pump cap, debrief)
  fleet-watch.bats     # MODIFIED: night tick pumps the queue
  fleet-project.bats   # MODIFIED: show on a missing project fails cleanly (review P4-2)
  fleet-ship.bats      # MODIFIED: local-merge refuses when repo is off its default branch (review P4-3)
  fleet-e2e.bats       # MODIFIED: night queue cap=1 -> run one -> free slot -> run next -> debrief
```

> **Already applied (Plan 4 review P4-1):** `tests/fleet-forge.bats` was missing `export REPO_ROOT`, so its two `run bash -c '…$REPO_ROOT…'` cases exited 127 and the suite was red (2 failing). The one-line fix (`export REPO_ROOT` in `setup()`) is already in the working tree — suite is now 93 green. Commit it alongside Task 1 (`git add tests/fleet-forge.bats`); no further change needed.

---

### Task 1: Plan 4 review fixes (P4-2 `show` var, P4-3 local-merge base guard)

**Files:**
- Modify: `bin/fleet-project` (`show` arm error message)
- Modify: `bin/fleet-ship` (`local-merge` branch guard)
- Test: `tests/fleet-project.bats`, `tests/fleet-ship.bats`

**Interfaces:** unchanged externally. `fleet-project show <missing>` now dies with a clean `no project <name>` instead of a `set -u` "unbound variable" crash. `fleet-ship` `local-merge` now refuses (journals `ship-fail`, `fleet_die`) if the target repo is not checked out on its `default_branch`, so it can never fast-forward the wrong branch.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fleet-project.bats`:

```bash
@test "show on a missing project fails cleanly (no unbound-variable crash)" {
  run "$REPO_ROOT/bin/fleet-project" show ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"no project ghost"* ]]
  [[ "$output" != *"unbound variable"* ]]
}
```

Add to `tests/fleet-ship.bats`:

```bash
@test "local-merge refuses when the repo is off its default branch" {
  repo="$(seed_shipping_mission g1 local-merge)"
  git -C "$repo" checkout -q -b sidetrack     # repo no longer on main
  run "$REPO_ROOT/bin/fleet-ship" g1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on main"* ]]
  [ "$(jq -r .stage "$(mj g1)")" != "done" ]  # nothing shipped
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-project.bats tests/fleet-ship.bats -f "missing project|off its default"`
Expected: FAIL — `show ghost` prints `project: unbound variable`; `local-merge` merges (or dies with a different message) instead of refusing on the wrong branch.

- [ ] **Step 3: Fix `fleet-project` `show`**

In `bin/fleet-project`, in the `show)` arm, correct the undefined variable (bin/fleet-project:68):

```bash
      pj="$(fleet_project_json "$name")"; [ -f "$pj" ] || fleet_die "no project $name"
```

- [ ] **Step 4: Guard `fleet-ship` local-merge**

In `bin/fleet-ship`, in the `local-merge)` arm, verify the branch before merging. Replace the arm body with:

```bash
  local-merge)
    [ -n "$REPO_PATH" ] && [ -n "$branch" ] || fleet_die "local-merge needs repo path + branch"
    cur="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$cur" = "$BASE" ] || { fleet_journal ship-fail "$ID repo not on $BASE (on ${cur:-?})"; \
                              fleet_die "repo $REPO_PATH not on $BASE (on ${cur:-?})"; }
    git -C "$REPO_PATH" merge --ff-only "$branch" >/dev/null 2>&1 \
      || { fleet_journal ship-fail "$ID local-merge ff-only failed ($branch -> $BASE)"; \
           fleet_die "ff-only merge failed: $branch -> $BASE"; }
    result="merged $branch -> $BASE" ;;
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-project.bats tests/fleet-ship.bats && bats tests/
shellcheck bin/fleet-project bin/fleet-ship
git add bin/fleet-project bin/fleet-ship tests/fleet-project.bats tests/fleet-ship.bats tests/fleet-forge.bats
git commit -m "fix: clean 'no project' error (P4-2) + local-merge base-branch guard (P4-3) + forge test export (P4-1)"
```

---

### Task 2: `fleet-night start` / `end` + night flag & queue

**Files:**
- Create: `bin/fleet-night` (helpers + `start`/`end` first; other subcommands added in Tasks 3–6)
- Test: `tests/fleet-night.bats`

**Interfaces:**
- Produces (sourced helpers):
  - `fleet_night_queue_file` → `$FLEET_STATE/queue`.
  - `fleet_night_cap` → integer; contents of `$FLEET_STATE/.night-cap` if present, else `1`.
- Produces (entrypoint): `start [--cap <n>]` — create `state/.night`, write `.night-cap` if `--cap` given, ensure `state/queue` exists (never truncates an existing queue), journal `night-start`. `end` — remove `state/.night`, print the debrief (Task 6 fills it in; for now a stub line), journal `night-end`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-night.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "start sets night mode, cap, and an empty queue" {
  run "$REPO_ROOT/bin/fleet-night" start --cap 2
  [ "$status" -eq 0 ]
  [ -f "$FLEET_STATE_OVERRIDE/.night" ]
  [ "$(cat "$FLEET_STATE_OVERRIDE/.night-cap")" = "2" ]
  [ -f "$FLEET_STATE_OVERRIDE/queue" ]
}

@test "end clears night mode" {
  "$REPO_ROOT/bin/fleet-night" start >/dev/null
  run "$REPO_ROOT/bin/fleet-night" end
  [ "$status" -eq 0 ]
  [ ! -f "$FLEET_STATE_OVERRIDE/.night" ]
}

@test "start defaults cap to 1 and does not truncate an existing queue" {
  echo m001 > "$FLEET_STATE_OVERRIDE/queue"
  "$REPO_ROOT/bin/fleet-night" start >/dev/null
  [ "$(cat "$FLEET_STATE_OVERRIDE/queue")" = "m001" ]
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-night"; fleet_roots; fleet_night_cap'
  [ "$output" = "1" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-night.bats`
Expected: FAIL — `bin/fleet-night` missing.

- [ ] **Step 3: Write `bin/fleet-night` (helpers + start/end)**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-night - unattended night ops (spec "Night ops"): run queue + concurrency
# pump + morning debrief. Dual-use: sourceable helpers (fleet_night_*) and a
# runnable subcommand entrypoint. Sourced section has no side effects.

fleet_night_queue_file() { printf '%s/queue' "$FLEET_STATE"; }

fleet_night_cap() {  # max concurrently-running missions (default 1)
  local c; c="$(cat "$FLEET_STATE/.night-cap" 2>/dev/null || true)"
  case "$c" in ''|*[!0-9]*) printf '1' ;; *) printf '%s' "$c" ;; esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  # shellcheck source=bin/fleet-pipeline
  . "$SCRIPT_DIR/fleet-pipeline"
  fleet_roots
  cmd="${1:-}"; shift || true
  case "$cmd" in
    start)
      cap=""
      while [ $# -gt 0 ]; do case "$1" in
        --cap) cap=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      : > "$FLEET_STATE/.night"
      [ -n "$cap" ] && printf '%s' "$cap" > "$FLEET_STATE/.night-cap"
      : >> "$(fleet_night_queue_file)"
      fleet_journal night-start "cap=$(fleet_night_cap)"
      printf 'night ops on (cap=%s)\n' "$(fleet_night_cap)" ;;
    end)
      rm -f "$FLEET_STATE/.night"
      fleet_journal night-end ""
      printf 'night ops off\n' ;;
    *) fleet_die "usage: fleet-night {start|end|queue|pump|debrief} ..." ;;
  esac
fi
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-night.bats
shellcheck bin/fleet-night
git add bin/fleet-night tests/fleet-night.bats
git commit -m "feat: fleet-night start/end + night flag, cap, queue file"
```

---

### Task 3: Admission gate + `fleet-night queue`

**Files:**
- Modify: `bin/fleet-night` (add `fleet_night_admits` + `queue` subcommand)
- Test: `tests/fleet-night.bats`

**Interfaces:**
- Produces:
  - `fleet_night_admits <id>` → returns 0 if the mission has no pending interactive stage; else prints a reason to stderr and returns 1. Rules: `campaign` needs `.artifacts.spec`; `strike` needs `.artifacts.issue`; `recon`/`fortify` need non-empty `.description`.
  - Entrypoint `queue --mission <id>` — admits then appends `<id>` to `state/queue`; on rejection prints the reason and exits non-zero (mission is not queued).

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-night.bats`:

```bash
@test "queue admits a strike with an issue and a recon" {
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 42 --id q1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon  --project acme --repo id:r --desc "why slow" --id q2 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission q1
  "$REPO_ROOT/bin/fleet-night" queue --mission q2
  run cat "$FLEET_STATE_OVERRIDE/queue"
  [[ "$output" == *"q1"* ]]
  [[ "$output" == *"q2"* ]]
}

@test "queue rejects a campaign with no spec (no unattended brainstorming)" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id q3 >/dev/null
  run "$REPO_ROOT/bin/fleet-night" queue --mission q3
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec"* ]]
  run grep -c q3 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "0" ]
}

@test "queue admits a campaign that has a spec" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --spec docs/s.md --id q4 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission q4
  run grep -c q4 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "1" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-night.bats -f "queue"`
Expected: FAIL — the `queue` subcommand hits the `*)` usage die.

- [ ] **Step 3: Add the gate + subcommand**

Add `fleet_night_admits` to the sourced-helpers section of `bin/fleet-night` (after `fleet_night_cap`):

```bash
fleet_night_admits() {  # <id> -> 0 admit, 1 reject (reason on stderr)
  local mj type; mj="$(fleet_mission_json "$1")"
  [ -f "$mj" ] || { echo "no mission $1" >&2; return 1; }
  type="$(fleet_json_get "$mj" '.type')"
  case "$type" in
    campaign)
      [ -n "$(fleet_json_get "$mj" '.artifacts.spec // ""')" ] \
        || { echo "campaign $1 needs a spec (interactive stage) — not admitted" >&2; return 1; } ;;
    strike)
      [ -n "$(fleet_json_get "$mj" '.artifacts.issue // ""')" ] \
        || { echo "strike $1 needs an issue reference — not admitted" >&2; return 1; } ;;
    recon|fortify)
      [ -n "$(fleet_json_get "$mj" '.description // ""')" ] \
        || { echo "$type $1 needs a stated goal — not admitted" >&2; return 1; } ;;
  esac
  return 0
}
```

Add the `queue` arm to the entrypoint `case` (before the `*)` arm):

```bash
    queue)
      id=""
      while [ $# -gt 0 ]; do case "$1" in
        --mission) id=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$id" ] || fleet_die "need --mission"
      fleet_night_admits "$id" || exit 1
      printf '%s\n' "$id" >> "$(fleet_night_queue_file)"
      fleet_journal night-queue "$id"
      printf '%s\n' "$id" ;;
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-night.bats
shellcheck bin/fleet-night
git add bin/fleet-night tests/fleet-night.bats
git commit -m "feat: fleet-night queue with interactive-stage admission gate"
```

---

### Task 4: `fleet-night pump` (cap-limited kickoff / pull-next)

**Files:**
- Modify: `bin/fleet-night` (add `fleet_night_active_count`, `fleet_night_dequeue`, `pump`)
- Test: `tests/fleet-night.bats`

**Interfaces:**
- Produces:
  - `fleet_night_active_count` → number of missions currently occupying a run slot (`.stage` is a pipeline stage AND `.terminal` is set).
  - `fleet_night_dequeue` → prints and removes the head queue id; returns 1 if the queue is empty.
  - Entrypoint `pump` — while `active_count < cap` and the queue is non-empty, dequeue the head mission and `fleet-spawn` its current stage (the kickoff). Idempotent per call; prints each started id.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-night.bats`:

```bash
@test "pump starts up to cap missions and leaves the rest queued" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id p1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id p2 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission p1
  "$REPO_ROOT/bin/fleet-night" queue --mission p2
  "$REPO_ROOT/bin/fleet-night" pump
  [ "$(jq -r .terminal "$(mj p1)")" != "null" ]   # p1 started
  [ "$(jq -r .terminal "$(mj p2)")" = "null" ]    # p2 held (cap 1)
  [ "$(cat "$FLEET_STATE_OVERRIDE/queue")" = "p2" ]
}

@test "pump pulls the next mission once a slot frees" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id p3 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id p4 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission p3
  "$REPO_ROOT/bin/fleet-night" queue --mission p4
  "$REPO_ROOT/bin/fleet-night" pump                       # starts p3
  jq '.stage="done"' "$(mj p3)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj p3)"   # p3 frees its slot
  "$REPO_ROOT/bin/fleet-night" pump                       # now starts p4
  [ "$(jq -r .terminal "$(mj p4)")" != "null" ]
  [ ! -s "$FLEET_STATE_OVERRIDE/queue" ]                  # queue drained
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-night.bats -f "pump"`
Expected: FAIL — the `pump` subcommand hits the `*)` usage die.

- [ ] **Step 3: Add the counters + pump**

Add to the sourced-helpers section of `bin/fleet-night`:

```bash
fleet_night_active_count() {  # missions occupying a run slot
  local mj n=0 type stage term
  for mj in "$FLEET_STATE"/missions/*/mission.json; do
    [ -e "$mj" ] || continue
    type="$(fleet_json_get "$mj" '.type')"; stage="$(fleet_json_get "$mj" '.stage')"
    fleet_pipeline_is_stage "$type" "$stage" || continue
    term="$(fleet_json_get "$mj" '.terminal')"
    [ "$term" != null ] && [ -n "$term" ] && n=$((n + 1))
  done
  printf '%d' "$n"
}

fleet_night_dequeue() {  # print+remove head id; rc 1 if empty
  local q; q="$(fleet_night_queue_file)"
  [ -s "$q" ] || return 1
  local head; head="$(head -n 1 "$q")"
  tail -n +2 "$q" > "$q.tmp" && mv "$q.tmp" "$q"
  [ -n "$head" ] || return 1
  printf '%s' "$head"
}
```

Add the `pump` arm to the entrypoint `case` (before `*)`):

```bash
    pump)
      cap="$(fleet_night_cap)"
      while [ "$(fleet_night_active_count)" -lt "$cap" ]; do
        id="$(fleet_night_dequeue)" || break
        [ -n "$id" ] || break
        stage="$(fleet_json_get "$(fleet_mission_json "$id")" '.stage')"
        if "$SCRIPT_DIR/fleet-spawn" --mission "$id" --stage "$stage" >/dev/null; then
          fleet_journal night-pump "$id $stage"
          printf '%s\n' "$id"
        else
          fleet_journal night-pump-fail "$id $stage"
        fi
      done ;;
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-night.bats
shellcheck bin/fleet-night
git add bin/fleet-night tests/fleet-night.bats
git commit -m "feat: fleet-night pump — cap-limited kickoff and pull-next"
```

---

### Task 5: Watcher pumps the queue in night mode

**Files:**
- Modify: `bin/fleet-watch` (`fleet_watch_tick` calls `fleet-night pump` when night mode is on)
- Test: `tests/fleet-watch.bats`

**Interfaces:** no new functions. Each `fleet_watch_tick`, after the mission sweep + beacon, invokes `fleet-night pump` iff `fleet_mode` is `night` — so the running heartbeat both parks stuck missions (existing behavior) and refills freed slots from the queue.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "a night-mode tick pumps the queue" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id w1 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission w1
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .terminal "$(mj w1)")" != "null" ]   # tick kicked it off
}
```

(This file already defines `mj` and loads `helpers/common`; if `mj` is absent, add `mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }` to the file.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-watch.bats -f "night-mode tick"`
Expected: FAIL — `w1.terminal` stays `null` (the tick never pumps).

- [ ] **Step 3: Wire the tick**

In `bin/fleet-watch`, at the end of `fleet_watch_tick`, add the night pump after the beacon:

```bash
fleet_watch_tick() {
  local mj id
  for mj in "$FLEET_STATE"/missions/*/mission.json; do
    [ -e "$mj" ] || continue
    id="$(fleet_json_get "$mj" '.id')"
    fleet_watch_check "$id"
  done
  fleet_watch_beacon
  [ "$(fleet_mode)" = night ] && "$SCRIPT_DIR/fleet-night" pump >/dev/null 2>&1 || true
}
```

(`fleet_mode` comes from the already-sourced `fleet-common`; `fleet-night` is invoked as a subprocess like `fleet-spawn`/`fleet-advance` already are — no new source line, no coupling.)

- [ ] **Step 4: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-watch.bats && bats tests/
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "feat: night-mode watcher tick pumps the run queue"
```

---

### Task 6: Morning debrief + end-to-end

**Files:**
- Modify: `bin/fleet-night` (add `fleet_night_debrief` + `debrief` subcommand; `end` prints it)
- Modify: `tests/fleet-e2e.bats`
- Test: `tests/fleet-night.bats`

**Interfaces:**
- Produces:
  - `fleet_night_debrief` — scans `state/missions/*`, buckets by stage, prints one line per category: `shipped` (`stage=done` with `.ship`), `awaiting approval` (`ready`), `parked`, `blocked`, `failed`, `completed` (`done` without `.ship`, e.g. recon). Each line lists mission ids or ` none`.
  - Entrypoint `debrief` — prints `fleet_night_debrief`; via `lavish-axi` when present (gated), plain text otherwise. `end` now prints the debrief before returning.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fleet-night.bats`:

```bash
@test "debrief buckets missions by outcome" {
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id d1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc b --id d2 >/dev/null
  jq '.stage="done" | .ship={mode:"local-merge",result:"merged",at:"now"}' "$(mj d1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj d1)"
  jq '.stage="parked"' "$(mj d2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj d2)"
  run "$REPO_ROOT/bin/fleet-night" debrief
  [ "$status" -eq 0 ]
  [[ "$output" == *"shipped:"*"d1"* ]]
  [[ "$output" == *"parked:"*"d2"* ]]
}

@test "end prints the debrief and clears night mode" {
  run "$REPO_ROOT/bin/fleet-night" end
  [ "$status" -eq 0 ]
  [[ "$output" == *"shipped:"* ]]
  [ ! -f "$FLEET_STATE_OVERRIDE/.night" ]
}
```

Add to `tests/fleet-e2e.bats`:

```bash
@test "night: queue two, cap 1 runs one, freed slot runs next, debrief reports" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id n1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id n2 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission n1
  "$REPO_ROOT/bin/fleet-night" queue --mission n2
  "$REPO_ROOT/bin/fleet-watch" --tick                  # pump starts n1 (cap 1)
  [ "$(jq -r .terminal "$(mj n1)")" != "null" ]
  [ "$(jq -r .terminal "$(mj n2)")" = "null" ]
  jq '.stage="done"' "$(mj n1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n1)"   # n1 finishes
  "$REPO_ROOT/bin/fleet-watch" --tick                  # freed slot -> n2 starts
  [ "$(jq -r .terminal "$(mj n2)")" != "null" ]
  run "$REPO_ROOT/bin/fleet-night" debrief
  [[ "$output" == *"completed:"*"n1"* ]]
}
```

(`tests/fleet-e2e.bats` already `load`s `helpers/common` and defines `mj`; reuse them.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-night.bats tests/fleet-e2e.bats -f "debrief|end prints|night:"`
Expected: FAIL — `debrief` hits the `*)` usage die; `end` prints no debrief.

- [ ] **Step 3: Add the debrief**

Add `fleet_night_debrief` to the sourced-helpers section of `bin/fleet-night`:

```bash
fleet_night_debrief() {  # deterministic scan; one line per outcome bucket
  local mj id stage ship shipped="" awaiting="" parked="" blocked="" failed="" completed=""
  for mj in "$FLEET_STATE"/missions/*/mission.json; do
    [ -e "$mj" ] || continue
    id="$(fleet_json_get "$mj" '.id')"; stage="$(fleet_json_get "$mj" '.stage')"
    ship="$(fleet_json_get "$mj" '.ship.mode // ""')"
    case "$stage" in
      done)    if [ -n "$ship" ]; then shipped="$shipped $id"; else completed="$completed $id"; fi ;;
      ready)   awaiting="$awaiting $id" ;;
      parked)  parked="$parked $id" ;;
      blocked) blocked="$blocked $id" ;;
      failed)  failed="$failed $id" ;;
    esac
  done
  printf 'shipped:%s\n'           "${shipped:- none}"
  printf 'awaiting approval:%s\n' "${awaiting:- none}"
  printf 'parked:%s\n'            "${parked:- none}"
  printf 'blocked:%s\n'           "${blocked:- none}"
  printf 'failed:%s\n'            "${failed:- none}"
  printf 'completed:%s\n'         "${completed:- none}"
}
```

Add the `debrief` arm to the entrypoint `case` (before `*)`):

```bash
    debrief)
      if command -v lavish-axi >/dev/null 2>&1; then
        fleet_night_debrief | lavish-axi format --title "Morning debrief" 2>/dev/null || fleet_night_debrief
      else
        fleet_night_debrief
      fi ;;
```

And make `end` print the debrief — change the `end)` arm to:

```bash
    end)
      rm -f "$FLEET_STATE/.night"
      fleet_journal night-end ""
      printf 'night ops off\n'
      fleet_night_debrief ;;
```

- [ ] **Step 4: Run to verify pass; full suite; make check; commit**

```bash
bats tests/
make check
git add bin/fleet-night tests/fleet-night.bats tests/fleet-e2e.bats
git commit -m "feat: fleet-night morning debrief (plain + optional lavish-axi) + night e2e"
```

---

## Self-Review

**Spec coverage (Night ops slice):**
- `fleet-night start`/`end` + `state/.night` + `state/queue` → Tasks 2, 6 ✓
- Admission rules (campaign→spec, strike→issue, recon/fortify→goal; no unattended brainstorming) → Task 3 ✓
- Pipeline advances as normal; park, don't ping → reused from Plans 2–3 (unchanged); **queue pulls next** → Tasks 4 (pump) + 5 (tick wiring) ✓
- Completions held per ship mode → reused from Plan 4 (pump never ships; `ready` rests, unattended already shipped) — asserted by the debrief buckets ✓
- Morning debrief: shipped / awaiting approval / parked / failed (+ completed, blocked) via `lavish-axi` when available, plain otherwise → Task 6 ✓
- Plan 4 review P4-2 (`show` var) + P4-3 (local-merge base guard) → Task 1; P4-1 (forge test export) already applied, committed in Task 1 ✓

**Deferred (later plans, explicitly):** per-project `night_cap` enforcement (v1 uses one global `--cap`; the `project.json night_cap` field stays read-only groundwork); `lavish-axi`/`gh-axi`/`tea-axi` wrappers (gated calls only); a real cron/systemd night trigger (operator runs `start`; the existing watcher daemon drives it); bunkers/loadouts (Plan 6).

**Type consistency:** `fleet_night_cap` (Task 2) is read by `pump` (Task 4). `fleet_night_admits <id>` (Task 3) is called by the `queue` arm (Task 3). `fleet_night_active_count`/`fleet_night_dequeue` (Task 4) are consumed only by `pump` (Task 4). `pump` kicks off via `fleet-spawn --mission <id> --stage <stage>` — the exact signature `fleet-spawn` has used since Plan 1. The watcher tick (Task 5) invokes `fleet-night pump` as a subprocess, mirroring its existing `fleet-spawn`/`fleet-advance`/`fleet-decision` calls. The debrief (Task 6) reads `.stage` and `.ship.mode` — the same fields `fleet-advance` and `fleet-ship` (Plan 4) write.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every code step carries complete, runnable code. The `lavish-axi` branch is an explicit availability gate with a plain-text fallback, not a stub.

**Idempotency & safety:** `start` never truncates an existing `queue` (`: >>`), so a restart mid-night preserves pending work. `pump` is safe to call every tick — it starts missions only while `active_count < cap` and stops when the queue drains; a `fleet-spawn` failure is journaled (`night-pump-fail`) and the loop continues rather than crashing the watcher (the tick wraps the pump in `|| true`). `fleet_night_dequeue` rewrites the queue via a temp file (no blank-line residue) and returns non-zero on empty. The admission gate is the only writer-side guard; re-queuing an already-running mission would just be re-counted as active and not double-started while a slot is occupied (though operators should not re-queue running ids — noted, not enforced).
```
