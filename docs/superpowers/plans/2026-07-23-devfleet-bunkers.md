# DevFleet Bunkers + Loadouts Implementation Plan (Plan 6)

> **SUPERSEDED 2026-07-24.** This plan targeted `agent-sandbox`, whose CLI never
> had the `--path`, `status`, `build`, or `--yes` surface assumed below — the
> seam was written against a contract that did not exist, and its tests passed
> only because the test fake encoded the same fiction. The bunker work now
> targets [airlock](https://github.com/jptissot/airlock), a repo-scoped fork
> built for it: see
> [`../specs/2026-07-24-airlock-design.md`](../specs/2026-07-24-airlock-design.md)
> for the design and the "devfleet follow-up" section for the seam rewrite that
> replaced Tasks 3–6 here. The two watcher-resilience fixes (Tasks 1–2) shipped
> and are unaffected.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the weakest-judgment stage (executor) inside a hardened **bunker** (agent-sandbox container) through a single `fleet-spawn` choke point, gated by a per-repo **loadout** (the committed `.agent-sandbox/` image) that must be built before a bunkered operator may launch — an unbuilt loadout raises a decision record, never a silent failure. Plus the two watcher-resilience fixes from the Plan 5 review.

**Architecture:** A new `fleet-bunker` lib is the **one seam** for all agent-sandbox calls (exactly as `fleet-backend` seams Orca and `fleet-forge` seams the forge). `fleet-spawn` asks it two questions — *is this role/repo bunkered?* and *is the loadout built?* — and, when bunkered, wraps the launch string as `agent-sandbox --yes -- <cmd>`. All the hard container mechanics (linked-worktree git mounts, network posture, SELinux, the distrobox podman shim) live **inside agent-sandbox** (its own repo, prototyped 2026‑07‑23); DevFleet's job is the choke point, the flag, and the loadout gate. A new `fleet-loadout` wraps `agent-sandbox init/build/status`.

**Tech Stack:** Bash, `jq`, `git`, `bats-core` 1.12, `shellcheck`. Orca stubbed by the fake `orca` (Plan 2); **agent-sandbox stubbed by a fake `agent-sandbox` on `PATH`** (new helper) — it is absent in this environment, so the seam is exercised through the fake exactly like `gh`/`tea`/`gum`/`lavish-axi`.

**Builds on:** Plans 1–5 (all scripts/libs/tests exist; 111 bats green). This plan **modifies** `bin/fleet-watch-lib`, `bin/fleet-watch`, `bin/fleet-spawn`, `bin/fleet-project`, `tests/helpers/common.bash`, and **adds** `bin/fleet-bunker`, `bin/fleet-loadout`. It reuses `fleet-decision` (loadout gate → record), `fleet-project` (`fleet_repo_field`), and the `fleet-spawn` launch path unchanged in shape.

**Spec:** `docs/superpowers/specs/2026-07-22-devfleet-design.md` — "Bunkers (sandboxing via agent-sandbox)" (executor-only v1, per-role/repo `bunker: true`, `fleet-spawn` wraps `agent-sandbox -- <cmd>`, markers bunker-transparent, ship creds host-side only, loadout-gate → decision record), "Loadouts" (`fleet-loadout init/build/status`, `.agent-sandbox/` is the loadout), "Components" (`bin/fleet-loadout`). The container chain was empirically validated 2026‑07‑23 (Orca visibility through the wrapper, marker round-trip, executor→endpoint); this plan wires the DevFleet side of that proof.

**Out of scope (later / other repos):** the agent-sandbox upstream work itself (worktree-aware git mounts, endpoint reachability, sandbox-key override, `--yes` non-interactive create, egress allow-list, `--ssh`) — those live in the agent-sandbox repo and are consumed here only through the `agent-sandbox` CLI; bunkering the **frontier/Commander** roles (v1 is executor-only — hardest walls on weakest judgment); the remote/ssh fleet (Phase 2); `tea-axi` companion (Plan 7).

## Global Constraints

- Same conventions as Plans 1–5: `#!/usr/bin/env bash`; entrypoints `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; `fleet_<area>_<verb>()`; `*_OVERRIDE` env roots; all JSON via `jq`; string writes via `fleet_json_set_str`; `shellcheck bin/*` + `bats tests/` green after every task.
- **One seam per external system:** every agent-sandbox call lives in `bin/fleet-bunker`. `fleet-spawn` never calls `agent-sandbox` directly — it calls the seam. Swapping the sandbox implementation touches one file.
- **Executor-only v1** (spec): only the executor role is bunkered. Frontier/Commander launch bare. The bunker decision is `role.bunker || repo.bunker`, defaulting false — an unset flag always runs bare.
- **Fail-closed loadout gate** (spec): a bunkered spawn against a repo whose loadout is not built must **not** launch bare and must **not** hang — it records a decision (`repo X has no loadout — init now?`) and dies. Ship credentials stay host-side; the bunkered launch never carries forge creds (structurally true — `fleet-ship` runs host-side, Plan 4).

## Data model (delta)

- `config/roles.json` — a role may carry `"bunker": true` (spec's executor example). Read as `.<role>.bunker // false`.
- `project.json` repos gain an optional `"bunker"` boolean (per-repo override; `fleet-project add-repo --bunker`). Absent → not overridden.
- A repo's **loadout** is its committed `.agent-sandbox/` directory (Containerfile + `config.toml`) — no DevFleet-owned format. "Built" is whatever `agent-sandbox status` reports for that path.
- No new mission.json fields; a bunkered launch differs only in `.terminal`'s underlying command (transparent — markers still land in the mounted worktree).

## File Structure (delta)

```
bin/
  fleet-bunker    # NEW seam lib: fleet_bunker_enabled / _wrap / _built (all agent-sandbox calls)
  fleet-loadout   # NEW: init/build/status (wraps agent-sandbox init/build/status)
  fleet-spawn     # MODIFIED: bunker-wrap the executor launch + fail-closed loadout gate
  fleet-project   # MODIFIED: add-repo --bunker (per-repo override)
  fleet-watch-lib # MODIFIED: fleet_watch_hash tolerates a non-git worktree (review N1)
  fleet-watch     # MODIFIED: skip stall/cycle/budget for not-started missions (N2); isolate per-mission check (N1)
tests/
  helpers/common.bash   # MODIFIED: fleet_install_fake_bunker (fake agent-sandbox) + bunker_log_has
  fleet-watch.bats      # MODIFIED: non-git worktree doesn't kill the tick (N1); queued mission not restarted (N2)
  fleet-bunker.bats     # NEW
  fleet-loadout.bats     # NEW
  fleet-spawn.bats      # MODIFIED: bunkered launch wraps; unbuilt loadout -> decision + no spawn
```

---

### Task 1: Watcher survives a non-git worktree (review N1)

**Files:**
- Modify: `bin/fleet-watch-lib` (`fleet_watch_hash`)
- Modify: `bin/fleet-watch` (`fleet_watch_tick` isolates each mission's check)
- Test: `tests/fleet-watch.bats`

**Why:** Under `set -euo pipefail`, `fleet_watch_hash` on a non-git/missing worktree exits non-zero (pipefail catches `git`'s failure), so `new="$(fleet_watch_hash "$wt")"` aborts the **whole** `fleet-watch` process — one bad worktree kills supervision for every mission. Confirmed: a non-git worktree makes the tick exit 129 before it reaches the pump. Fix both the source (hash tolerates non-git) and add depth (one mission's error can't end the loop).

**Interfaces:** `fleet_watch_hash <dir>` now always returns 0; on a non-git/missing dir it prints the stable sentinel `no-git` (so the mission reads as "unchanged" and flows into the normal stall path rather than crashing the daemon). `fleet_watch_tick` wraps each `fleet_watch_check` so a failure is journaled, not fatal.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "a non-git worktree does not kill the tick" {
  mk n1                                  # campaign mission; worktree NOT git-inited
  "$REPO_ROOT/bin/fleet-watch" --tick    # must not abort
  [ "$(stage_of n1)" != "" ]             # tick completed, mission still readable
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]   # beacon written => tick reached its end
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fleet-watch.bats -f "non-git worktree"`
Expected: FAIL — the tick aborts inside `fleet_watch_hash`; no beacon file.

- [ ] **Step 3: Make `fleet_watch_hash` tolerate a non-git worktree**

In `bin/fleet-watch-lib`, replace `fleet_watch_hash` with:

```bash
fleet_watch_hash() {  # <worktree> -> stable hash of working-tree state ("no-git" if not a repo)
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'no-git'; return 0; }
  { git -C "$1" status --porcelain 2>/dev/null; git -C "$1" diff 2>/dev/null; } \
    | sha256sum | cut -d' ' -f1
}
```

(The guard runs first, so a non-git/missing path returns a constant instead of letting `git`'s non-zero exit propagate through the pipe under `pipefail`.)

- [ ] **Step 4: Isolate each mission's check in the tick**

In `bin/fleet-watch`, change the `fleet_watch_tick` loop body so one mission's failure cannot end the loop:

```bash
fleet_watch_tick() {
  local mj id
  for mj in "$FLEET_STATE"/missions/*/mission.json; do
    [ -e "$mj" ] || continue
    id="$(fleet_json_get "$mj" '.id')"
    fleet_watch_check "$id" || fleet_journal watch-check-error "$id"
  done
  fleet_watch_beacon
  [ "$(fleet_mode)" = night ] && "$SCRIPT_DIR/fleet-night" pump >/dev/null 2>&1 || true
}
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-watch.bats && bats tests/
shellcheck bin/fleet-watch bin/fleet-watch-lib
git add bin/fleet-watch bin/fleet-watch-lib tests/fleet-watch.bats
git commit -m "fix: watcher survives a non-git worktree (review N1) + per-mission check isolation"
```

---

### Task 2: Watcher ignores not-yet-started (queued) missions (review N2)

**Files:**
- Modify: `bin/fleet-watch` (`fleet_watch_check`)
- Test: `tests/fleet-watch.bats`

**Why:** `fleet_watch_check` runs the stall/cycle/budget block on missions whose `.terminal` is null — a mission waiting in the night queue past `STALL_SECONDS` is falsely "restarted", spawned out-of-band **bypassing the cap** and burning its restart budget. Confirmed: a queued mission got `watch-restart … (stalled)` while cap was full. A mission with no terminal has not started — the pump owns its kickoff, not the stall detector.

**Interfaces:** `fleet_watch_check` returns early (no-op) when `.terminal` is null/empty — the mission is not in flight, so there is nothing to stall-detect. The marker-advance check above it still runs (a not-started mission has no markers, so it is inert there too).

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-watch.bats`:

```bash
@test "a queued (not-started) mission is never restarted by stall detection" {
  mk q9; gitify q9
  # simulate it having waited well past the stall threshold, still unstarted
  past=$(( $(date +%s) - 100000 ))
  jq --argjson p "$past" '.terminal=null | .last_progress_at=$p | .stage_started_at=$p | .state_hash="x"' \
    "$(mj q9)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj q9)"
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .terminal "$(mj q9)")" = "null" ]     # not spawned
  [ "$(jq -r .restarts "$(mj q9)")" = "0" ]        # restart budget intact
  [ "$(stage_of q9)" != "parked" ]                 # not parked
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/fleet-watch.bats -f "never restarted by stall"`
Expected: FAIL — the mission is restarted (`terminal` set, `restarts=1`).

- [ ] **Step 3: Guard `fleet_watch_check`**

In `bin/fleet-watch`, in `fleet_watch_check`, after `wt` is read and before the `# dead?` block, add a not-started guard. The relevant region becomes:

```bash
  term="$(fleet_json_get "$mj" '.terminal')"; wt="$(fleet_json_get "$mj" '.worktree_path')"
  # not started yet (queued): the pump owns kickoff, not the stall detector.
  { [ "$term" = null ] || [ -z "$term" ]; } && return 0
  local now; now="$(date +%s)"
```

(With this, the whole `# dead?` block's `if [ "$term" != null ] …` is now always entered when we reach it — a mission past this point always has a terminal. The stall/cycle/budget block below only runs for in-flight missions.)

- [ ] **Step 4: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-watch.bats && bats tests/
shellcheck bin/fleet-watch
git add bin/fleet-watch tests/fleet-watch.bats
git commit -m "fix: watcher skips not-started missions in stall detection (review N2)"
```

---

### Task 3: `fleet-bunker` seam + fake agent-sandbox helper

**Files:**
- Create: `bin/fleet-bunker`
- Modify: `tests/helpers/common.bash` (`fleet_install_fake_bunker` + `bunker_log_has`)
- Test: `tests/fleet-bunker.bats`

**Interfaces:**
- Produces (sourced):
  - `fleet_bunker_enabled <role> <project> <repo-selector>` → prints `true` if `roles.json .<role>.bunker` is true **or** the repo's `bunker` override is true, else `false`.
  - `fleet_bunker_wrap <command-string>` → prints the bunkered launch: `agent-sandbox --yes -- <command-string>`.
  - `fleet_bunker_built <repo-path>` → rc 0 if `.agent-sandbox/` exists and `agent-sandbox status` reports built, else rc 1.
- Consumes: `fleet-common` (`fleet_json_get`, `FLEET_CONFIG`), `fleet-project` (`fleet_repo_field`) — the caller sources both.
- Helper: `fleet_install_fake_bunker` drops a fake `agent-sandbox` on `PATH` logging argv to `$FLEET_BUNKER_LOG`; `FLEET_FAKE_LOADOUT_BUILT=0` makes `status` report not-built. `bunker_log_has <needle>` assertion.

- [ ] **Step 1: Write the failing test**

Add to `tests/helpers/common.bash` (after `fleet_install_fake_forge`):

```bash
# Fake agent-sandbox on PATH: log argv; `status` honors FLEET_FAKE_LOADOUT_BUILT.
fleet_install_fake_bunker() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_BUNKER_LOG="$FLEET_TMP/bunker.log"; : > "$FLEET_BUNKER_LOG"
  cat > "$fb/agent-sandbox" <<'AS'
#!/usr/bin/env bash
set -u
{ printf 'agent-sandbox'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_BUNKER_LOG"
case "${1:-}" in
  status) [ "${FLEET_FAKE_LOADOUT_BUILT:-1}" = 1 ] && exit 0 || exit 1 ;;
  init)   printf 'scaffolded\n' ;;
  build)  printf 'built\n' ;;
  *)      printf 'ran\n' ;;
esac
AS
  chmod +x "$fb/agent-sandbox"
  export PATH="$fb:$PATH"
}
bunker_log_has() { grep -qF "$1" "$FLEET_BUNKER_LOG"; }
```

Create `tests/fleet-bunker.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
}
teardown() { fleet_teardown_home; }

@test "enabled is true when the role flags bunker" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots
               fleet_bunker_enabled executor acme id:r'
  [ "$output" = "true" ]
}

@test "enabled is false for a bare role with no repo override" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots
               fleet_bunker_enabled frontier acme id:r'
  [ "$output" = "false" ]
}

@test "wrap prefixes agent-sandbox --yes --" {
  run bash -c '. "$REPO_ROOT/bin/fleet-bunker"; fleet_bunker_wrap "pi \"\$(cat brief)\""'
  [[ "$output" == "agent-sandbox --yes -- pi \"\$(cat brief)\"" ]]
}

@test "built reflects agent-sandbox status + .agent-sandbox presence" {
  repo="$FLEET_TMP/repo"; mkdir -p "$repo/.agent-sandbox"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots; fleet_bunker_built "'"$repo"'"'
  [ "$status" -eq 0 ]
  FLEET_FAKE_LOADOUT_BUILT=0 run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots; fleet_bunker_built "'"$repo"'"'
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-bunker.bats`
Expected: FAIL — `bin/fleet-bunker` missing.

- [ ] **Step 3: Write `bin/fleet-bunker`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-bunker - the ONE seam for agent-sandbox (bunker) ops (spec "Bunkers").
# v1: executor role only; frontier/Commander run bare. All hard container
# mechanics (worktree mounts, network, SELinux, distrobox shim) live INSIDE
# agent-sandbox; this seam is thin. Sourced only; no side effects on source.

# true if the role flags bunker, or the repo overrides bunker=true.
fleet_bunker_enabled() {  # <role> <project> <repo-selector>
  local role=$1 project=$2 repo=$3 rb pb
  rb="$(fleet_json_get "$FLEET_CONFIG/roles.json" ".${role}.bunker // false")"
  [ "$rb" = true ] && { printf 'true'; return 0; }
  pb="$(fleet_repo_field "$project" "$repo" bunker)"
  [ "$pb" = true ] && { printf 'true'; return 0; }
  printf 'false'
}

# Wrap a launch command to run inside the bunker (the one choke point).
# --yes = non-interactive create (fail-closed, never hangs on an approval prompt).
fleet_bunker_wrap() {  # <command-string> -> wrapped command-string
  printf 'agent-sandbox --yes -- %s' "$1"
}

# rc 0 if the repo's loadout (.agent-sandbox/) exists and is built.
fleet_bunker_built() {  # <repo-path>
  [ -d "$1/.agent-sandbox" ] || return 1
  agent-sandbox status --path "$1" >/dev/null 2>&1
}
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-bunker.bats
shellcheck bin/fleet-bunker
git add bin/fleet-bunker tests/helpers/common.bash tests/fleet-bunker.bats
git commit -m "feat: fleet-bunker seam (enabled/wrap/built) + fake agent-sandbox helper"
```

---

### Task 4: `fleet-loadout` (init / build / status)

**Files:**
- Create: `bin/fleet-loadout`
- Test: `tests/fleet-loadout.bats`

**Interfaces:**
- Consumes: `fleet-common`, `fleet-bunker`.
- Produces: `fleet-loadout {init|build|status} --path <repo-path>` — `init` scaffolds via `agent-sandbox init --path`, `build` builds via `agent-sandbox build --path` (agent-sandbox's own approval gate), `status` prints `built` (rc 0) or `not-built` (rc 1) via `fleet_bunker_built`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-loadout.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  REPO="$FLEET_TMP/repo"; mkdir -p "$REPO"
}
teardown() { fleet_teardown_home; }

@test "init scaffolds via agent-sandbox init" {
  run "$REPO_ROOT/bin/fleet-loadout" init --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has $'agent-sandbox\x1finit\x1f--path'
}

@test "build builds via agent-sandbox build" {
  run "$REPO_ROOT/bin/fleet-loadout" build --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has $'agent-sandbox\x1fbuild\x1f--path'
}

@test "status reports built vs not-built" {
  mkdir -p "$REPO/.agent-sandbox"
  run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -eq 0 ]; [[ "$output" == "built" ]]
  FLEET_FAKE_LOADOUT_BUILT=0 run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -ne 0 ]; [[ "$output" == "not-built" ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-loadout.bats`
Expected: FAIL — `bin/fleet-loadout` missing.

- [ ] **Step 3: Write `bin/fleet-loadout`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fleet-common
. "$SCRIPT_DIR/fleet-common"
# shellcheck source=bin/fleet-project
. "$SCRIPT_DIR/fleet-project"
# shellcheck source=bin/fleet-bunker
. "$SCRIPT_DIR/fleet-bunker"
fleet_roots

cmd="${1:-}"; shift || true
path=""
while [ $# -gt 0 ]; do case "$1" in
  --path) path=$2; shift 2 ;;
  *) fleet_die "unknown flag: $1" ;;
esac; done
[ -n "$path" ] || fleet_die "need --path <repo-path>"

case "$cmd" in
  init)   agent-sandbox init  --path "$path"; fleet_journal loadout-init  "$path" ;;
  build)  agent-sandbox build --path "$path"; fleet_journal loadout-build "$path" ;;
  status)
    if fleet_bunker_built "$path"; then echo built; else echo not-built; exit 1; fi ;;
  *) fleet_die "usage: fleet-loadout {init|build|status} --path <repo-path>" ;;
esac
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/fleet-loadout.bats
shellcheck bin/fleet-loadout
git add bin/fleet-loadout tests/fleet-loadout.bats
git commit -m "feat: fleet-loadout init/build/status (wraps agent-sandbox)"
```

---

### Task 5: `fleet-spawn` bunker-wrap + fail-closed loadout gate

**Files:**
- Modify: `bin/fleet-spawn` (source seams; wrap launch; loadout gate)
- Modify: `bin/fleet-project` (add-repo `--bunker`)
- Test: `tests/fleet-spawn.bats`, `tests/fleet-project.bats`

**Interfaces:** `fleet-spawn` reads the mission's `.project`/`.repo`, asks `fleet_bunker_enabled "$ROLE" "$PROJECT" "$REPO"`; when true it wraps `LAUNCH` via `fleet_bunker_wrap` (visible in `--dry-run`) and, on the real spawn path, refuses if `fleet_bunker_built` is false — recording a decision (`repo X has no loadout — init now?`) via `fleet_decision_create` and dying (fail-closed). `fleet-project add-repo` gains `--bunker` to set the per-repo override.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fleet-project.bats`:

```bash
@test "add-repo --bunker sets the per-repo override" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode local-merge --bunker >/dev/null
  [ "$(jq -r '.repos[0].bunker' "$FLEET_PROJECTS_OVERRIDE/acme/project.json")" = "true" ]
}
```

Add to `tests/fleet-spawn.bats` (this file loads `helpers/common`; ensure `fleet_install_fake_bunker` is called — add it to that file's `setup` alongside the fake orca):

```bash
@test "a bunkered executor stage wraps the launch in agent-sandbox (dry-run)" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s1 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox --yes --"* ]]
}

@test "a bunkered spawn with an unbuilt loadout records a decision and does not launch" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"     # repo dir exists but NO .agent-sandbox -> not built
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s2 >/dev/null
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-spawn" --mission s2 --stage execute
  [ "$status" -ne 0 ]
  ! orca_log_has $'terminal\x1fcreate'                       # nothing launched
  [[ "$("$REPO_ROOT/bin/fleet-decision" list --open)" == *"s2"* ]]   # decision recorded
  [[ "$("$REPO_ROOT/bin/fleet-decision" list --open)" == *"loadout"* ]]
}

@test "a non-bunkered stage still launches bare" {
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s3 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s3 --stage plan --dry-run   # plan = frontier, not bunkered
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent-sandbox"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-spawn.bats tests/fleet-project.bats -f "bunker|loadout"`
Expected: FAIL — no wrap, no gate; `--bunker` is an unknown flag.

- [ ] **Step 3: Add `--bunker` to `fleet-project add-repo`**

In `bin/fleet-project`, add a flag + field. In the `add-repo)` arm, add the flag parse (alongside the others) and default:

```bash
      project="" sel="" path="" branch="main" forge="" mode="report-only" unatt=false bunker=false
      while [ $# -gt 0 ]; do case "$1" in
        --project) project=$2; shift 2 ;;
        --repo) sel=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        --default-branch) branch=$2; shift 2 ;;
        --forge) forge=$2; shift 2 ;;
        --ship-mode) mode=$2; shift 2 ;;
        --unattended) unatt=true; shift ;;
        --bunker) bunker=true; shift ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
```

and add `bunker` to the written object:

```bash
      jq --arg s "$sel" --arg p "$path" --arg b "$branch" --arg f "$forge" --arg m "$mode" \
         --argjson u "$unatt" --argjson bk "$bunker" \
        '.repos = ((.repos // []) | map(select(.selector != $s))
                   + [{selector:$s,path:$p,default_branch:$b,forge:$f,ship_mode:$m,unattended:$u,bunker:$bk}])' \
        "$pj" > "$tmp" && mv "$tmp" "$pj"
```

- [ ] **Step 4: Wire `fleet-spawn`**

In `bin/fleet-spawn`, add the seam sources after the existing ones (after `fleet-pipeline`):

```bash
# shellcheck source=bin/fleet-project
. "$SCRIPT_DIR/fleet-project"
# shellcheck source=bin/fleet-bunker
. "$SCRIPT_DIR/fleet-bunker"
# shellcheck source=bin/fleet-decision
. "$SCRIPT_DIR/fleet-decision"
```

Read project/repo alongside the other mission fields (near `TYPE=…`/`WT=…`):

```bash
PROJECT="$(fleet_json_get "$mj" '.project')"
REPO="$(fleet_json_get "$mj" '.repo')"
```

Then, right after `LAUNCH="$CMD \"\$(cat \"$brief\")\""` and **before** the `if [ "$DRY" -eq 1 ]` block, insert the bunker wrap + gate:

```bash
# Bunker (spec "Bunkers"): executor-only, one choke point. Wrap the launch and,
# on the real spawn path, fail closed if the repo's loadout is not built.
if [ "$(fleet_bunker_enabled "$ROLE" "$PROJECT" "$REPO")" = true ]; then
  if [ "$DRY" -ne 1 ]; then
    repo_path="$(fleet_repo_field "$PROJECT" "$REPO" path)"
    if [ -z "$repo_path" ] || ! fleet_bunker_built "$repo_path"; then
      fleet_decision_create "$MISSION" "$PROJECT" "$STAGE" \
        "repo $REPO has no built loadout — init now?" "bunkered spawn blocked" \
        '[{"key":"init","label":"init loadout","description":"scaffold+build the bunker image"}]' >/dev/null
      fleet_journal bunker-blocked "$MISSION $REPO (loadout not built)"
      fleet_die "bunkered spawn blocked: repo $REPO loadout not built (decision recorded)"
    fi
  fi
  LAUNCH="$(fleet_bunker_wrap "$LAUNCH")"
fi
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-spawn.bats tests/fleet-project.bats && bats tests/
shellcheck bin/fleet-spawn bin/fleet-project
git add bin/fleet-spawn bin/fleet-project tests/fleet-spawn.bats tests/fleet-project.bats
git commit -m "feat: fleet-spawn bunker-wrap executor + fail-closed loadout gate (decision record)"
```

---

### Task 6: End-to-end — bunkered executor, host-side ship, status

**Files:**
- Modify: `tests/fleet-e2e.bats`
- Test: `tests/fleet-e2e.bats`

**Interfaces:** no new code — an end-to-end proof that a bunkered executor launches through the wrapper (markers still land in the mounted worktree, so the pipeline advances) while the host-side ship path stays outside the bunker.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-e2e.bats` (ensure its `setup` installs the fake bunker — add `fleet_install_fake_bunker` beside the fake orca):

```bash
@test "bunkered executor launches through agent-sandbox; ship stays host-side" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo/.agent-sandbox"     # loadout present + built (fake status=built)
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id bk1 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission bk1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox --yes -- "* ]]     # executor bunkered
  # the frontier plan stage is NOT bunkered (executor-only v1)
  run "$REPO_ROOT/bin/fleet-spawn" --mission bk1 --stage plan --dry-run
  [[ "$output" != *"agent-sandbox"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-e2e.bats -f "bunkered executor"`
Expected: FAIL until Task 5 is in place (here it verifies the integrated path end to end).

- [ ] **Step 3: (already implemented by Task 5) — confirm green**

No new production code. Run the case; it passes on the Task 5 wiring.

- [ ] **Step 4: Full suite; make check; commit**

```bash
bats tests/
make check
git add tests/fleet-e2e.bats
git commit -m "test: e2e bunkered executor wraps; frontier + ship stay bare/host-side"
```

---

## Self-Review

**Spec coverage (Bunkers slice):**
- Executor-only bunker via a per-role/per-repo flag, `fleet-spawn` wraps `agent-sandbox -- <cmd>` at one choke point → Tasks 3, 5 ✓
- Loadout = committed `.agent-sandbox/`; `fleet-loadout init/build/status` → Task 4 ✓
- Fail-closed loadout gate: unbuilt → decision record, no silent error, no hang → Task 5 ✓
- Markers bunker-transparent (launch differs only in wrapping; worktree is mounted) → Tasks 5, 6 ✓
- Ship credentials host-side only (ship runs outside the bunker) → asserted structurally in Task 6 ✓
- All agent-sandbox mechanics behind one seam (swap = one file) → Task 3 ✓
- Review N1 (non-git worktree kills watcher) → Task 1; N2 (queued mission restarted) → Task 2 ✓

**Deferred (later / other repos, explicitly):** the agent-sandbox upstream blockers (worktree git mounts, endpoint reachability, sandbox-key, `--yes` create, egress allow-list, `--ssh`) — consumed via the CLI, not built here; bunkering frontier/Commander (v1 executor-only); remote/ssh fleet (Phase 2); `tea-axi` (Plan 7).

**Type consistency:** `fleet_bunker_enabled <role> <project> <repo-selector>` (Task 3) is called with that exact arg order from `fleet-spawn` (Task 5). `fleet_bunker_wrap`/`fleet_bunker_built` (Task 3) are consumed by `fleet-spawn` (Task 5) and `fleet-loadout` (Task 4). The repo `bunker` field written by `fleet-project add-repo --bunker` (Task 5) is read by `fleet_repo_field … bunker` inside `fleet_bunker_enabled` (Task 3). The loadout-gate decision reuses `fleet_decision_create <mission> <project> <stage> <question> <context> <opts-json>` (Plan 3) with the same signature. `fleet_watch_hash` (Task 1) still returns a single hash token consumed by `fleet_watch_cycle`/`fleet_watch_stalled` unchanged.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every code step carries complete, runnable code. The fake `agent-sandbox` stands in for the real (absent) tool exactly as the fake `orca`/`gh`/`tea` do.

**Idempotency & safety:** the bunker gate is fail-closed — a bunkered spawn never silently falls back to bare and never launches against an unbuilt loadout; the decision record dedups on mission+stage (Plan 3), so repeated gated spawns don't spam records. `--dry-run` shows the wrapped command without side effects (no gate, no decision). N1's `fleet_watch_hash` guard makes the watcher tolerant of any non-git worktree (bunker mounts included) instead of fatal; the per-mission `|| fleet_journal` in the tick contains a single mission's failure. N2's not-started guard keeps queued missions inert until the pump owns their kickoff, so the cap is never bypassed.
```
