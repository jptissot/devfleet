# DevFleet Ship Path + Per-Repo Modes Implementation Plan (Plan 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a review-PASS into a real shipped change: a per-repo **project partition** holds each repo's ship mode + forge + `unattended` flag; on review PASS the mission rests at `ready` and raises a *ship-approval* decision (or ships straight through when `unattended`); answering `ship` applies the repo's mode — `local-merge` (git ff), `direct-PR` (push + forge PR), or `report-only`. Plus the two supervision fixes from the Plan 3 review.

**Architecture:** A new dual-use `fleet-project` (sourced readers + CRUD entrypoint) owns `projects/<name>/project.json`. A new `fleet-forge` lib is the single seam for PR ops (GitHub `gh` / Gitea-Forgejo `tea`, with `gh-axi`/`tea-axi` as one-file swap-ins), mirroring how `fleet-backend` seams Orca. `fleet-ship` resolves a mission's repo config and dispatches the mode. `fleet-advance`'s review-PASS branch stops merely resting at `ready` — it either ships (unattended) or opens a ship-approval decision reusing the Plan 3 inbox; the answer router gains a `ship` verb alongside `resume`.

**Tech Stack:** Bash, `jq`, `git`, `bats-core` 1.12, `shellcheck`. Orca stubbed by the programmable fake `orca` on `PATH` (Plan 2). `gh`/`tea` stubbed by a fake forge on `PATH` (new helper); both are absent in this environment, so `local-merge` (real `git`) is the fully-exercised primary path and `direct-PR` is exercised through the fake.

**Builds on:** Plans 1–3 (all scripts/libs/tests exist and pass — 76 bats green). This plan **modifies** `bin/fleet-advance`, `bin/fleet-watch`, `bin/fleet-decision`, `bin/fleet-common`, `bin/fleet-status`, `tests/helpers/common.bash`, and **adds** `bin/fleet-project`, `bin/fleet-forge`, `bin/fleet-ship`.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md` — "Ship modes (per repo)", "Components" (`fleet-ship`, `fleet-project`), "State layout" (`projects/<name>/project.json`), "Mission types" (`… → ready → ship`), "Advancement" (review PASS → decision record; ship-on-PASS iff `unattended`). Predecessor reference: `~/repos/kenchenguid/firstmate` — mirror the one-file backend-seam idiom for `fleet-forge`.

**Out of scope (later plans):** night ops queue + morning debrief (Plan 5 — `fleet-night`, `state/queue`); bunkers / loadouts (Plan 6); `tea-axi`/`gh-axi` wrappers themselves (this plan calls plain `gh`/`tea` behind the seam and leaves the axi swap as a one-file change); `fleet-review`'s diff-collection specialization (review already runs via generic `fleet-spawn`); a live `fleet-decide` gum TUI (Plan 3 shipped the one-shot render, still gated).

## Global Constraints

- Same conventions as Plans 1–3: `#!/usr/bin/env bash`; entrypoints `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; `fleet_<area>_<verb>()`; `*_OVERRIDE` env roots; all JSON via `jq`; string writes via `fleet_json_set_str`; `shellcheck bin/*` + `bats tests/` green after every task.
- **Records are the source of truth** (spec "Decision inbox"): a ship-approval is a durable decision record, created before any wake, deduped on mission+stage.
- **Approval is the default; `unattended` opts out** (spec "Ship modes"): review PASS → ship-approval decision; a repo with `unattended: true` ships on PASS with no decision. Night holds at `report-only` unless `unattended` (night queue itself is Plan 5; this plan only honors the per-repo flags).
- **One seam per external system:** all forge calls live in `bin/fleet-forge`; all Orca calls stay in `bin/fleet-backend`. A missing forge tool is a graceful degrade to report-only, never a crash.

## Data model (delta)

Project partition `projects/<name>/project.json`:

```json
{
  "name": "acme",
  "repos": [
    { "selector": "id:r", "path": "/abs/path/to/repo", "default_branch": "main",
      "forge": "github", "ship_mode": "local-merge", "unattended": false }
  ],
  "night_cap": null
}
```

- `selector` matches a mission's `.repo` field (the Orca repo selector, e.g. `id:r`) — the join key from mission → repo config.
- `ship_mode ∈ local-merge | direct-PR | report-only`. `forge ∈ github | gitea | forgejo` (only read for `direct-PR`).
- `unattended` boolean; absent repo/field → readers return `""` and callers apply safe defaults (`report-only`, base `main`, attended).

Mission record gains, on ship: `.ship = {mode, result, at}` and `.stage = "done"`. Ship never edits any other mission field.

## File Structure (delta)

```
bin/
  fleet-project    # NEW dual-use: create/add-repo/show + fleet_project_* + fleet_repo_field readers
  fleet-forge      # NEW lib: fleet_forge_pr seam (gh / tea; gh-axi/tea-axi swap-in); absent tool -> rc 3
  fleet-ship       # NEW: resolve mission repo config -> dispatch local-merge | direct-PR | report-only
  fleet-decision   # MODIFIED: resume stops the old terminal (review F1); answer router gains `ship`
  fleet-watch      # MODIFIED: remove the duplicate fleet-decision source (review F2)
  fleet-advance    # MODIFIED: review PASS -> unattended ship | ship-approval decision (source fleet-project)
  fleet-common     # (unchanged here; project roots already exported by fleet_roots)
  fleet-status     # MODIFIED: --json includes each mission's ship result
tests/
  helpers/common.bash  # MODIFIED: fleet_install_fake_forge (fake gh/tea) + fleet_make_repo_worktree
  fleet-decision.bats  # MODIFIED: resume-stops-old-terminal case
  fleet-project.bats   # NEW
  fleet-forge.bats     # NEW
  fleet-ship.bats      # NEW
  fleet-e2e.bats       # MODIFIED: review PASS -> approval -> answer ship -> merged & done
```

---

### Task 1: `fleet_decision_resume` stops the old agent before respawn (review F1)

**Files:**
- Modify: `bin/fleet-decision` (`fleet_decision_resume`)
- Test: `tests/fleet-decision.bats`

**Interfaces:** `fleet_decision_resume` unchanged externally; internally it now best-effort-stops the recorded `.terminal` (via `fleet_backend_terminal_stop`, Plan 3 Task 3) before `fleet-spawn` overwrites it — closing the same orphan the watcher-restart path already closes. Requires `fleet-backend` on the source chain of any script that runs `answer` (the `fleet-decision` entrypoint already sources `fleet-common`; add `fleet-backend`).

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-decision.bats`:

```bash
@test "resume stops the old (blocked) terminal before respawning" {
  jq '.stage="parked" | .last_stage="plan" | .terminal="term_old"' \
    "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage plan --question "parked" >/dev/null
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-decision" answer d1 resume
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fstop\x1f--terminal\x1fterm_old'   # old agent killed
  orca_log_has $'orca\x1fterminal\x1fcreate'                          # then respawned
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fleet-decision.bats -f "stops the old"`
Expected: FAIL — no `terminal stop` in the log (the confirmed F1 orphan) and/or `fleet_backend_terminal_stop: command not found`.

- [ ] **Step 3: Add `fleet-backend` to the entrypoint source chain**

In `bin/fleet-decision`, in the `if [ "${BASH_SOURCE[0]}" = "$0" ]` block, add the backend source right after the `fleet-common` source (before `fleet_roots`):

```bash
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  # shellcheck source=bin/fleet-backend
  . "$SCRIPT_DIR/fleet-backend"
  fleet_roots
```

- [ ] **Step 4: Stop the old terminal in `fleet_decision_resume`**

Change `fleet_decision_resume` so it captures and stops the old terminal before mutating/respawning. Replace the function body with:

```bash
fleet_decision_resume() {  # <mission>
  local mission=$1 mj ls now old_term
  mj="$(fleet_mission_json "$mission")"
  ls="$(fleet_json_get "$mj" '.last_stage')"
  [ -n "$ls" ] && [ "$ls" != null ] || { echo "error: $mission has no last_stage to resume" >&2; return 1; }
  old_term="$(fleet_json_get "$mj" '.terminal')"
  [ "$old_term" != null ] && [ -n "$old_term" ] && fleet_backend_terminal_stop "$old_term"
  now="$(date +%s)"
  fleet_json_set_str "$mj" '.stage' "$ls"
  fleet_json_set "$mj" ".restarts=0 | .stage_started_at=$now | .last_progress_at=$now | .state_hash=\"\""
  fleet_journal decision-resume "$mission -> $ls (stopped $old_term)"
  "$SCRIPT_DIR/fleet-spawn" --mission "$mission" --stage "$ls" >/dev/null
}
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-decision.bats && bats tests/
shellcheck bin/fleet-decision
git add bin/fleet-decision tests/fleet-decision.bats
git commit -m "fix: resume stops the orphaned agent before respawn (review F1)"
```

---

### Task 2: Remove the duplicate `fleet-decision` source in `fleet-watch` (review F2)

**Files:**
- Modify: `bin/fleet-watch` (source block)
- Test: covered by the existing suite (no behavior change; guard against regressions)

**Interfaces:** none. Purely removes a dead duplicate `source` line so `fleet-decision` is sourced once, after `fleet-watch-lib`, before `fleet_roots`.

- [ ] **Step 1: Delete the stray source pair**

In `bin/fleet-watch`, the header currently sources `fleet-decision` twice. Delete the **second** occurrence (the pair that sits *after* `fleet_roots`, at bin/fleet-watch:18-19):

```bash
fleet_roots

# shellcheck source=bin/fleet-decision   <-- DELETE THIS LINE
. "$SCRIPT_DIR/fleet-decision"            <-- DELETE THIS LINE
STALL_SECONDS="${FLEET_STALL_SECONDS:-900}"
```

After the edit the top of the file reads:

```bash
# shellcheck source=bin/fleet-watch-lib
. "$SCRIPT_DIR/fleet-watch-lib"
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
fleet_roots

STALL_SECONDS="${FLEET_STALL_SECONDS:-900}"
BUDGET_SECONDS="${FLEET_BUDGET_SECONDS:-2700}"
```

- [ ] **Step 2: Verify no regression; lint; commit**

```bash
bats tests/fleet-watch.bats tests/fleet-escalate.bats
shellcheck bin/fleet-watch
git add bin/fleet-watch
git commit -m "cleanup: source fleet-decision once in fleet-watch (review F2)"
```

---

### Task 3: `fleet-project` — project partitions + per-repo ship config

**Files:**
- Create: `bin/fleet-project`
- Test: `tests/fleet-project.bats`

**Interfaces:**
- Produces (sourced readers):
  - `fleet_project_dir <name>` → `$FLEET_PROJECTS/<name>`.
  - `fleet_project_json <name>` → `.../project.json`.
  - `fleet_project_repo <project> <selector>` → prints the repo object (JSON); returns 1 if project/repo absent.
  - `fleet_repo_field <project> <selector> <field>` → prints the field value, `""` if project/repo/field is missing or null (booleans printed as `true`/`false`).
- Produces (entrypoint): `create --name <n>`; `add-repo --project <n> --repo <sel> --path <p> --default-branch <b> --forge <f> --ship-mode <m> [--unattended]`; `show <n> [--json]`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-project.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "create writes a project.json skeleton" {
  run "$REPO_ROOT/bin/fleet-project" create --name acme
  [ "$status" -eq 0 ]
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r .name "$pj")" = "acme" ]
  [ "$(jq -r '.repos | length' "$pj")" = "0" ]
}

@test "add-repo registers a repo with mode + forge + unattended" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r \
    --path /srv/acme --default-branch main --forge github --ship-mode local-merge --unattended >/dev/null
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r '.repos[0].selector' "$pj")" = "id:r" ]
  [ "$(jq -r '.repos[0].ship_mode' "$pj")" = "local-merge" ]
  [ "$(jq -r '.repos[0].unattended' "$pj")" = "true" ]
}

@test "add-repo replaces an existing repo rather than duplicating it" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode report-only >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode local-merge >/dev/null
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r '.repos | length' "$pj")" = "1" ]
  [ "$(jq -r '.repos[0].ship_mode' "$pj")" = "local-merge" ]
}

@test "fleet_repo_field reads fields and degrades to empty on miss" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch dev --forge gitea --ship-mode direct-PR >/dev/null
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; fleet_roots
               fleet_repo_field acme id:r ship_mode; echo "|"; fleet_repo_field acme id:r default_branch
               echo "|"; fleet_repo_field acme nope missing'
  [[ "$output" == "direct-PR|dev|" ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-project.bats`
Expected: FAIL — `bin/fleet-project` missing.

- [ ] **Step 3: Write `bin/fleet-project`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-project - project partitions + per-repo ship config (spec "State layout",
# "Ship modes"). Dual-use: sourceable readers (fleet_project_*, fleet_repo_field)
# and a runnable CRUD entrypoint. Sourced section has no side effects.

fleet_project_dir()  { printf '%s/%s' "$FLEET_PROJECTS" "$1"; }
fleet_project_json() { printf '%s/%s/project.json' "$FLEET_PROJECTS" "$1"; }

# Print the repo object (JSON) for <project> <selector>; return 1 if absent.
fleet_project_repo() {  # <project> <selector>
  local pj; pj="$(fleet_project_json "$1")"; [ -f "$pj" ] || return 1
  jq -e --arg s "$2" 'first(.repos[] | select(.selector==$s))' "$pj" 2>/dev/null
}

# Print one field of a repo; "" if project/repo/field is missing or null.
fleet_repo_field() {  # <project> <selector> <field>
  local pj; pj="$(fleet_project_json "$1")"; [ -f "$pj" ] || { printf ''; return 0; }
  jq -r --arg s "$2" --arg k "$3" \
    '(first(.repos[] | select(.selector==$s)) | .[$k]) // "" | if type=="boolean" then tostring else . end' \
    "$pj"
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
      name=""
      while [ $# -gt 0 ]; do case "$1" in
        --name) name=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$name" ] || fleet_die "need --name"
      d="$(fleet_project_dir "$name")"; mkdir -p "$d"
      pj="$(fleet_project_json "$name")"
      [ -f "$pj" ] || jq -n --arg n "$name" '{name:$n,repos:[],night_cap:null}' > "$pj"
      : >> "$d/memory.md"; : >> "$d/log.md"
      fleet_journal project-create "$name"
      printf '%s\n' "$name" ;;
    add-repo)
      project="" sel="" path="" branch="main" forge="" mode="report-only" unatt=false
      while [ $# -gt 0 ]; do case "$1" in
        --project) project=$2; shift 2 ;;
        --repo) sel=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        --default-branch) branch=$2; shift 2 ;;
        --forge) forge=$2; shift 2 ;;
        --ship-mode) mode=$2; shift 2 ;;
        --unattended) unatt=true; shift ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$project" ] && [ -n "$sel" ] || fleet_die "need --project --repo"
      pj="$(fleet_project_json "$project")"; [ -f "$pj" ] || fleet_die "no project $project"
      tmp="$(mktemp)"
      jq --arg s "$sel" --arg p "$path" --arg b "$branch" --arg f "$forge" --arg m "$mode" --argjson u "$unatt" \
        '.repos = ((.repos // []) | map(select(.selector != $s))
                   + [{selector:$s,path:$p,default_branch:$b,forge:$f,ship_mode:$m,unattended:$u}])' \
        "$pj" > "$tmp" && mv "$tmp" "$pj"
      fleet_journal project-add-repo "$project $sel $mode"
      printf '%s\n' "$sel" ;;
    show)
      name="${1:-}"; [ -n "$name" ] || fleet_die "usage: fleet-project show <name> [--json]"
      pj="$(fleet_project_json "$name")"; [ -f "$pj" ] || fleet_die "no project $name"
      if [ "${2:-}" = "--json" ]; then cat "$pj"
      else jq -r '.repos[] | [.selector,.ship_mode,.forge,(.unattended|tostring)] | @tsv' "$pj"; fi ;;
    *) fleet_die "usage: fleet-project {create|add-repo|show} ..." ;;
  esac
fi
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-project.bats
shellcheck bin/fleet-project
git add bin/fleet-project tests/fleet-project.bats
git commit -m "feat: fleet-project partitions + per-repo ship config readers"
```

---

### Task 4: `fleet-forge` seam + fake forge test helper

**Files:**
- Create: `bin/fleet-forge`
- Modify: `tests/helpers/common.bash` (add `fleet_install_fake_forge`)
- Test: `tests/fleet-forge.bats`

**Interfaces:**
- Produces: `fleet_forge_pr <forge> <repo_path> <branch> <base> <title>` — pushes `<branch>` and opens a PR; prints a URL/identifier on success (rc 0); returns **3** when the forge tool is unavailable (caller degrades to report-only); returns 2 for an unknown forge. GitHub via `gh` (swap `gh-axi`), Gitea/Forgejo via `tea` (swap `tea-axi`).
- Produces (helper): `fleet_install_fake_forge` — drops fake `gh` and `tea` on `PATH` logging argv (0x1f-separated) to `$FLEET_FORGE_LOG` and printing a canned URL; `forge_log_has <needle>` assertion.

- [ ] **Step 1: Write the failing test**

Add to `tests/helpers/common.bash` (after `fleet_install_fake_orca`):

```bash
# Fake forge tools (gh / tea) on PATH: log argv, print a canned PR URL.
fleet_install_fake_forge() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_FORGE_LOG="$FLEET_TMP/forge.log"; : > "$FLEET_FORGE_LOG"
  local t
  for t in gh tea; do
    cat > "$fb/$t" <<'TOOL'
#!/usr/bin/env bash
set -u
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_FORGE_LOG"
printf 'https://forge.example/pr/1\n'
TOOL
    chmod +x "$fb/$t"
  done
  export PATH="$fb:$PATH"
}
forge_log_has() { grep -qF "$1" "$FLEET_FORGE_LOG"; }
```

Create `tests/fleet-forge.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

@test "github PR pushes and calls gh, prints a url" {
  fleet_install_fake_forge
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr github "'"$repo"'" feat main "mission x"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"forge.example/pr/1"* ]]
  forge_log_has $'gh\x1fpr\x1fcreate'
}

@test "missing forge tool returns rc 3 (degrade signal)" {
  # no fleet_install_fake_forge -> gh/tea absent on PATH
  PATH="/usr/bin:/bin" run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr github /nope b main t'
  [ "$status" -eq 3 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-forge.bats`
Expected: FAIL — `bin/fleet-forge` missing.

- [ ] **Step 3: Write `bin/fleet-forge`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-forge - the ONE seam for forge (PR) ops (spec "Ship modes: direct-PR").
# GitHub via `gh` (swap `gh-axi`), Gitea/Forgejo via `tea` (swap `tea-axi`).
# Sourced only; no side effects on source. rc 3 == tool unavailable (degrade).

fleet_forge_pr() {  # <forge> <repo_path> <branch> <base> <title> -> prints url; rc 3 if no tool
  local forge=$1 path=$2 branch=$3 base=$4 title=$5
  case "$forge" in
    github)
      command -v gh >/dev/null 2>&1 || return 3
      git -C "$path" push -u origin "$branch" >/dev/null 2>&1 || true
      ( cd "$path" && gh pr create --head "$branch" --base "$base" --title "$title" --body "" ) ;;
    gitea|forgejo)
      command -v tea >/dev/null 2>&1 || return 3
      git -C "$path" push -u origin "$branch" >/dev/null 2>&1 || true
      ( cd "$path" && tea pr create --head "$branch" --base "$base" --title "$title" ) ;;
    *) return 2 ;;
  esac
}
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-forge.bats
shellcheck bin/fleet-forge
git add bin/fleet-forge tests/helpers/common.bash tests/fleet-forge.bats
git commit -m "feat: fleet-forge PR seam (gh/tea, axi swap-in) + fake forge helper"
```

---

### Task 5: `fleet-ship` — dispatch the repo's ship mode

**Files:**
- Create: `bin/fleet-ship`
- Test: `tests/fleet-ship.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-project` (`fleet_repo_field`), `fleet-forge` (`fleet_forge_pr`).
- Produces: `fleet-ship <mission-id>` — resolves `.project`/`.repo`/`.worktree_path` from the mission, reads the repo's `ship_mode`/`path`/`default_branch`/`forge`, and applies the mode. On success sets `.stage="done"` and `.ship={mode,result,at}`, journals `ship`, prints the result. `local-merge`: `git -C <repo_path> merge --ff-only <worktree-branch>`. `direct-PR`: `fleet_forge_pr` (rc 3 → degrade to a report-only result, still `done`). `report-only`: record a manual-integration note. Unknown mode → `fleet_die`.

- [ ] **Step 1: Write the failing test**

Add `fleet_make_repo_worktree` to `tests/helpers/common.bash` (a real repo + linked worktree on a feature branch, one extra commit ahead of `main`):

```bash
# Build a real repo with `main`, plus a linked worktree on branch <mission-id>
# one commit ahead. Echoes "<repo_path>\t<worktree_path>".
fleet_make_repo_worktree() {  # <mission-id>
  local id=$1 repo="$FLEET_TMP/repos/$id" wt="$FLEET_TMP/wt/$id"
  mkdir -p "$FLEET_TMP/repos" "$FLEET_TMP/wt"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" worktree add -q -b "fleet-$id" "$wt" >/dev/null
  git -C "$wt" commit -q --allow-empty -m "work for $id"
  printf '%s\t%s' "$repo" "$wt"
}
```

Create `tests/fleet-ship.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

# Create a mission, then repoint it at a real repo+worktree and register the repo.
seed_shipping_mission() {  # <id> <ship-mode> [--unattended]
  local id=$1 mode=$2; shift 2
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id "$id" >/dev/null
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree "$id")"
  jq --arg wt "$wt" '.worktree_path=$wt | .orca_worktree_id="id:r::x"' "$(mj "$id")" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$(mj "$id")"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r \
    --path "$repo" --default-branch main --forge github --ship-mode "$mode" "$@" >/dev/null
  echo "$repo"
}

@test "local-merge fast-forwards the branch into main and marks the mission done" {
  repo="$(seed_shipping_mission s1 local-merge)"
  before="$(git -C "$repo" rev-parse main)"
  run "$REPO_ROOT/bin/fleet-ship" s1
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]     # main advanced
  [ "$(jq -r .stage "$(mj s1)")" = "done" ]
  [ "$(jq -r .ship.mode "$(mj s1)")" = "local-merge" ]
}

@test "direct-PR calls the forge and records the PR url" {
  fleet_install_fake_forge
  seed_shipping_mission s2 direct-PR >/dev/null
  run "$REPO_ROOT/bin/fleet-ship" s2
  [ "$status" -eq 0 ]
  forge_log_has $'gh\x1fpr\x1fcreate'
  [[ "$(jq -r .ship.result "$(mj s2)")" == *"forge.example/pr/1"* ]]
  [ "$(jq -r .stage "$(mj s2)")" = "done" ]
}

@test "report-only records a manual note without touching git history" {
  repo="$(seed_shipping_mission s3 report-only)"
  before="$(git -C "$repo" rev-parse main)"
  run "$REPO_ROOT/bin/fleet-ship" s3
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" = "$before" ]      # untouched
  [ "$(jq -r .ship.mode "$(mj s3)")" = "report-only" ]
  [ "$(jq -r .stage "$(mj s3)")" = "done" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-ship.bats`
Expected: FAIL — `bin/fleet-ship` missing.

- [ ] **Step 3: Write `bin/fleet-ship`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-project
. "$SCRIPT_DIR/fleet-project"
# shellcheck source=bin/fleet-forge
. "$SCRIPT_DIR/fleet-forge"
fleet_roots

ID="${1:-}"; [ -n "$ID" ] || fleet_die "usage: fleet-ship <mission-id>"
mj="$(fleet_mission_json "$ID")"; [ -f "$mj" ] || fleet_die "no mission $ID"
PROJECT="$(fleet_json_get "$mj" '.project')"
REPO="$(fleet_json_get "$mj" '.repo')"
WT="$(fleet_json_get "$mj" '.worktree_path')"

MODE="$(fleet_repo_field "$PROJECT" "$REPO" ship_mode)"; [ -n "$MODE" ] || MODE=report-only
REPO_PATH="$(fleet_repo_field "$PROJECT" "$REPO" path)"
BASE="$(fleet_repo_field "$PROJECT" "$REPO" default_branch)"; [ -n "$BASE" ] || BASE=main
FORGE="$(fleet_repo_field "$PROJECT" "$REPO" forge)"
branch="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
now="$(date '+%Y-%m-%dT%H:%M:%S%z')"

result=""
case "$MODE" in
  local-merge)
    [ -n "$REPO_PATH" ] && [ -n "$branch" ] || fleet_die "local-merge needs repo path + branch"
    git -C "$REPO_PATH" merge --ff-only "$branch" >/dev/null 2>&1 \
      || { fleet_journal ship-fail "$ID local-merge ff-only failed ($branch -> $BASE)"; \
           fleet_die "ff-only merge failed: $branch -> $BASE"; }
    result="merged $branch -> $BASE" ;;
  direct-PR)
    if url="$(fleet_forge_pr "$FORGE" "$REPO_PATH" "$branch" "$BASE" "mission $ID")"; then
      result="PR $url"
    else
      result="report-only: forge tool unavailable, integrate $branch -> $BASE manually"
    fi ;;
  report-only)
    result="report-only: integrate $branch -> $BASE manually" ;;
  *) fleet_die "unknown ship mode '$MODE'" ;;
esac

tmp="$(mktemp)"
jq --arg m "$MODE" --arg r "$result" --arg now "$now" \
  '.stage="done" | .ship={mode:$m,result:$r,at:$now} | .updated_at=$now' "$mj" > "$tmp" && mv "$tmp" "$mj"
fleet_journal ship "$ID $MODE ($result)"
printf '%s\n' "$result"
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-ship.bats
shellcheck bin/fleet-ship
git add bin/fleet-ship tests/helpers/common.bash tests/fleet-ship.bats
git commit -m "feat: fleet-ship dispatch (local-merge | direct-PR | report-only)"
```

---

### Task 6: Review PASS → unattended ship | ship-approval decision

**Files:**
- Modify: `bin/fleet-advance` (source `fleet-project`; review-PASS branch)
- Test: `tests/fleet-advance.bats`

**Interfaces:** the review-PASS branch still `set_stage`s the pipeline's `on_pass` (`ready`), then: if the repo is `unattended`, runs `fleet-ship` directly (mission → `done`); otherwise creates a ship-approval decision (`options` `ship`/`hold`) via the Plan 3 inbox and, in day mode, wakes the Commander. No new stage names; `ready` stays the resting state where an attended mission waits for the `ship` answer.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-advance.bats` (helpers `mk`/`mj` and fake orca already used by that file; a review-PASS is signaled by a `findings.json` with `result:"PASS"` in the worktree):

```bash
@test "attended review PASS rests at ready and opens a ship-approval decision" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id v1 >/dev/null
  jq '.stage="review"' "$(mj v1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj v1)"
  wt="$(jq -r .worktree_path "$(mj v1)")"; echo '{"result":"PASS"}' > "$wt/findings.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode local-merge >/dev/null
  "$REPO_ROOT/bin/fleet-done" v1 done
  "$REPO_ROOT/bin/fleet-advance" v1 >/dev/null
  [ "$(jq -r .stage "$(mj v1)")" = "ready" ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"v1"* ]]
  [[ "$output" == *"ship?"* ]]
}

@test "unattended review PASS ships straight through to done" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id v2 >/dev/null
  jq '.stage="review"' "$(mj v2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj v2)"
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree v2)"
  jq --arg wt "$wt" '.worktree_path=$wt' "$(mj v2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj v2)"
  echo '{"result":"PASS"}' > "$wt/findings.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$repo" --default-branch main --forge github --ship-mode local-merge --unattended >/dev/null
  "$REPO_ROOT/bin/fleet-done" v2 done
  "$REPO_ROOT/bin/fleet-advance" v2 >/dev/null
  [ "$(jq -r .stage "$(mj v2)")" = "done" ]
  [ "$(jq -r .ship.mode "$(mj v2)")" = "local-merge" ]
}
```

If `tests/fleet-advance.bats` lacks `fleet_make_repo_worktree` in scope, it is provided by `helpers/common` (Task 5) which that file already `load`s; no change needed.

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-advance.bats -f "ship"`
Expected: FAIL — PASS rests at `ready` with no decision; unattended does not reach `done`.

- [ ] **Step 3: Source `fleet-project` in `fleet-advance`**

Add after the `fleet-decision` source (bin/fleet-advance:10-11):

```bash
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
# shellcheck source=bin/fleet-project
. "$SCRIPT_DIR/fleet-project"
```

- [ ] **Step 4: Extend the review-PASS branch**

In `fleet-advance`, replace the PASS arm (`if [ "$result" = "PASS" ]; then … log "review PASS -> $on_pass"`) with:

```bash
      if [ "$result" = "PASS" ]; then
        on_pass="$(fleet_pipeline_field "$TYPE" "$STAGE" on_pass)"
        set_stage "$on_pass"; next_state="$on_pass"; log "review PASS -> $on_pass"
        unatt="$(fleet_repo_field "$(fleet_json_get "$mj" '.project')" "$(fleet_json_get "$mj" '.repo')" unattended)"
        if [ "$unatt" = "true" ]; then
          "$SCRIPT_DIR/fleet-ship" "$ID" >/dev/null; next_state=done; log "unattended -> shipped"
        else
          fleet_decision_create "$ID" "$(fleet_json_get "$mj" '.project')" "$STAGE" \
            "mission $ID passed review — ship?" "review PASS" \
            '[{"key":"ship","label":"ship","description":"apply the repo ship mode"},{"key":"hold","label":"hold","description":"leave in ready"}]' >/dev/null
          [ "$(fleet_mode)" = day ] && "$SCRIPT_DIR/fleet-wake" "mission $ID passed review — ship?" 2>/dev/null || true
          log "review PASS -> awaiting ship approval"
        fi
```

(The branch's closing `elif`/`else`/`fi` structure is unchanged — only the `if [ "$result" = "PASS" ]` body grows. `fleet-ship` is reachable via `$SCRIPT_DIR`; `fleet_decision_create`/`fleet_mode` come from the already-sourced `fleet-decision`/`fleet-common`.)

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-advance.bats && bats tests/
shellcheck bin/fleet-advance
git add bin/fleet-advance tests/fleet-advance.bats
git commit -m "feat: review PASS opens a ship-approval decision (unattended ships direct)"
```

---

### Task 7: Answer routing gains `ship`; status shows ship result; end-to-end

**Files:**
- Modify: `bin/fleet-decision` (`fleet_decision_answer` routing)
- Modify: `bin/fleet-status` (`--json` includes ship result)
- Test: `tests/fleet-decision.bats`, `tests/fleet-status.bats`, `tests/fleet-e2e.bats`

**Interfaces:** `fleet_decision_answer` routes a `ship` answer to `fleet-ship <mission>` (mechanical, applied directly — same class as `resume`); `resume` unchanged; any other answer wakes the Commander (day) for judgment. `fleet-status --json` mission objects gain `ship` (null until shipped).

- [ ] **Step 1: Write the failing tests**

Add to `tests/fleet-decision.bats`:

```bash
@test "answer ship applies the repo ship mode and marks the mission done" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m1)"
  jq --arg wt "$wt" '.stage="ready" | .worktree_path=$wt' "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  before="$(git -C "$repo" rev-parse main)"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "ship?" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 ship
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m1/mission.json")" = "done" ]
}
```

Add to `tests/fleet-status.bats`:

```bash
@test "status --json carries the mission ship result" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id j1 >/dev/null
  jq '.ship={mode:"local-merge",result:"merged",at:"now"}' "$FLEET_STATE_OVERRIDE/missions/j1/mission.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/j1/mission.json"
  run "$REPO_ROOT/bin/fleet-status" --json
  [ "$(echo "$output" | jq -r '.missions[0].ship.mode')" = "local-merge" ]
}
```

Add to `tests/fleet-e2e.bats`:

```bash
@test "review PASS -> approval decision -> answer ship -> merged & done" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id sh1 >/dev/null
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree sh1)"
  jq --arg wt "$wt" '.stage="review" | .worktree_path=$wt' "$(mj sh1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj sh1)"
  echo '{"result":"PASS"}' > "$wt/findings.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  before="$(git -C "$repo" rev-parse main)"
  "$REPO_ROOT/bin/fleet-done" sh1 done; "$REPO_ROOT/bin/fleet-watch" --tick   # advance: PASS -> ready + decision
  [ "$(stage_of sh1)" = "ready" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | grep sh1 | head -1 | cut -f1)"
  "$REPO_ROOT/bin/fleet-decision" answer "$did" ship
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]     # shipped
  [ "$(stage_of sh1)" = "done" ]
}
```

(`tests/fleet-e2e.bats` already defines `mj`, `wt_of`/`stage_of`, and `load helpers/common`; reuse them. If `stage_of` differs, use `jq -r .stage "$(mj sh1)"`.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-decision.bats tests/fleet-status.bats tests/fleet-e2e.bats -f "ship"`
Expected: FAIL — `answer ship` falls through to the wake branch (mission stays `ready`); `--json` has no `ship`.

- [ ] **Step 3: Route `ship` in `fleet_decision_answer`**

In `bin/fleet-decision`, extend the routing tail of `fleet_decision_answer`:

```bash
  if [ "$answer" = resume ]; then
    fleet_decision_resume "$mission"
  elif [ "$answer" = ship ]; then
    "$SCRIPT_DIR/fleet-ship" "$mission" >/dev/null
  elif [ "$(fleet_mode)" = day ]; then
    "$SCRIPT_DIR/fleet-wake" "decision $did answered: $answer" 2>/dev/null || true
  fi
```

- [ ] **Step 4: Add `ship` to `fleet-status --json`**

In `bin/fleet-status`, extend the `missions` projection to include `ship`:

```bash
  missions="$(jq -s 'map({id,type,project,stage,last_stage,ship})' "${files[@]}" 2>/dev/null || echo '[]')"
```

- [ ] **Step 5: Run to verify pass; full suite; make check; commit**

```bash
bats tests/
make check
git add bin/fleet-decision bin/fleet-status tests/fleet-decision.bats tests/fleet-status.bats tests/fleet-e2e.bats
git commit -m "feat: answer 'ship' routes to fleet-ship + status ship result + e2e ship path"
```

---

## Self-Review

**Spec coverage (Ship-path slice):**
- Ship modes `local-merge` / `direct-PR` / `report-only` → Task 5 ✓
- Forge-aware direct-PR (GitHub `gh`, Gitea/Forgejo `tea`; axi swap-in) → Task 4 ✓
- Per-repo config partition `project.json` (path, forge, ship mode, `unattended`) → Task 3 ✓
- Approval default: review PASS → decision record; ship on answer → Tasks 6 (record), 7 (answer `ship`) ✓
- `unattended: true` → ship-on-PASS → Task 6 ✓
- `bin/fleet-ship`, `bin/fleet-project` components → Tasks 5, 3 ✓
- `fleet-status` reports ship state → Task 7 ✓
- Review F1 (resume orphan) → Task 1; review F2 (dup source) → Task 2 ✓

**Deferred (later plans, explicitly):** night queue + morning debrief (Plan 5 — `fleet-night`, `state/queue`; this plan honors `unattended`/`report-only` flags only); `gh-axi`/`tea-axi` wrappers (one-file swap behind the `fleet-forge` seam); bunkers/loadouts (Plan 6); `fleet-review` diff specialization (review runs via generic `fleet-spawn` today).

**Type consistency:** `fleet_repo_field <project> <selector> <field>` (Task 3) is called with identical arg order from `fleet-ship` (Task 5) and `fleet-advance` (Task 6). The mission→repo join key is `.repo` (selector) throughout — written by `fleet-mission`, matched against `project.json.repos[].selector`. The ship record shape `{mode,result,at}` written by `fleet-ship` (Task 5) is read by `fleet-status --json` (Task 7) with the same field names. `fleet_forge_pr <forge> <repo_path> <branch> <base> <title>` (Task 4) is called with that exact signature by `fleet-ship` (Task 5). The answer verbs `resume`/`ship` in `fleet_decision_answer` (Tasks 1, 7) match the decision `options[].key` written by `fleet_escalate` (`resume`, Plan 3) and `fleet-advance`'s ship-approval (`ship`/`hold`, Task 6).

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every code step carries complete, runnable code. `direct-PR`'s missing-tool path degrades to a concrete report-only result string, not a stub.

**Idempotency & safety:** ship-approval reuses `fleet_decision_create`'s mission+stage dedup (no duplicate records on repeated advance no-ops). `local-merge` uses `--ff-only` so a non-fast-forwardable branch fails loudly (journaled `ship-fail` + `fleet_die`) rather than creating a merge commit silently. `report-only` and a degraded `direct-PR` never touch git history. A missing `project.json`/repo/field degrades to safe defaults (`report-only`, base `main`, attended) via `fleet_repo_field` returning `""`.
```
