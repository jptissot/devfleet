# Session-Start Mode Briefing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `bin/fleet-session-start` tell an agent what it is — Commander, devfleet developer, or mission executor — instead of letting it find out by chance.

**Architecture:** A new sourced-only library `bin/fleet-session-lib` resolves the session's mode from the *location* of the checkout and composes the briefing text. `bin/fleet-session-start` calls it and prints the result. `bin/fleet-watch` gains an atomic single-instance lock, because the delivery design has two callers invoking `fleet-session-start` per session. `AGENTS.md` gets a stop-clause so an executor is safe even in a harness that never runs the script.

**Tech Stack:** bash 5, `jq`, `git`, `bats-core` ≥ 1.12, `shellcheck`.

## Global Constraints

- Every file in `bin/` is linted by `shellcheck bin/*` (`Makefile:3`). Sourced-only libraries carry `# shellcheck shell=bash` on line 2.
- Sourced libraries have **no side effects on source** — no `set`, no `mkdir`, no writes. Enforced by convention in `bin/fleet-common:3`.
- `make check` = `shellcheck bin/*` then `bats tests/`. It is green at 235 tests today and must be green at every commit.
- `fleet_mode()` already exists in `bin/fleet-common:55` and means **day/night**. Do not reuse that name or the `fleet_mode_*` prefix. This plan's functions use `fleet_session_*`.
- `fleet_roots()` (`bin/fleet-common:6`) **creates directories as a side effect** (`mkdir -p "$FLEET_STATE/missions" …`). Mode detection must run **before** `fleet_roots` is called, or detecting a worktree will already have polluted it with a `state/` tree.
- Commit messages: Conventional Commits, subject ≤ 50 chars.

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/fleet-session-lib` (create) | Detect session mode from checkout location; compose briefing text. Sourced only. |
| `bin/fleet-session-start` (modify) | Call the lib before `fleet_roots`; print the briefing; keep today's reconcile behavior. |
| `bin/fleet-watch` (modify) | Atomic single-instance lock on the daemon path. |
| `tests/fleet-watch-lock.bats` (create) | Lock behavior. |
| `tests/fleet-session-mode.bats` (create) | Mode detection + briefing. |
| `tests/fleet-session-start.bats` (modify) | Existing 4 tests keep passing; add the bootstrap-still-works assertion. |
| `AGENTS.md` (modify) | Stop-clause, mode preamble, Operate/Develop headings. |
| `CLAUDE.md` (create) | Two-line pointer for Claude Code. |
| `.claude/settings.json` (create, tracked) | `SessionStart` hook. |

---

### Task 1: Single-instance lock in `fleet-watch`

Prerequisite for Task 4: once the hook *and* `AGENTS.md` both invoke `fleet-session-start`, two watchers would run against the same state, both advancing stages.

**Files:**
- Modify: `bin/fleet-watch:28` (beside `fleet_watch_beacon`), and the daemon path at `bin/fleet-watch:96-110`
- Test: `tests/fleet-watch-lock.bats` (create)

**Interfaces:**
- Consumes: `fleet_journal` (`bin/fleet-common:35`), `$FLEET_STATE` (`bin/fleet-common:11`)
- Produces: `fleet_watch_claim()` → exit 0 when this process now holds the lock, exit 1 when a live watcher already holds it. Lock is the directory `$FLEET_STATE/.watch-lock` containing a `pid` file.

Guard the **loop** path only. `--tick` runs one synchronous tick and is used by 20+ existing tests; guarding it would break them. `--ticks <n>` is used by no existing test and is guarded along with the daemon.

- [ ] **Step 1: Write the failing tests**

Create `tests/fleet-watch-lock.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "a live lock makes a second watcher exit 0 without starting" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"   # $$ is bats: alive
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  ! grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a stale lock is claimed, not honored" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  # A pid that cannot be alive: reap a real child, then reuse its pid.
  sleep 0 & dead=$!; wait $dead 2>/dev/null || true
  echo "$dead" > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a lock with no pid file is claimed" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "the lock is released when the watcher exits" {
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  [ ! -d "$FLEET_STATE_OVERRIDE/.watch-lock" ]
}

@test "--tick is not guarded by the lock" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-watch-lock.bats`
Expected: FAIL — the second watcher starts anyway, so `watch-start` is journaled in test 1 and `.watch-lock` still exists in test 4.

- [ ] **Step 3: Add `fleet_watch_claim`**

In `bin/fleet-watch`, directly after `fleet_watch_beacon()` (line 28):

```bash
# Single-instance guard. `mkdir` is atomic, so two racing watchers cannot both
# claim. A lock whose pid is gone (crash, kill -9) is stale and gets claimed;
# honoring it would wedge the fleet until a human deleted a file.
fleet_watch_claim() {
  local lock="$FLEET_STATE/.watch-lock" old
  if ! mkdir "$lock" 2>/dev/null; then
    old="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      return 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$lock/pid"
  return 0
}
```

- [ ] **Step 4: Guard the loop path**

In `bin/fleet-watch`, replace the block starting `fleet_journal watch-start` (line 100) with:

```bash
if ! fleet_watch_claim; then
  fleet_journal watch-skip "live watcher holds the lock"
  exit 0
fi
trap 'rm -rf "$FLEET_STATE/.watch-lock"' EXIT

fleet_journal watch-start "interval=${INTERVAL}s ticks=${TICKS:-inf}"
```

The `--tick` early-exit at line 95 stays above this and is untouched.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-watch-lock.bats`
Expected: 5 tests PASS

- [ ] **Step 6: Run the full suite and the linter**

Run: `make check`
Expected: shellcheck clean, 240 tests pass

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-watch tests/fleet-watch-lock.bats
git commit -m "fix: single-instance lock for the watcher"
```

---

### Task 2: Mode detection in `fleet-session-lib`

**Files:**
- Create: `bin/fleet-session-lib`
- Test: `tests/fleet-session-mode.bats` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks. Uses `git` only. Must not call `fleet_roots`.
- Produces:
  - `fleet_session_brief_file()` → prints the path of the first `.devfleet/*.brief` in the checkout, or nothing. Exit 0 if found, 1 if not.
  - `fleet_session_linked_worktree()` → exit 0 if the cwd is inside a **linked** git worktree, 1 if the fleet root or not a git repo at all.
  - `fleet_session_mode()` → prints exactly one of `execute`, `root`, `orphan`. Exit 0 for `execute`/`root`, exit 3 for `orphan`.

Detection is by location, not by state: `FLEET_HOME` is inheritable through the environment, so an executor that inherits it would pass any state-based check. `--git-dir` versus `--git-common-dir` describes the checkout the agent is actually standing in, and cannot be inherited.

`execute` is resolved **first**, before any git question, for the same reason.

- [ ] **Step 1: Write the failing tests**

Create `tests/fleet-session-mode.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

# Run a fleet_session_* function with cwd set to $1.
sess() { local d=$1; shift; ( cd "$d" && bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; '"$*" ); }

@test "a mission worktree with a brief is execute mode" {
  read -r repo wt <<<"$(fleet_make_repo_worktree m1)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m1.spec.brief"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = execute ]
}

@test "execute wins even when FLEET_HOME points at a real fleet root" {
  read -r repo wt <<<"$(fleet_make_repo_worktree m2)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m2.plan.brief"
  run env FLEET_HOME="$FLEET_HOME" sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = execute ]
}

@test "the brief file path is reported" {
  read -r repo wt <<<"$(fleet_make_repo_worktree m3)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m3.review.brief"
  run sess "$wt" 'fleet_session_brief_file'
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3.review.brief" ]]
}

@test "a linked worktree with no brief is orphan mode" {
  read -r repo wt <<<"$(fleet_make_repo_worktree m4)"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 3 ]
  [ "$output" = orphan ]
}

@test "the main checkout is root mode" {
  read -r repo wt <<<"$(fleet_make_repo_worktree m5)"
  run sess "$repo" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = root ]
}

@test "a directory that is not a git repo at all is root mode" {
  mkdir -p "$FLEET_TMP/plain"
  run sess "$FLEET_TMP/plain" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = root ]
}
```

`fleet_make_repo_worktree` (`tests/helpers/common.bash`) already builds a real repo plus a real linked worktree and echoes both paths tab-separated.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-session-mode.bats`
Expected: FAIL — `bin/fleet-session-lib: No such file or directory`

- [ ] **Step 3: Write `bin/fleet-session-lib`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-session-lib - session mode detection + briefing text. Sourced only; no
# `set`, no side effects on source, and NO fleet_roots (it mkdirs state, which
# must not happen in a worktree). (bin/fleet-common:3 discipline)

# The rendered brief fleet-spawn:86 writes into a mission worktree. Its presence
# is the one signal that cannot be inherited through the environment.
fleet_session_brief_file() {
  local top b
  top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for b in "$top"/.devfleet/*.brief; do
    [ -e "$b" ] || continue
    printf '%s\n' "$b"
    return 0
  done
  return 1
}

# True in a linked worktree: git keeps its gitdir under the main repo's
# .git/worktrees/, so --git-dir and --git-common-dir differ. Not a git repo at
# all counts as false — a plain directory is not somebody's worktree.
fleet_session_linked_worktree() {
  local d c
  d="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  c="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd)" || return 1
  [ "$d" != "$c" ]
}

# execute -> a mission worktree with a brief beside us
# root    -> the fleet root (or any non-worktree checkout)
# orphan  -> a linked worktree with no brief: refuse, exit 3
fleet_session_mode() {
  if fleet_session_brief_file >/dev/null; then
    printf 'execute\n'; return 0
  fi
  if fleet_session_linked_worktree; then
    printf 'orphan\n'; return 3
  fi
  printf 'root\n'; return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-session-mode.bats`
Expected: 6 tests PASS

- [ ] **Step 5: Lint**

Run: `shellcheck bin/fleet-session-lib`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-session-lib tests/fleet-session-mode.bats
git commit -m "feat: session mode detection by checkout location"
```

---

### Task 3: Briefing text, wired into `fleet-session-start`

**Files:**
- Modify: `bin/fleet-session-lib` (add the two briefing functions)
- Modify: `bin/fleet-session-start:12` (detect before `fleet_roots`) and `:48` (replace the output line)
- Test: `tests/fleet-session-mode.bats` (extend), `tests/fleet-session-start.bats` (extend)

**Interfaces:**
- Consumes: `fleet_session_mode`, `fleet_session_brief_file` from Task 2.
- Produces:
  - `fleet_session_brief_execute()` → prints the executor briefing. Takes the brief path as `$1`.
  - `fleet_session_brief_root()` → prints the Commander briefing. Takes `$1` = mission count, `$2` = open-decision count, `$3` = the existing reconcile line.

Mission and decision counts are passed in rather than read, so the lib stays free of `fleet_roots` and stays testable without a fleet.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-session-mode.bats`:

```bash
@test "the executor briefing names the mission, the stage, and fleet-done" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_execute /w/.devfleet/m9.review.brief'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the Commander"* ]]
  [[ "$output" == *"m9"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"fleet-done m9"* ]]
  [[ "$output" != *"you are the Commander of this fleet"* ]]
}

@test "the root briefing names both modes and the announce rule" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_root 0 0 "reconciled 0 missions, 0 drifted"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"operate"* ]]
  [[ "$output" == *"develop"* ]]
  [[ "$output" == *"END YOUR TURN"* ]]
  [[ "$output" == *"Announce the inference"* ]]
  [[ "$output" == *"reconciled 0 missions, 0 drifted"* ]]
}

@test "the root briefing renders live counts" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_root 2 1 "reconciled 2 missions, 0 drifted"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 missions in flight"* ]]
  [[ "$output" == *"1 open decisions"* ]]
  [[ "$output" != *"idle"* ]]
}
```

Append to `tests/fleet-session-start.bats`:

```bash
@test "session start briefs the Commander and both root modes" {
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"you are the Commander of this fleet"* ]]
  [[ "$output" == *"operate"* ]]
  [[ "$output" == *"develop"* ]]
  [[ "$output" == *"reconciled 0 missions, 0 drifted"* ]]
}

@test "session start in a mission worktree briefs an executor, not a Commander" {
  read -r repo wt <<<"$(fleet_make_repo_worktree w1)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/w1.execute.brief"
  run bash -c "cd '$wt' && '$REPO_ROOT/bin/fleet-session-start' --no-watch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the Commander"* ]]
  [[ "$output" != *"you are the Commander of this fleet"* ]]
}

@test "session start refuses a worktree with no brief and creates no state" {
  read -r repo wt <<<"$(fleet_make_repo_worktree w2)"
  run bash -c "cd '$wt' && FLEET_HOME='$wt' '$REPO_ROOT/bin/fleet-session-start' --no-watch"
  [ "$status" -ne 0 ]
  [ ! -d "$wt/state" ]
}

@test "bootstrap still runs at the fleet root when roles.json is absent" {
  rm -f "$FLEET_CONFIG_OVERRIDE/roles.json"
  harness="$FLEET_TMP/harness"; mkdir -p "$harness"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$harness/claude"; chmod +x "$harness/claude"
  PATH="$harness:$PATH" run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_CONFIG_OVERRIDE/roles.json" ]
  [[ "$output" == *"you are the Commander of this fleet"* ]]
}
```

That last test is the contradiction caught in spec self-review: a fresh fleet has no `roles.json`, and must be read as a fleet root rather than a wrong location.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-session-mode.bats tests/fleet-session-start.bats`
Expected: FAIL — `fleet_session_brief_execute: command not found`, and the session-start tests still print only the one-line reconcile output.

- [ ] **Step 3: Add the briefing functions**

Append to `bin/fleet-session-lib`:

```bash
# <brief-path> -> the executor briefing. The filename carries the identity:
# .devfleet/<mission>.<stage>.brief (fleet-spawn:86).
fleet_session_brief_execute() {
  local path=$1 base mission stage
  base="$(basename "$path" .brief)"
  mission="${base%%.*}"; stage="${base#*.}"
  cat <<EOF
DEVFLEET — you are a mission executor, not the Commander.
mission $mission, stage $stage
Your brief is $path. It is the whole job.
Do not spawn, advance, ship, or answer decisions. AGENTS.md is not addressed to you.
When finished: fleet-done $mission done|blocked:<question>|failed:<reason>
EOF
}

# <missions> <decisions> <reconcile-line> -> the fleet-root briefing.
fleet_session_brief_root() {
  local missions=$1 decisions=$2 reconciled=$3 state
  if [ "$missions" -eq 0 ] && [ "$decisions" -eq 0 ]; then
    state="idle"
  else
    state="$missions missions in flight | $decisions open decisions"
  fi
  cat <<EOF
DEVFLEET — you are the Commander of this fleet.
fleet: $state
$reconciled

MODE: state which mode you are in as your first line, before acting.
  operate  — fleet work: missions, decisions, reports on fleet repos.
             Act once, then END YOUR TURN. Never poll. The watcher wakes you.
  develop  — feature work on devfleet itself, here in this checkout.
             You do the work directly. Do not spawn a mission against devfleet.
             The end-your-turn rule does not apply; work the task to completion.
Infer from the request. Announce the inference. One word from the user corrects it.
EOF
}
```

- [ ] **Step 4: Detect before `fleet_roots` in `fleet-session-start`**

In `bin/fleet-session-start`, add the lib to the source block after the `fleet-config` line (line 11):

```bash
# shellcheck source=bin/fleet-session-lib
. "$SCRIPT_DIR/fleet-session-lib"
```

Then, immediately **before** the `fleet_roots` call on line 12, insert:

```bash
# Resolve mode before fleet_roots: fleet_roots mkdirs $FLEET_STATE, and doing
# that inside a worktree is exactly the pollution this guard exists to prevent.
SESSION_MODE="$(fleet_session_mode || true)"
case "$SESSION_MODE" in
  execute)
    fleet_session_brief_execute "$(fleet_session_brief_file)"
    exit 0 ;;
  orphan)
    echo "error: linked worktree with no .devfleet brief — not a fleet root" >&2
    exit 3 ;;
esac

fleet_roots
```

Delete the bare `fleet_roots` on the old line 12.

- [ ] **Step 5: Replace the output line**

At the end of `bin/fleet-session-start`, replace:

```bash
printf 'reconciled %d missions, %d drifted\n' "$reconciled" "$drifted"
```

with:

```bash
open_decisions="$(fleet_decision_list --open | grep -c . || true)"
fleet_session_brief_root "$reconciled" "$open_decisions" \
  "$(printf 'reconciled %d missions, %d drifted' "$reconciled" "$drifted")"
```

`fleet_decision_list` comes from `bin/fleet-decision`, which `fleet-session-start` does not yet source. Add it to the source block beside the others:

```bash
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/fleet-session-mode.bats tests/fleet-session-start.bats`
Expected: 9 + 8 tests PASS, including the 4 pre-existing session-start tests

- [ ] **Step 7: Run the full suite and the linter**

Run: `make check`
Expected: shellcheck clean, 253 tests pass

- [ ] **Step 8: Commit**

```bash
git add bin/fleet-session-lib bin/fleet-session-start tests/fleet-session-mode.bats tests/fleet-session-start.bats
git commit -m "feat: session-start briefs the agent's mode"
```

---

### Task 4: Delivery — hook, `CLAUDE.md`, `AGENTS.md` stop-clause

**Files:**
- Create: `.claude/settings.json` (tracked — it must reach worktrees)
- Create: `CLAUDE.md`
- Modify: `AGENTS.md` (stop-clause + preamble + headings)

**Interfaces:**
- Consumes: `bin/fleet-session-start` from Task 3, `fleet_watch_claim` from Task 1 (the hook is the second caller that made the lock necessary).
- Produces: no code interface. This is the delivery layer.

- [ ] **Step 1: Create the hook**

`.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bin/fleet-session-start"
          }
        ]
      }
    ]
  }
}
```

Tracked on purpose. It reaches every worktree, which is correct now that Task 2 resolves `execute` — an executor gets the executor briefing instead of nothing.

- [ ] **Step 2: Create `CLAUDE.md`**

```markdown
# DevFleet

Run `bin/fleet-session-start` before anything else, then obey the briefing it prints.

It tells you whether you are the Commander of this fleet, a developer working on
devfleet itself, or an executor running a mission brief. All rules live in `AGENTS.md`,
under the heading for the mode the briefing names.
```

No rules of its own. Two copies of a rule drift, and the copy the agent reads is the stale one.

- [ ] **Step 3: Add the stop-clause to `AGENTS.md`**

Insert as the **first block of the file**, above the current `# DevFleet — Commander instructions` heading:

```markdown
<EXECUTOR-STOP>
If a `.devfleet/` directory with a `*.brief` file sits beside this file, you are a mission
executor and this document is NOT addressed to you. Read your brief; it is the whole job.
Do not spawn, advance, ship, or answer decisions. When finished:
`fleet-done <mission> done|blocked:<question>|failed:<reason>`
</EXECUTOR-STOP>

Run `bin/fleet-session-start` first. It prints your mode. This file's **Operate** section
applies in `operate` mode and its **Develop** section applies in `develop` mode.
```

An executor whose harness never runs the script still meets this on line 1.

- [ ] **Step 4: Add the Operate and Develop headings**

Put today's content — everything from `You are the **Commander** of this fleet.` through the end of the Configuration section — under a new `## Operate` heading, **verbatim**. No rule changes in this task.

Then append:

```markdown
## Develop

Feature work on devfleet itself. You do it directly, here in this checkout.

- Do **not** spawn a mission against devfleet. There is no sub-Commander; you are the engineer.
- The `operate` rules do not apply. Do not end your turn mid-task waiting for a watcher —
  nothing is going to wake you. Work the task to completion.
- TDD: failing test first, then the minimal implementation.
- `make check` must be green — `shellcheck bin/*` plus the full bats suite — before you call
  anything done.
- Sourced libraries in `bin/` have no side effects on source: no `set`, no `mkdir`, no writes.
```

- [ ] **Step 5: Verify the hook fires and briefs correctly**

Run: `bin/fleet-session-start --no-watch`
Expected: output begins `DEVFLEET — you are the Commander of this fleet.` and contains both mode descriptions.

Run: `git ls-files .claude/`
Expected: `.claude/settings.json`

- [ ] **Step 6: Verify an executor is not misled**

Run from the repo root:

```bash
root="$PWD"; tmp="$(mktemp -d)"
git worktree add -q "$tmp/wt" -b throwaway-mode-check
mkdir -p "$tmp/wt/.devfleet"; : > "$tmp/wt/.devfleet/x1.review.brief"
(cd "$tmp/wt" && "$tmp/wt/bin/fleet-session-start" --no-watch)
```

The worktree has its own copy of `bin/`, which is the realistic case — an executor
runs the copy it is standing in, not the fleet root's.

Expected: prints `DEVFLEET — you are a mission executor, not the Commander.`, names `x1` and `review`, and does **not** print the Commander line. Then clean up:

```bash
cd "$root"
git worktree remove --force "$tmp/wt"; git branch -D throwaway-mode-check; rm -rf "$tmp"
```

- [ ] **Step 7: Run the full suite and the linter**

Run: `make check`
Expected: shellcheck clean, 253 tests pass

- [ ] **Step 8: Commit**

```bash
git add .claude/settings.json CLAUDE.md AGENTS.md
git commit -m "docs: mode briefing delivery and executor stop-clause"
```

---

## Verification

After Task 4, from a clean checkout:

| Check | Command | Expected |
|---|---|---|
| Suite green | `make check` | shellcheck clean, 253 tests pass |
| Commander briefed | `bin/fleet-session-start --no-watch` | Commander line + both modes |
| No double watcher | `bin/fleet-session-start` twice | one `watch-start` in `state/journal.log`, one `watch-skip` |
| Executor not misled | Task 4 Step 6 | executor briefing, no Commander line |
