# DevFleet Core Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the deterministic, zero-token bash state machine that creates a mission (with an Orca worktree behind a backend seam), spawns each stage's agent, and advances the mission through its typed pipeline via completion markers — driven entirely from mission-type JSON and tested end-to-end against a fake `orca` and synthetic markers.

**Architecture:** Three sourced libs (`fleet-common`, `fleet-backend`, `fleet-pipeline`) plus five entrypoint scripts (`fleet-mission`, `fleet-done`, `fleet-spawn`, `fleet-advance`, `fleet-status`). All Orca calls are confined to `fleet-backend` (the one seam a tmux fallback would later replace). Pipelines are pure data (`config/missions/<type>.json`); `fleet-advance` is a single-owner, fail-closed transition reader over that data. Mission truth is `mission.json` (durable identity/config); completion is a separate append-only marker the worker writes — the load-bearing "event-log vs current-state" split inherited from the firstmate predecessor.

**Tech Stack:** Bash, `jq` (all JSON), `bats-core` 1.12 (tests), `shellcheck` (lint). Orca CLI is the runtime backend but is *stubbed by a fake `orca` on `PATH`* for all Phase-1 tests — no real Orca, no LLM, no containers.

**Reference codebase:** `~/repos/kenchenguid/firstmate` is the `fm-*` predecessor. Mirror its idioms (cited inline as `firstmate:bin/<file>:<lines>`). Do NOT port its `.no-mistakes.yaml` gates, `*-command-policy.mjs` pretool hooks, or `fm-supervise-daemon.sh` tree — DevFleet's spec lists those as non-goals.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md`. This plan implements the "core deterministic pipeline" slice only. Out of scope (each its own follow-on plan): `fleet-watch` daemon + loop/stall + `fleet-session-start`, decision inbox + `fleet-decide`, ship modes + forge, night ops, bunkers + `fleet-loadout`, axi integrations.

## Global Constraints

- **Shebang/flags:** entrypoints start `#!/usr/bin/env bash` + `set -euo pipefail`. Sourced libs (`fleet-common`, `fleet-backend`, `fleet-pipeline`) start `#!/usr/bin/env bash` + `# shellcheck shell=bash` and set **no** `set` flags and cause **no** side effects on source (firstmate:bin/fm-marker-lib.sh:38).
- **Naming:** entrypoints `bin/fleet-<name>` (no extension, matching the spec component table). Functions namespaced `fleet_<area>_<verb>()`. Backend adapter functions `fleet_backend_orca_<verb>()`.
- **Env-overridable roots** (tests set these to temp dirs; firstmate:bin/fm-spawn.sh:84-90):
  - `FLEET_ROOT` = `${FLEET_ROOT_OVERRIDE:-<repo dir>}`
  - `FLEET_HOME` = `${FLEET_HOME:-$FLEET_ROOT}`
  - `FLEET_STATE` = `${FLEET_STATE_OVERRIDE:-$FLEET_HOME/state}`
  - `FLEET_CONFIG` = `${FLEET_CONFIG_OVERRIDE:-$FLEET_HOME/config}`
  - `FLEET_PROJECTS` = `${FLEET_PROJECTS_OVERRIDE:-$FLEET_HOME/projects}`
- **Sourcing:** always `. "$SCRIPT_DIR/fleet-common"` (dot, not `source`) with a `# shellcheck source=bin/fleet-common` directive above each (firstmate:bin/fm-spawn.sh:101-110).
- **JSON:** every read/write goes through `jq`. Never hand-parse JSON. Mutations are write-tmp-then-`mv` (atomic).
- **Completion contract:** an agent finishes a stage by running `fleet-done <mission-id> <status>` where `status ∈ done | blocked:<question> | failed:<reason>`. This appends one line to `<worktree>/.devfleet/<mission-id>.status` — inside the worktree so it is identical from bare and (later) bunkered operators (spec "Completion protocol").
- **Mission states:** `<stage names of the type> | ready | done | parked | blocked | failed`.
- **Determinism:** no wall-clock or random values in control flow that a test asserts on. `fleet-mission` accepts `--id` to make ids deterministic in tests; production derives ids from a sequence file.
- **Lint/test:** `shellcheck bin/*` must pass; `bats tests/` must pass. Every task ends green on both.

## File Structure

```
bin/
  fleet-common        # sourced lib: roots, jq get/set, journal, id helpers
  fleet-backend       # sourced lib: ALL orca calls (status/worktree/terminal verbs)
  fleet-pipeline      # sourced lib: read mission-type stage graph (next/pass/fail/entry/limit)
  fleet-mission       # entrypoint: create mission.json + orca worktree + entry stage
  fleet-done          # entrypoint: append completion marker into worktree/.devfleet/
  fleet-spawn         # entrypoint: build brief + launch cmd, create orca terminal (--dry-run)
  fleet-advance       # entrypoint: read marker + mission.json + stage graph -> next stage/state
  fleet-status        # entrypoint: one-line-per-mission snapshot
config/
  roles.json          # role -> harness+cmd (frontier/executor); git-ignored, seeded from .example
  roles.json.example
  missions/
    campaign.json     # spec -> plan -> execute -> review <=> fix -> ready
    strike.json       # plan -> execute -> review <=> fix -> ready
    recon.json        # recon -> report (no ship)
    fortify.json      # audit -> execute -> review <=> fix -> ready
prompts/
  spec.txt plan.txt execute.txt review.txt fix.txt audit.txt recon.txt   # stage brief templates
state/                # runtime (git-ignored): missions/<id>/, journal.log, .mission-seq
tests/
  helpers/common.bash # bats helper: temp roots, fake orca installer, assert helpers, config seed
  fleet-common.bats
  fleet-backend.bats
  fleet-pipeline.bats
  fleet-mission.bats
  fleet-done.bats
  fleet-spawn.bats
  fleet-advance.bats
  fleet-status.bats
  fleet-e2e.bats
.gitignore            # state/, config/roles.json, .agent-sandbox/state/
```

---

### Task 1: Repo scaffolding + `fleet-common`

**Files:**
- Create: `bin/fleet-common`
- Create: `.gitignore`
- Create: `tests/helpers/common.bash`
- Test: `tests/fleet-common.bats`

**Interfaces:**
- Produces (sourced by every other script):
  - `fleet_roots()` — sets globals `FLEET_ROOT`, `FLEET_HOME`, `FLEET_STATE`, `FLEET_CONFIG`, `FLEET_PROJECTS` from `*_OVERRIDE` env or defaults; `mkdir -p` the state dirs.
  - `fleet_json_get <file> <jq-filter>` — prints value, `-r` raw.
  - `fleet_json_set <file> <jq-filter>` — applies filter, atomic write-back.
  - `fleet_journal <event> [detail]` — appends `<iso-ts>\t<event>\t<detail>` to `$FLEET_STATE/journal.log` (best-effort).
  - `fleet_next_id` — prints `m001`, `m002`, … from `$FLEET_STATE/.mission-seq`.
  - `fleet_mission_dir <id>` / `fleet_mission_json <id>` — path helpers.
  - `fleet_die <msg>` — print `error: <msg>` to stderr, exit 1.

- [ ] **Step 1: Write the failing test**

Create `tests/helpers/common.bash`:

```bash
# shellcheck shell=bash
# Shared bats helpers: temp roots, fake orca, assertions, config seed.

fleet_setup_home() {
  FLEET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
  export FLEET_TMP
  export FLEET_ROOT_OVERRIDE="$REPO_ROOT"
  export FLEET_HOME="$FLEET_TMP/home"
  export FLEET_STATE_OVERRIDE="$FLEET_HOME/state"
  export FLEET_CONFIG_OVERRIDE="$FLEET_HOME/config"
  export FLEET_PROJECTS_OVERRIDE="$FLEET_HOME/projects"
  mkdir -p "$FLEET_HOME" "$FLEET_STATE_OVERRIDE" "$FLEET_CONFIG_OVERRIDE" "$FLEET_PROJECTS_OVERRIDE"
}

fleet_teardown_home() {
  [ -n "${FLEET_TMP:-}" ] && rm -rf "$FLEET_TMP"
}

# Copy the real mission-type configs + roles + prompts into the temp home.
fleet_seed_config() {
  mkdir -p "$FLEET_CONFIG_OVERRIDE/missions"
  cp "$REPO_ROOT"/config/missions/*.json "$FLEET_CONFIG_OVERRIDE/missions/"
  cp "$REPO_ROOT"/config/roles.json.example "$FLEET_CONFIG_OVERRIDE/roles.json"
  cp -r "$REPO_ROOT"/prompts "$FLEET_HOME/prompts"
}

# Install a fake `orca` on PATH that logs argv and replays canned responses.
# (firstmate:tests/fm-backend-orca.test.sh:11-40)
fleet_install_fake_orca() {
  FAKEBIN="$FLEET_TMP/fakebin"; mkdir -p "$FAKEBIN"
  export FLEET_ORCA_LOG="$FLEET_TMP/orca.log"; : > "$FLEET_ORCA_LOG"
  export FLEET_FAKE_WT_ROOT="$FLEET_TMP/worktrees"; mkdir -p "$FLEET_FAKE_WT_ROOT"
  export FLEET_FAKE_TERM_SEQ="$FLEET_TMP/.term-seq"; echo 0 > "$FLEET_FAKE_TERM_SEQ"
  cat > "$FAKEBIN/orca" <<'ORCA'
#!/usr/bin/env bash
set -u
{ printf 'orca'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_ORCA_LOG"
val() { local flag=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$flag" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "status --json"|"status ")
    printf '{"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  "worktree create")
    name="$(val --name "$@")"; repo="$(val --repo "$@")"
    path="$FLEET_FAKE_WT_ROOT/$name"; mkdir -p "$path"
    printf '{"result":{"worktree":{"id":"%s::%s","path":"%s"}}}\n' "${repo#id:}" "$path" "$path" ;;
  "worktree rm")   printf '{"result":{"ok":true}}\n' ;;
  "terminal create")
    n=$(( $(cat "$FLEET_FAKE_TERM_SEQ") + 1 )); echo "$n" > "$FLEET_FAKE_TERM_SEQ"
    printf '{"result":{"terminal":{"handle":"term_%03d"}}}\n' "$n" ;;
  "terminal wait")
    printf '{"result":{"wait":{"satisfied":true,"status":"running","blockedReason":null,"exitCode":null}}}\n' ;;
  "terminal send"|"terminal read"|"terminal stop")
    printf '{"result":{"terminal":{"tail":[]}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
ORCA
  chmod +x "$FAKEBIN/orca"
  export PATH="$FAKEBIN:$PATH"
}

# argv log assertion: every field 0x1f-separated (firstmate:tests/fm-backend-orca.test.sh:84)
orca_log_has() { grep -qF "$1" "$FLEET_ORCA_LOG"; }
```

Create `tests/fleet-common.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

@test "fleet_roots sets and creates state dir from overrides" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; echo "$FLEET_STATE"; [ -d "$FLEET_STATE/missions" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == "$FLEET_STATE_OVERRIDE" ]]
}

@test "fleet_json_get/set round-trips a value" {
  f="$FLEET_TMP/x.json"; echo '{"stage":"spec"}' > "$f"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_json_set "'"$f"'" ".stage=\"plan\""; fleet_json_get "'"$f"'" ".stage"'
  [ "$status" -eq 0 ]
  [[ "$output" == "plan" ]]
}

@test "fleet_next_id increments" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; echo "$(fleet_next_id)$(fleet_next_id)"'
  [ "$status" -eq 0 ]
  [[ "$output" == "m001m002" ]]
}

@test "fleet_journal appends a tab-separated line" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; fleet_journal spawn "m001 spec"; cat "$FLEET_STATE/journal.log"'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"spawn"$'\t'"m001 spec"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-common.bats`
Expected: FAIL — `bin/fleet-common` does not exist (`No such file`).

- [ ] **Step 3: Write `bin/fleet-common`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-common - shared roots, json helpers, journal, ids. Sourced only; no `set`,
# no side effects on source. (firstmate:bin/fm-marker-lib.sh:38 discipline)

fleet_roots() {
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FLEET_ROOT="${FLEET_ROOT_OVERRIDE:-$(cd "$self_dir/.." && pwd)}"
  FLEET_HOME="${FLEET_HOME:-$FLEET_ROOT}"
  FLEET_STATE="${FLEET_STATE_OVERRIDE:-$FLEET_HOME/state}"
  FLEET_CONFIG="${FLEET_CONFIG_OVERRIDE:-$FLEET_HOME/config}"
  FLEET_PROJECTS="${FLEET_PROJECTS_OVERRIDE:-$FLEET_HOME/projects}"
  mkdir -p "$FLEET_STATE/missions" "$FLEET_STATE/decisions"
}

fleet_die() { echo "error: $*" >&2; exit 1; }

fleet_json_get() {  # <file> <jq-filter>
  jq -r "$2" "$1"
}

fleet_json_set() {  # <file> <jq-filter>
  local f=$1 filter=$2 tmp
  tmp="$(mktemp)"
  jq "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
}

fleet_journal() {  # <event> [detail]
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\n' "$ts" "$1" "${2:-}" >> "$FLEET_STATE/journal.log" || true
}

fleet_next_id() {
  local seq_file="$FLEET_STATE/.mission-seq" n
  n=$(( $(cat "$seq_file" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$seq_file"
  printf 'm%03d' "$n"
}

fleet_mission_dir() {  # <id>
  printf '%s/missions/%s' "$FLEET_STATE" "$1"
}
fleet_mission_json() {  # <id>
  printf '%s/missions/%s/mission.json' "$FLEET_STATE" "$1"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-common.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Create `.gitignore` and lint**

Create `.gitignore`:

```
state/
config/roles.json
.agent-sandbox/state/
```

Run: `shellcheck bin/fleet-common`
Expected: no output (exit 0). If `shellcheck` is missing: `sudo dnf install -y ShellCheck` (Fedora) then re-run.

- [ ] **Step 6: Commit**

```bash
chmod +x bin/fleet-common
git add bin/fleet-common .gitignore tests/helpers/common.bash tests/fleet-common.bats
git commit -m "feat: fleet-common lib (roots, json, journal, ids) + test harness"
```

---

### Task 2: `fleet-backend` (Orca verb seam) + fake-orca tests

**Files:**
- Create: `bin/fleet-backend`
- Test: `tests/fleet-backend.bats`

**Interfaces:**
- Consumes: nothing (self-contained; calls `orca` on PATH).
- Produces:
  - `fleet_backend_status_ready` — returns 0 iff `orca status --json` reports `.result.runtime.reachable == true`.
  - `fleet_backend_worktree_create <repo-selector> <name>` — runs `orca worktree create --repo <sel> --name <name> --no-parent --setup skip --json`; prints `<worktree-id>\t<path>` (TAB-joined; firstmate:bin/backends/orca.sh:153).
  - `fleet_backend_worktree_rm <worktree-id>` — `orca worktree rm --worktree id:<id> --force --json`.
  - `fleet_backend_terminal_create <worktree-id> <title> <command>` — prints the terminal `handle`.
  - `fleet_backend_terminal_send <handle> <text>` and `fleet_backend_terminal_enter <handle>` — send text / bare Enter (`--enter`; there is **no** `--key` flag, verified in spec).
  - `fleet_backend_terminal_idle <handle> <timeout-ms>` — prints `<satisfied>\t<blockedReason>` from `terminal wait --for tui-idle`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-backend.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home
  fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "status_ready returns 0 when runtime reachable" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_status_ready'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fstatus\x1f--json'
}

@test "worktree_create returns id and path, tab-joined, and calls orca correctly" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_worktree_create id:repo1 fleet-m001'
  [ "$status" -eq 0 ]
  id="${output%%$'\t'*}"; path="${output#*$'\t'}"
  [[ "$id" == "repo1::"* ]]
  [ -d "$path" ]
  orca_log_has $'orca\x1fworktree\x1fcreate\x1f--repo\x1fid:repo1\x1f--name\x1ffleet-m001\x1f--no-parent\x1f--setup\x1fskip\x1f--json'
}

@test "terminal_create returns a handle" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_create "r::/w" title "claude"'
  [ "$status" -eq 0 ]
  [[ "$output" == term_* ]]
}

@test "terminal_enter uses --enter not --key" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_enter term_001'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_001\x1f--enter'
  ! orca_log_has '--key'
}

@test "terminal_idle reports satisfied and blockedReason" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_idle term_001 5000'
  [ "$status" -eq 0 ]
  [[ "$output" == "true"$'\t'"null" ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-backend.bats`
Expected: FAIL — `bin/fleet-backend` missing.

- [ ] **Step 3: Write `bin/fleet-backend`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-backend - the ONE seam for all Orca calls. A tmux + git-worktree fallback
# would replace this file wholesale (spec "Thin boundaries"). Every op shells
# `orca <noun> <verb> --json` and parses with jq. Sourced only; no `set`.
# (Template: firstmate:bin/backends/orca.sh)

fleet_backend_status_ready() {
  local out
  out="$(orca status --json 2>/dev/null)" || return 1
  [ "$(printf '%s' "$out" | jq -r '.result.runtime.reachable')" = "true" ]
}

fleet_backend_worktree_create() {  # <repo-selector> <name> -> "<wt-id>\t<path>"
  local repo=$1 name=$2 out id path
  out="$(orca worktree create --repo "$repo" --name "$name" --no-parent --setup skip --json)" || return 1
  id="$(printf '%s' "$out" | jq -r '.result.worktree.id')"
  path="$(printf '%s' "$out" | jq -r '.result.worktree.path')"
  [ -n "$id" ] && [ "$id" != null ] || return 1
  printf '%s\t%s' "$id" "$path"
}

fleet_backend_worktree_rm() {  # <worktree-id>
  orca worktree rm --worktree "id:$1" --force --json >/dev/null
}

fleet_backend_terminal_create() {  # <worktree-id> <title> <command> -> handle
  local wt=$1 title=$2 cmd=$3 out h
  out="$(orca terminal create --worktree "id:$wt" --title "$title" --command "$cmd" --json)" || return 1
  h="$(printf '%s' "$out" | jq -r '.result.terminal.handle // .result.handle')"
  [ -n "$h" ] && [ "$h" != null ] || return 1
  printf '%s' "$h"
}

fleet_backend_terminal_send() {  # <handle> <text>
  orca terminal send --terminal "$1" --text "$2" --enter --json >/dev/null
}

fleet_backend_terminal_enter() {  # <handle>  (clear a trust/onboarding gate)
  orca terminal send --terminal "$1" --enter --json >/dev/null
}

fleet_backend_terminal_idle() {  # <handle> <timeout-ms> -> "<satisfied>\t<blockedReason>"
  local out
  out="$(orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$2" --json)" || return 1
  printf '%s\t%s' \
    "$(printf '%s' "$out" | jq -r '.result.wait.satisfied')" \
    "$(printf '%s' "$out" | jq -r '.result.wait.blockedReason')"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-backend.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-backend
chmod +x bin/fleet-backend
git add bin/fleet-backend tests/fleet-backend.bats
git commit -m "feat: fleet-backend Orca seam with fake-orca-on-PATH tests"
```

---

### Task 3: Mission-type pipelines + `fleet-pipeline` reader

**Files:**
- Create: `config/missions/campaign.json`, `config/missions/strike.json`, `config/missions/recon.json`, `config/missions/fortify.json`
- Create: `bin/fleet-pipeline`
- Test: `tests/fleet-pipeline.bats`

**Interfaces:**
- Consumes: `fleet_roots` globals (`FLEET_CONFIG`).
- Produces:
  - `fleet_pipeline_file <type>` — prints `$FLEET_CONFIG/missions/<type>.json`, or dies if absent.
  - `fleet_pipeline_entry <type>` — the entry stage name.
  - `fleet_pipeline_fix_limit <type>` — integer (default 3).
  - `fleet_pipeline_field <type> <stage> <field>` — prints a stage field (`role`, `prompt`, `next`, `on_pass`, `on_fail`, `review`, `terminal`), empty string if unset.

**Stage graph schema** (each mission-type file): `type`, `entry`, `fix_round_limit`, and `stages[]` where each stage has `name`, optional `role` (`frontier|executor`), optional `prompt` (template filename), and exactly one transition form: `next: <stage|"ready">`, or (review stages) `review: true` + `on_pass` + `on_fail`, or `terminal: true` (no successor — recon's `report`).

- [ ] **Step 1: Write the four config files**

Create `config/missions/campaign.json`:

```json
{
  "type": "campaign",
  "entry": "spec",
  "fix_round_limit": 3,
  "stages": [
    { "name": "spec",    "role": "frontier", "prompt": "spec.txt",    "next": "plan" },
    { "name": "plan",    "role": "frontier", "prompt": "plan.txt",    "next": "execute" },
    { "name": "execute", "role": "executor", "prompt": "execute.txt", "next": "review" },
    { "name": "review",  "role": "frontier", "prompt": "review.txt",  "review": true, "on_pass": "ready", "on_fail": "fix" },
    { "name": "fix",     "role": "executor", "prompt": "fix.txt",     "next": "review" }
  ]
}
```

Create `config/missions/strike.json`:

```json
{
  "type": "strike",
  "entry": "plan",
  "fix_round_limit": 3,
  "stages": [
    { "name": "plan",    "role": "frontier", "prompt": "plan.txt",    "next": "execute" },
    { "name": "execute", "role": "executor", "prompt": "execute.txt", "next": "review" },
    { "name": "review",  "role": "frontier", "prompt": "review.txt",  "review": true, "on_pass": "ready", "on_fail": "fix" },
    { "name": "fix",     "role": "executor", "prompt": "fix.txt",     "next": "review" }
  ]
}
```

Create `config/missions/recon.json`:

```json
{
  "type": "recon",
  "entry": "recon",
  "fix_round_limit": 0,
  "stages": [
    { "name": "recon",  "role": "frontier", "prompt": "recon.txt", "next": "report" },
    { "name": "report", "terminal": true }
  ]
}
```

Create `config/missions/fortify.json`:

```json
{
  "type": "fortify",
  "entry": "audit",
  "fix_round_limit": 3,
  "stages": [
    { "name": "audit",   "role": "frontier", "prompt": "audit.txt",   "next": "execute" },
    { "name": "execute", "role": "executor", "prompt": "execute.txt", "next": "review" },
    { "name": "review",  "role": "frontier", "prompt": "review.txt",  "review": true, "on_pass": "ready", "on_fail": "fix" },
    { "name": "fix",     "role": "executor", "prompt": "fix.txt",     "next": "review" }
  ]
}
```

- [ ] **Step 2: Write the failing test**

Create `tests/fleet-pipeline.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home
  fleet_seed_config
}
teardown() { fleet_teardown_home; }

pl() { bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; '"$1"; }

@test "entry stage per type" {
  run pl 'fleet_pipeline_entry campaign'; [ "$output" = "spec" ]
  run pl 'fleet_pipeline_entry strike';   [ "$output" = "plan" ]
  run pl 'fleet_pipeline_entry recon';    [ "$output" = "recon" ]
  run pl 'fleet_pipeline_entry fortify';  [ "$output" = "audit" ]
}

@test "stage fields read from the graph" {
  run pl 'fleet_pipeline_field campaign execute role';  [ "$output" = "executor" ]
  run pl 'fleet_pipeline_field campaign execute next';  [ "$output" = "review" ]
  run pl 'fleet_pipeline_field campaign review on_pass'; [ "$output" = "ready" ]
  run pl 'fleet_pipeline_field campaign review on_fail'; [ "$output" = "fix" ]
  run pl 'fleet_pipeline_field campaign review review';  [ "$output" = "true" ]
}

@test "fix limit and terminal stage" {
  run pl 'fleet_pipeline_fix_limit campaign'; [ "$output" = "3" ]
  run pl 'fleet_pipeline_field recon report terminal'; [ "$output" = "true" ]
}

@test "missing type dies" {
  run pl 'fleet_pipeline_file nope'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}
```

- [ ] **Step 3: Write `bin/fleet-pipeline`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-pipeline - read a mission-type's stage graph (data-driven pipeline).
# The graph is DATA; this is the only reader. Sourced only; no `set`.

fleet_pipeline_file() {  # <type>
  local f="$FLEET_CONFIG/missions/$1.json"
  [ -f "$f" ] || fleet_die "unknown mission type '$1' (no $f)"
  printf '%s' "$f"
}

fleet_pipeline_entry() {  # <type>
  jq -r '.entry' "$(fleet_pipeline_file "$1")"
}

fleet_pipeline_fix_limit() {  # <type>
  jq -r '.fix_round_limit // 3' "$(fleet_pipeline_file "$1")"
}

fleet_pipeline_field() {  # <type> <stage> <field>  -> value or "" if unset/null
  jq -r --arg s "$2" --arg k "$3" \
    '(.stages[] | select(.name==$s) | .[$k]) // "" | if type=="boolean" then tostring else . end' \
    "$(fleet_pipeline_file "$1")"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-pipeline.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-pipeline
chmod +x bin/fleet-pipeline
git add bin/fleet-pipeline config/missions
git commit -m "feat: mission-type stage graphs + fleet-pipeline reader"
```

---

### Task 4: `fleet-mission` (create mission + worktree)

**Files:**
- Create: `bin/fleet-mission`
- Test: `tests/fleet-mission.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-backend`, `fleet-pipeline`.
- Produces: writes `state/missions/<id>/mission.json` and prints `<id>`. `mission.json` fields: `id, type, project, repo, description, stage, fix_round, restarts, worktree_path, orca_worktree_id, terminal, artifacts, created_at, updated_at`. Entry-stage rule: campaign with `--spec` starts at `plan` (spec provided); otherwise the type's entry stage.

**CLI:** `fleet-mission --type <t> --project <p> --repo <repo-selector> --desc <text> [--spec <path>] [--issue <n>] [--id <id>]`

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-mission.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "creates mission.json with entry stage and a worktree" {
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:repo1 --desc "add login" --id m001
  [ "$status" -eq 0 ]
  [[ "$output" == "m001" ]]
  mj="$FLEET_STATE_OVERRIDE/missions/m001/mission.json"
  [ -f "$mj" ]
  [ "$(jq -r .stage "$mj")" = "spec" ]
  [ "$(jq -r .type "$mj")" = "campaign" ]
  [ "$(jq -r .description "$mj")" = "add login" ]
  wt="$(jq -r .worktree_path "$mj")"; [ -d "$wt" ]
  [ "$(jq -r .orca_worktree_id "$mj")" != "null" ]
}

@test "campaign with --spec skips to plan" {
  echo "# spec" > "$FLEET_TMP/spec.md"
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --spec "$FLEET_TMP/spec.md" --id m002
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m002/mission.json")" = "plan" ]
}

@test "strike starts at plan" {
  run "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc "bug" --issue 42 --id m003
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m003/mission.json")" = "plan" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-mission.bats`
Expected: FAIL — `bin/fleet-mission` missing.

- [ ] **Step 3: Write `bin/fleet-mission`**

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

TYPE="" PROJECT="" REPO="" DESC="" SPEC="" ISSUE="" ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --desc) DESC=$2; shift 2 ;;
    --spec) SPEC=$2; shift 2 ;;
    --issue) ISSUE=$2; shift 2 ;;
    --id) ID=$2; shift 2 ;;
    *) fleet_die "unknown flag: $1" ;;
  esac
done
[ -n "$TYPE" ] && [ -n "$PROJECT" ] && [ -n "$REPO" ] && [ -n "$DESC" ] || fleet_die "need --type --project --repo --desc"
fleet_pipeline_file "$TYPE" >/dev/null   # validates type

[ -n "$ID" ] || ID="$(fleet_next_id)"
STAGE="$(fleet_pipeline_entry "$TYPE")"
# Artifact-skip rule: a provided spec skips the campaign spec stage.
if [ "$TYPE" = campaign ] && [ -n "$SPEC" ]; then STAGE="plan"; fi

fleet_backend_status_ready || fleet_die "orca runtime not ready"
IFS=$'\t' read -r WT_ID WT_PATH <<<"$(fleet_backend_worktree_create "$REPO" "fleet-$ID")" \
  || fleet_die "worktree create failed"

mdir="$(fleet_mission_dir "$ID")"; mkdir -p "$mdir"
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
jq -n \
  --arg id "$ID" --arg type "$TYPE" --arg project "$PROJECT" --arg repo "$REPO" \
  --arg desc "$DESC" --arg stage "$STAGE" --arg wt "$WT_PATH" --arg wtid "$WT_ID" \
  --arg spec "$SPEC" --arg issue "$ISSUE" --arg now "$now" \
  '{id:$id,type:$type,project:$project,repo:$repo,description:$desc,stage:$stage,
    fix_round:0,restarts:0,worktree_path:$wt,orca_worktree_id:$wtid,terminal:null,
    artifacts:({} + (if $spec!="" then {spec:$spec} else {} end)
                  + (if $issue!="" then {issue:$issue} else {} end)),
    created_at:$now,updated_at:$now}' \
  > "$(fleet_mission_json "$ID")"

: > "$mdir/log"
fleet_journal mission-create "$ID $TYPE $STAGE"
printf '%s\n' "$ID"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/fleet-mission.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-mission
chmod +x bin/fleet-mission
git add bin/fleet-mission tests/fleet-mission.bats
git commit -m "feat: fleet-mission creates mission.json + orca worktree"
```

---

### Task 5: `fleet-done` (completion marker)

**Files:**
- Create: `bin/fleet-done`
- Test: `tests/fleet-done.bats`

**Interfaces:**
- Consumes: `fleet-common`.
- Produces: appends one line `<epoch>\t<status>` to `<worktree>/.devfleet/<id>.status` (creating `.devfleet/`). Reads the worktree path from `mission.json`. `status ∈ done | blocked:<q> | failed:<reason>`. Also exposes `fleet_done_latest <id>` → prints the latest status line's status field (used by `fleet-advance`).

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-done.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  ID=$("$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id m001)
  WT=$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m001/mission.json")
}
teardown() { fleet_teardown_home; }

@test "fleet-done writes a marker into the worktree" {
  run "$REPO_ROOT/bin/fleet-done" m001 done
  [ "$status" -eq 0 ]
  [ -f "$WT/.devfleet/m001.status" ]
  [[ "$(cat "$WT/.devfleet/m001.status")" == *$'\t'"done" ]]
}

@test "fleet_done_latest returns the last status verb" {
  "$REPO_ROOT/bin/fleet-done" m001 done
  "$REPO_ROOT/bin/fleet-done" m001 "blocked:need a key"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-done"; fleet_roots; fleet_done_latest m001'
  [ "$status" -eq 0 ]
  [[ "$output" == "blocked:need a key" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-done.bats`
Expected: FAIL — `bin/fleet-done` missing.

- [ ] **Step 3: Write `bin/fleet-done`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-done - append a completion marker into <worktree>/.devfleet/<id>.status.
# Dual-use: runnable as an entrypoint by an operator, AND sourceable for
# fleet_done_latest. When sourced, defines functions only (no side effects).

fleet_done_marker() {  # <id> -> path to that mission's status file
  local id=$1 wt
  wt="$(fleet_json_get "$(fleet_mission_json "$id")" '.worktree_path')"
  printf '%s/.devfleet/%s.status' "$wt" "$id"
}

fleet_done_write() {  # <id> <status>
  local id=$1 status=$2 marker
  marker="$(fleet_done_marker "$id")"
  mkdir -p "$(dirname "$marker")"
  printf '%s\t%s\n' "$(date +%s)" "$status" >> "$marker"
}

fleet_done_latest() {  # <id> -> latest status field (after the tab)
  local marker
  marker="$(fleet_done_marker "$1")"
  [ -f "$marker" ] || return 1
  tail -n1 "$marker" | cut -f2-
}

# Entrypoint behavior only when executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  fleet_roots
  [ $# -eq 2 ] || fleet_die "usage: fleet-done <mission-id> <status>"
  fleet_done_write "$1" "$2"
  fleet_journal done "$1 $2"
fi
```

Note: `fleet-done` is sourced by `fleet-advance` (for `fleet_done_latest`) and also run directly by operators — the `BASH_SOURCE`/`$0` guard keeps the entrypoint block from firing on source, so defining functions has no side effects.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/fleet-done.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-done
chmod +x bin/fleet-done
git add bin/fleet-done tests/fleet-done.bats
git commit -m "feat: fleet-done completion marker (write + latest reader)"
```

---

### Task 6: `fleet-spawn` (brief + launch command + `--dry-run`)

**Files:**
- Create: `bin/fleet-spawn`
- Create: `config/roles.json.example`
- Create: `prompts/spec.txt`, `prompts/plan.txt`, `prompts/execute.txt`, `prompts/review.txt`, `prompts/fix.txt`, `prompts/audit.txt`, `prompts/recon.txt`
- Test: `tests/fleet-spawn.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-backend`, `fleet-pipeline`, `mission.json`, `roles.json`, `prompts/`.
- Produces: for `fleet-spawn --mission <id> --stage <stage>`: resolves the stage `role` → harness `cmd` (from `roles.json`), renders the prompt template (substituting `{mission_id}`, `{description}`, `{worktree}`) + a completion footer, writes the brief to `<worktree>/.devfleet/<id>.<stage>.brief`, and (non-dry) creates an Orca terminal running `<cmd> "$(cat <brief>)"`, recording the terminal handle back into `mission.json`. With `--dry-run`, prints the launch command and the brief path, mutating nothing and calling no `orca` verbs that create state.
- Launch-template shape mirrors firstmate:bin/fm-spawn.sh:314-353 (per-harness `case`, `__BRIEF__` placeholder).

- [ ] **Step 1: Write roles + prompts**

Create `config/roles.json.example`:

```json
{
  "frontier": { "harness": "claude", "cmd": "claude" },
  "executor": { "harness": "pi", "cmd": "pi" }
}
```

Create `prompts/spec.txt`:

```
You are running the spec stage for mission {mission_id} in {worktree}.
Task: {description}
Run superpowers:brainstorming with the user, then write the spec to docs/superpowers/specs/.
```

Create `prompts/plan.txt`:

```
You are running the plan stage for mission {mission_id} in {worktree}.
Task: {description}
Write an implementation plan with superpowers:writing-plans from the spec.
```

Create `prompts/execute.txt`:

```
You are running the execute stage for mission {mission_id} in {worktree}.
Task: {description}
Implement the plan in this worktree with superpowers:executing-plans.
```

Create `prompts/review.txt`:

```
You are running the review stage for mission {mission_id} in {worktree}.
Read `git diff` vs base plus the plan. Write findings.json with {"result":"PASS"|"FAIL","findings":[...]} at the worktree root.
```

Create `prompts/fix.txt`:

```
You are running the fix stage for mission {mission_id} in {worktree}.
Address every FAIL finding in findings.json, then stop.
```

Create `prompts/audit.txt`:

```
You are running the audit stage for mission {mission_id} in {worktree}.
Task: {description}
Inspect the repo against the improvement goal and write an improvement plan.
```

Create `prompts/recon.txt`:

```
You are running the recon stage for mission {mission_id} in {worktree}.
Task: {description}
Investigate and write report.md at the worktree root. Do not change code.
```

- [ ] **Step 2: Write the failing test**

Create `tests/fleet-spawn.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  ID=$("$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc "add login" --id m001)
  MJ="$FLEET_STATE_OVERRIDE/missions/m001/mission.json"
  WT=$(jq -r .worktree_path "$MJ")
}
teardown() { fleet_teardown_home; }

@test "dry-run prints launch command with the harness, mutates no orca state" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude "* ]]
  [ -f "$WT/.devfleet/m001.spec.brief" ]
  ! orca_log_has $'terminal\x1fcreate'
}

@test "brief substitutes mission fields and adds the done footer" {
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  brief="$WT/.devfleet/m001.spec.brief"
  grep -q "mission m001" "$brief"
  grep -q "add login" "$brief"
  grep -q "fleet-done m001" "$brief"
}

@test "executor stage resolves the pi harness" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi "* ]]
}

@test "non-dry spawn creates an orca terminal and records the handle" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fcreate'
  [ "$(jq -r .terminal "$MJ")" = "term_001" ]
}
```

- [ ] **Step 3: Write `bin/fleet-spawn`**

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

mj="$(fleet_mission_json "$MISSION")"
[ -f "$mj" ] || fleet_die "no mission $MISSION"
TYPE="$(fleet_json_get "$mj" '.type')"
DESC="$(fleet_json_get "$mj" '.description')"
WT="$(fleet_json_get "$mj" '.worktree_path')"
WT_ID="$(fleet_json_get "$mj" '.orca_worktree_id')"

ROLE="$(fleet_pipeline_field "$TYPE" "$STAGE" role)"
[ -n "$ROLE" ] || fleet_die "stage $STAGE has no role in $TYPE"
CMD="$(fleet_json_get "$FLEET_CONFIG/roles.json" ".$ROLE.cmd")"
[ -n "$CMD" ] && [ "$CMD" != null ] || fleet_die "no cmd for role $ROLE in roles.json"

PROMPT_FILE="$(fleet_pipeline_field "$TYPE" "$STAGE" prompt)"
[ -n "$PROMPT_FILE" ] || fleet_die "stage $STAGE has no prompt"
tmpl="$FLEET_HOME/prompts/$PROMPT_FILE"
[ -f "$tmpl" ] || tmpl="$FLEET_ROOT/prompts/$PROMPT_FILE"
[ -f "$tmpl" ] || fleet_die "missing prompt template $PROMPT_FILE"

# Render brief: substitute placeholders, append the completion contract footer.
brief="$WT/.devfleet/$MISSION.$STAGE.brief"
mkdir -p "$(dirname "$brief")"
sed -e "s|{mission_id}|$MISSION|g" \
    -e "s|{description}|$DESC|g" \
    -e "s|{worktree}|$WT|g" "$tmpl" > "$brief"
{
  printf '\nWhen finished, run: fleet-done %s <status>\n' "$MISSION"
  printf '  status is one of: done | blocked:<question> | failed:<reason>\n'
} >> "$brief"

LAUNCH="$CMD \"\$(cat $brief)\""

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' "$LAUNCH"
  printf 'brief: %s\n' "$brief"
  exit 0
fi

fleet_backend_status_ready || fleet_die "orca runtime not ready"
handle="$(fleet_backend_terminal_create "$WT_ID" "fleet-$MISSION-$STAGE" "$LAUNCH")" \
  || fleet_die "terminal create failed"
fleet_json_set "$mj" ".terminal=\"$handle\" | .updated_at=\"$(date '+%Y-%m-%dT%H:%M:%S%z')\""
fleet_journal spawn "$MISSION $STAGE $handle"
printf '%s\n' "$handle"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/fleet-spawn.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-spawn
chmod +x bin/fleet-spawn
git add bin/fleet-spawn config/roles.json.example prompts tests/fleet-spawn.bats
git commit -m "feat: fleet-spawn (brief render, harness launch cmd, --dry-run)"
```

---

### Task 7: `fleet-advance` (data-driven state machine)

**Files:**
- Create: `bin/fleet-advance`
- Test: `tests/fleet-advance.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-pipeline`, `fleet-done` (for `fleet_done_latest`), `fleet-spawn` (invoked to launch the next stage). Reads `mission.json` + the mission's `.status` marker + `findings.json` (for review stages).
- Produces: `fleet-advance <mission-id>` reads the latest marker verb and the current stage, applies the transition table, updates `mission.json` (`stage`, `fix_round`, `restarts`, `updated_at`), appends to `state/missions/<id>/log`, and spawns the next stage (unless the mission reached `ready`/`parked`/`failed`/`blocked`). Prints the new mission state.

**Transition table** (single owner; fail-closed `*)` — mirrors firstmate:bin/fm-transition-lib.sh:96-103):

| marker verb | current stage | action |
|---|---|---|
| `failed:*` | any | state → `failed` |
| `blocked:*` | any | state → `blocked` (Phase 1: no wake) |
| `done` | review, findings PASS | stage → `on_pass` (`ready`); state → `ready` |
| `done` | review, findings FAIL, `fix_round < limit` | `fix_round++`, stage → `on_fail`; spawn |
| `done` | review, findings FAIL, `fix_round ≥ limit` | state → `parked` |
| `done` | stage.next == `ready` | state → `ready` |
| `done` | stage.terminal == true | state → `done` |
| `done` | otherwise | stage → `stage.next`; spawn |
| anything else | any | state → `parked` (fail-closed) |

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-advance.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mk() {  # <type> <id> [extra flags...]
  "$REPO_ROOT/bin/fleet-mission" --type "$1" --project a --repo id:r --desc x --id "$2" "${@:3}" >/dev/null
}
stage_of() { jq -r .stage "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
wt_of() { jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "done on a linear stage advances to next and spawns it" {
  mk campaign m001
  "$REPO_ROOT/bin/fleet-done" m001 done
  run "$REPO_ROOT/bin/fleet-advance" m001
  [ "$status" -eq 0 ]
  [ "$(stage_of m001)" = "plan" ]
  orca_log_has $'orca\x1fterminal\x1fcreate'
}

@test "review PASS goes to ready" {
  mk campaign m002
  jq '.stage="review"' "$FLEET_STATE_OVERRIDE/missions/m002/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m002/mission.json"
  echo '{"result":"PASS","findings":[]}' > "$(wt_of m002)/findings.json"
  "$REPO_ROOT/bin/fleet-done" m002 done
  run "$REPO_ROOT/bin/fleet-advance" m002
  [ "$status" -eq 0 ]
  [ "$(stage_of m002)" = "ready" ]
}

@test "review FAIL with rounds left goes to fix and increments fix_round" {
  mk campaign m003
  jq '.stage="review"' "$FLEET_STATE_OVERRIDE/missions/m003/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m003/mission.json"
  echo '{"result":"FAIL","findings":["x"]}' > "$(wt_of m003)/findings.json"
  "$REPO_ROOT/bin/fleet-done" m003 done
  run "$REPO_ROOT/bin/fleet-advance" m003
  [ "$status" -eq 0 ]
  [ "$(stage_of m003)" = "fix" ]
  [ "$(jq -r .fix_round "$FLEET_STATE_OVERRIDE/missions/m003/mission.json")" = "1" ]
}

@test "review FAIL with rounds exhausted parks" {
  mk campaign m004
  jq '.stage="review" | .fix_round=3' "$FLEET_STATE_OVERRIDE/missions/m004/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m004/mission.json"
  echo '{"result":"FAIL","findings":["x"]}' > "$(wt_of m004)/findings.json"
  "$REPO_ROOT/bin/fleet-done" m004 done
  run "$REPO_ROOT/bin/fleet-advance" m004
  [ "$status" -eq 0 ]
  [ "$(stage_of m004)" = "parked" ]
}

@test "blocked marker sets blocked state" {
  mk campaign m005
  "$REPO_ROOT/bin/fleet-done" m005 "blocked:need creds"
  run "$REPO_ROOT/bin/fleet-advance" m005
  [ "$(stage_of m005)" = "blocked" ]
}

@test "recon report is terminal -> done" {
  mk recon m006
  jq '.stage="report"' "$FLEET_STATE_OVERRIDE/missions/m006/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m006/mission.json"
  "$REPO_ROOT/bin/fleet-done" m006 done
  run "$REPO_ROOT/bin/fleet-advance" m006
  [ "$(stage_of m006)" = "done" ]
}
```

Note: `stage` doubles as the mission-state field — terminal states (`ready|done|parked|blocked|failed`) are written into `.stage`, matching the spec's "Mission states: `<stage names> | ready | done | parked | blocked | failed`".

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-advance.bats`
Expected: FAIL — `bin/fleet-advance` missing.

- [ ] **Step 3: Write `bin/fleet-advance`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-pipeline
. "$SCRIPT_DIR/fleet-pipeline"
# shellcheck source=bin/fleet-done
. "$SCRIPT_DIR/fleet-done"
fleet_roots

ID="${1:-}"; [ -n "$ID" ] || fleet_die "usage: fleet-advance <mission-id>"
mj="$(fleet_mission_json "$ID")"; [ -f "$mj" ] || fleet_die "no mission $ID"
TYPE="$(fleet_json_get "$mj" '.type')"
STAGE="$(fleet_json_get "$mj" '.stage')"
FIX="$(fleet_json_get "$mj" '.fix_round')"
WT="$(fleet_json_get "$mj" '.worktree_path')"
LIMIT="$(fleet_pipeline_fix_limit "$TYPE")"

verb="$(fleet_done_latest "$ID" || true)"
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

set_stage() { fleet_json_set "$mj" ".stage=\"$1\" | .updated_at=\"$now\""; }
set_fix()   { fleet_json_set "$mj" ".fix_round=$1 | .updated_at=\"$now\""; }
log() { printf '%s\t%s\n' "$now" "$*" >> "$(fleet_mission_dir "$ID")/log"; fleet_journal advance "$ID $*"; }
spawn() { "$SCRIPT_DIR/fleet-spawn" --mission "$ID" --stage "$1" >/dev/null; }

next_state=""
case "$verb" in
  failed:*)  set_stage failed; next_state=failed; log "failed: ${verb#failed:}" ;;
  blocked:*) set_stage blocked; next_state=blocked; log "blocked: ${verb#blocked:}" ;;
  done)
    if [ "$(fleet_pipeline_field "$TYPE" "$STAGE" review)" = "true" ]; then
      result="$(jq -r '.result // "FAIL"' "$WT/findings.json" 2>/dev/null || echo FAIL)"
      if [ "$result" = "PASS" ]; then
        on_pass="$(fleet_pipeline_field "$TYPE" "$STAGE" on_pass)"
        set_stage "$on_pass"; next_state="$on_pass"; log "review PASS -> $on_pass"
      elif [ "$FIX" -lt "$LIMIT" ]; then
        set_fix "$((FIX + 1))"
        on_fail="$(fleet_pipeline_field "$TYPE" "$STAGE" on_fail)"
        set_stage "$on_fail"; next_state="$on_fail"; log "review FAIL -> $on_fail (round $((FIX + 1)))"
        spawn "$on_fail"
      else
        set_stage parked; next_state=parked; log "review FAIL, rounds exhausted -> parked"
      fi
    elif [ "$(fleet_pipeline_field "$TYPE" "$STAGE" terminal)" = "true" ]; then
      set_stage done; next_state=done; log "terminal stage -> done"
    else
      nxt="$(fleet_pipeline_field "$TYPE" "$STAGE" next)"
      if [ "$nxt" = "ready" ]; then
        set_stage ready; next_state=ready; log "-> ready"
      else
        set_stage "$nxt"; next_state="$nxt"; log "$STAGE done -> $nxt"
        spawn "$nxt"
      fi
    fi
    ;;
  *) set_stage parked; next_state=parked; log "unknown marker '$verb' -> parked (fail-closed)" ;;
esac

printf '%s\n' "$next_state"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/fleet-advance.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-advance
chmod +x bin/fleet-advance
git add bin/fleet-advance tests/fleet-advance.bats
git commit -m "feat: fleet-advance data-driven transition table (fail-closed)"
```

---

### Task 8: `fleet-status` (snapshot)

**Files:**
- Create: `bin/fleet-status`
- Test: `tests/fleet-status.bats`

**Interfaces:**
- Consumes: `fleet-common`, all `mission.json` files.
- Produces: `fleet-status` prints one line per mission: `<id>  <type>  <project>/<repo-tail>  <stage>`, sorted by id. Read-only; exits 0 even with zero missions (prints nothing). `--json` prints an array of `{id,type,project,stage}`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-status.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "empty fleet prints nothing, exits 0" {
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lists one line per mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m001 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc y --id m002 >/dev/null
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "m001"*"campaign"*"spec"* ]]
  [[ "${lines[1]}" == "m002"*"recon"*"recon"* ]]
}

@test "--json emits an array" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m001 >/dev/null
  run "$REPO_ROOT/bin/fleet-status" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "m001" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-status.bats`
Expected: FAIL — `bin/fleet-status` missing.

- [ ] **Step 3: Write `bin/fleet-status`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
fleet_roots

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

files=()
for mj in "$FLEET_STATE"/missions/*/mission.json; do
  [ -e "$mj" ] || continue
  files+=("$mj")
done

if [ "$JSON" -eq 1 ]; then
  if [ "${#files[@]}" -eq 0 ]; then echo '[]'; exit 0; fi
  jq -s 'map({id,type,project,stage}) | sort_by(.id)' "${files[@]}"
  exit 0
fi

for mj in "${files[@]:-}"; do
  [ -n "$mj" ] || continue
  id="$(jq -r .id "$mj")"; type="$(jq -r .type "$mj")"
  project="$(jq -r .project "$mj")"; repo="$(jq -r .repo "$mj")"; stage="$(jq -r .stage "$mj")"
  printf '%s\t%s\t%s/%s\t%s\n' "$id" "$type" "$project" "${repo##*/}" "$stage"
done | sort
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/fleet-status.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint and commit**

```bash
shellcheck bin/fleet-status
chmod +x bin/fleet-status
git add bin/fleet-status tests/fleet-status.bats
git commit -m "feat: fleet-status snapshot (text + --json)"
```

---

### Task 9: End-to-end pipeline test

**Files:**
- Test: `tests/fleet-e2e.bats`

**Interfaces:**
- Consumes: every script. No new production code — this task proves the whole loop drives a campaign mission spec → plan → execute → review → ready via synthetic markers and the fake backend. If it fails, the fix goes into whichever script the failure implicates (and its own unit test).

- [ ] **Step 1: Write the end-to-end test**

Create `tests/fleet-e2e.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

stage_of() { jq -r .stage "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
wt_of() { jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

# Simulate a stage agent finishing: (optionally drop findings.json) then mark done.
finish() {  # <id> [findings-result]
  [ -n "${2:-}" ] && echo "{\"result\":\"$2\",\"findings\":[]}" > "$(wt_of "$1")/findings.json"
  "$REPO_ROOT/bin/fleet-done" "$1" done
  "$REPO_ROOT/bin/fleet-advance" "$1" >/dev/null
}

@test "campaign runs spec->plan->execute->review(PASS)->ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc "add login" --id m001 >/dev/null
  [ "$(stage_of m001)" = "spec" ]
  finish m001;         [ "$(stage_of m001)" = "plan" ]
  finish m001;         [ "$(stage_of m001)" = "execute" ]
  finish m001;         [ "$(stage_of m001)" = "review" ]
  finish m001 PASS;    [ "$(stage_of m001)" = "ready" ]
  # the journal recorded each transition
  grep -q "advance" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "campaign review FAIL loops through fix then PASS to ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m002 >/dev/null
  finish m002; finish m002              # spec->plan->execute
  [ "$(stage_of m002)" = "review" ]
  finish m002 FAIL                       # review FAIL -> fix
  [ "$(stage_of m002)" = "fix" ]
  [ "$(jq -r .fix_round "$FLEET_STATE_OVERRIDE/missions/m002/mission.json")" = "1" ]
  finish m002                            # fix done -> review
  [ "$(stage_of m002)" = "review" ]
  finish m002 PASS                       # review PASS -> ready
  [ "$(stage_of m002)" = "ready" ]
}

@test "each spawned stage created an orca terminal" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m003 >/dev/null
  finish m003; finish m003
  # spec-mission created worktree; plan+execute spawns created terminals
  [ "$(grep -c $'terminal\x1fcreate' "$FLEET_ORCA_LOG")" -ge 2 ]
}
```

- [ ] **Step 2: Run the whole suite**

Run: `bats tests/`
Expected: all suites PASS. If the e2e test fails, fix the implicated script, add/adjust its unit test, and re-run.

- [ ] **Step 3: Full lint sweep**

Run: `shellcheck bin/*`
Expected: exit 0, no findings.

- [ ] **Step 4: Commit**

```bash
git add tests/fleet-e2e.bats
git commit -m "test: end-to-end campaign pipeline over fake backend"
```

- [ ] **Step 5: Add a convenience runner and finalize**

Create `Makefile`:

```make
.PHONY: test lint check
lint:
	shellcheck bin/*
test:
	bats tests/
check: lint test
```

Run: `make check`
Expected: shellcheck clean, all bats green.

```bash
git add Makefile
git commit -m "chore: make check (lint + test)"
```

---

## Self-Review

**Spec coverage (core-pipeline slice):**
- Pipeline machine / zero-token deterministic advance → Task 7 (`fleet-advance`) ✓
- Typed mission pipelines as data (`config/missions/<type>.json`) → Task 3 ✓
- Four built-in types (campaign/strike/recon/fortify) → Task 3 ✓
- Backend seam confining all Orca calls → Task 2 (`fleet-backend`) ✓
- Worktree per mission via backend → Task 4 ✓
- Completion protocol (marker in `<worktree>/.devfleet/`) → Task 5 ✓
- Spawn with harness mapping + `--dry-run` → Task 6 ✓
- Review PASS/FAIL + fix-round limit + park → Task 7 ✓
- Fleet snapshot → Task 8 ✓
- State on disk / restart-proof (mission.json + markers + journal) → Tasks 1,4,5,7 ✓
- `shellcheck` + `bats` (fake-orca, synthetic markers) → every task ✓
- Day-0 Orca Linux smoke test → **already done** (prototyped 2026-07-23; see spec "Linux status"); Phase 1 stubs Orca, so no runtime dependency here.

**Deliberately deferred (each its own follow-on plan, NOT placeholders in this plan):**
`fleet-watch` daemon + loop/stall + `blockedReason` polling + `fleet-session-start` + turn-end guard (Plan 2); decision inbox + `fleet-decide` + `fleet-wake` (Plan 3); ship modes + forge (Plan 4); night ops (Plan 5); bunkers + `fleet-loadout` + agent-sandbox (Plan 6, gated on upstream blockers #1/#6); axi integrations (Plan 7). `fleet-advance` here spawns the next stage directly; Plan 2 replaces the manual "call advance" with the watcher reacting to markers — `fleet-advance`'s interface is unchanged by that.

**Type consistency:** `mission.json` field names (`id,type,project,repo,description,stage,fix_round,restarts,worktree_path,orca_worktree_id,terminal,artifacts,created_at,updated_at`) are written once in Task 4 and read with the same names in Tasks 5–8. Backend function names (`fleet_backend_worktree_create/terminal_create/status_ready/...`) are defined in Task 2 and called unchanged in Tasks 4 and 6. `fleet_done_latest`/`fleet_done_marker` defined in Task 5, consumed in Task 7. Pipeline reader names (`fleet_pipeline_entry/field/fix_limit/file`) defined in Task 3, consumed in Tasks 4,6,7. Stage field vocabulary (`role,prompt,next,on_pass,on_fail,review,terminal`) is identical between the Task 3 configs and the Task 7 reads.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders remain — every code step carries complete, runnable code.
