# Commander Config Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove hand configuration from DevFleet — the Commander creates and changes roles, projects, mission types, palettes, and prompts through one validated command surface, while the caps that bind it stay out of its reach.

**Architecture:** A new `bin/fleet-config` becomes the single door for config writes, all journaled and schema-checked. First-run setup is automatic: `fleet-session-start` bootstraps `config/roles.json` from harnesses detected on `PATH` and validates every config file each session. Because the Commander can now edit mission types, the drive caps introduced by the drive-lane plan are clamped at read time against user-owned ceilings in `config/fleet.json`, whose contents the Commander is told not to touch and whose hash is watched for drift.

**Tech Stack:** bash (`set -euo pipefail` in entrypoints, `# shellcheck shell=bash` in libraries), `jq` for all JSON, `bats-core` ≥ 1.12, `shellcheck`.

**Source spec:** [`docs/superpowers/specs/2026-07-24-devfleet-commander-drive-design.md`](../specs/2026-07-24-devfleet-commander-drive-design.md), sections *`bin/fleet-config`* and *Ceilings*.

**Depends on:** [`2026-07-24-devfleet-commander-drive.md`](2026-07-24-devfleet-commander-drive.md) — Task 1 of that plan creates `fleet_pipeline_cap`, `fleet_pipeline_driver`, `fleet_pipeline_palette_field`, and `config/missions/sortie.json`, all of which this plan modifies or reads.

## Global Constraints

- Entrypoints start with `set -euo pipefail`; libraries are `# shellcheck shell=bash` with **no side effects on source**.
- Every function is named `fleet_<area>_<verb>`.
- All JSON reads and writes go through `jq`.
- `make check` (= `shellcheck bin/*` then `bats tests/`) must be green at the end of every task.
- `config/roles.json` and `config/fleet.json` are git-ignored; only their `.example` files are committed.
- Ceiling values: built-in defaults `max_spawns_ceiling = 24`, `max_mission_seconds_ceiling = 28800`. Type-level defaults (from the drive plan) stay `max_spawns = 12`, `max_mission_seconds = 14400`.
- Every config write emits a `fleet_journal` line.
- Commit after every task with a Conventional Commits subject.

---

### Task 1: Ceilings clamp the caps

**Files:**
- Create: `config/fleet.json.example`
- Modify: `bin/fleet-pipeline`, `.gitignore`
- Test: `tests/fleet-pipeline.bats`

**Interfaces:**
- Consumes: `fleet_pipeline_file`, `fleet_die`, `$FLEET_CONFIG`.
- Produces: `fleet_pipeline_ceiling <max_spawns|max_mission_seconds>` → integer; `fleet_pipeline_cap` now returns `min(type value, ceiling)`.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-pipeline.bats`:

```bash
@test "caps are clamped by the built-in ceilings" {
  # sortie asks for more than the built-in ceiling allows
  jq '.max_spawns=999 | .max_mission_seconds=999999' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run pl 'fleet_pipeline_cap sortie max_spawns';          [ "$output" = "24" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds'; [ "$output" = "28800" ]
}

@test "a lower type value wins over the ceiling" {
  jq '.max_spawns=3' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run pl 'fleet_pipeline_cap sortie max_spawns'; [ "$output" = "3" ]
}

@test "config/fleet.json lowers the ceiling" {
  printf '{"max_spawns_ceiling":2,"max_mission_seconds_ceiling":60}\n' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  run pl 'fleet_pipeline_cap sortie max_spawns';          [ "$output" = "2" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds'; [ "$output" = "60" ]
  run pl 'fleet_pipeline_ceiling max_spawns';             [ "$output" = "2" ]
}

@test "an unknown ceiling name dies" {
  run pl 'fleet_pipeline_ceiling max_bananas'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-pipeline.bats`
Expected: FAIL — `fleet_pipeline_cap sortie max_spawns` prints `999`, and `fleet_pipeline_ceiling: command not found`.

- [ ] **Step 3: Implement the ceiling and the clamp**

In `bin/fleet-pipeline`, add above `fleet_pipeline_cap`:

```bash
# Ceilings are the user's, not the Commander's. The clamp is applied where the
# cap is READ, so hand-editing a mission type cannot route around it.
fleet_pipeline_ceiling() {  # <max_spawns|max_mission_seconds> -> integer
  local f="$FLEET_CONFIG/fleet.json" def
  case "$1" in
    max_spawns)          def=24 ;;
    max_mission_seconds) def=28800 ;;
    *) fleet_die "unknown ceiling '$1'" ;;
  esac
  if [ -f "$f" ]; then
    jq -r --arg k "${1}_ceiling" --argjson d "$def" '(.[$k] // $d)' "$f"
  else
    printf '%s' "$def"
  fi
}
```

and replace the body of `fleet_pipeline_cap` with:

```bash
fleet_pipeline_cap() {  # <type> <max_spawns|max_mission_seconds> -> min(type value, ceiling)
  local def want ceiling
  case "$2" in
    max_spawns)          def=12 ;;
    max_mission_seconds) def=14400 ;;
    *) fleet_die "unknown cap '$2'" ;;
  esac
  want="$(jq -r --arg k "$2" --argjson d "$def" '(.[$k] // $d)' "$(fleet_pipeline_file "$1")")"
  ceiling="$(fleet_pipeline_ceiling "$2")"
  if [ "$want" -gt "$ceiling" ]; then printf '%s' "$ceiling"; else printf '%s' "$want"; fi
}
```

- [ ] **Step 4: Add the example file and ignore the real one**

Create `config/fleet.json.example`:

```json
{
  "max_spawns_ceiling": 24,
  "max_mission_seconds_ceiling": 28800
}
```

Append to `.gitignore`:

```
config/fleet.json
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-pipeline.bats && make check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-pipeline config/fleet.json.example .gitignore tests/fleet-pipeline.bats
git commit -m "feat: user-owned ceilings clamp mission-type caps at read time"
```

---

### Task 2: `fleet-config validate`

**Files:**
- Create: `bin/fleet-config`, `tests/fleet-config-validate.bats`
- Modify: `bin/fleet-pipeline` (cheap parse check in `fleet_pipeline_file`)

**Interfaces:**
- Consumes: `$FLEET_CONFIG`, `$FLEET_HOME`, `$FLEET_ROOT`, `$FLEET_PROJECTS`, `fleet_die`, `fleet_journal`.
- Produces: `fleet_config_validate_type <type>` → exit 0/1, errors on stderr; `fleet_config_validate_all` → exit 0/1; the runnable `fleet-config validate [--json]`.

Validation rules, applied per mission type: the file parses; `type` is a non-empty string; `driver` is `machine` or `commander` when present; a machine type has a non-empty `stages` array, an `entry` naming one of them, and a `role` + `prompt` on every stage; a commander type has a non-empty `palette` with `name` + `role` + `prompt` on every entry; every referenced prompt file resolves under `$FLEET_HOME/prompts` or `$FLEET_ROOT/prompts`; every referenced role exists in `roles.json`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-config-validate.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mt() { echo "$FLEET_CONFIG_OVERRIDE/missions/$1.json"; }

@test "the shipped configuration validates" {
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "malformed JSON is caught" {
  printf '{ this is not json' > "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"sortie"* ]]
}

@test "a palette entry pointing at a missing prompt is caught" {
  jq '.palette[0].prompt="nope.txt"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope.txt"* ]]
}

@test "an unknown role is caught" {
  jq '.palette[0].role="wizard"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"wizard"* ]]
}

@test "an unknown driver is caught" {
  jq '.driver="autopilot"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"autopilot"* ]]
}

@test "a machine type whose entry is not a stage is caught" {
  jq '.entry="nowhere"' "$(mt campaign)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt campaign)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nowhere"* ]]
}

@test "--json lists findings as an array" {
  jq '.driver="autopilot"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate --json
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.[0].file')" != "null" ]
  [ "$(echo "$output" | jq -r '.[0].error')" != "null" ]
}

@test "spawn fails closed on an invalid type" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id c1 >/dev/null
  jq '.palette[2].prompt="gone.txt"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-spawn" --mission c1 --stage execute --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"gone.txt"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-config-validate.bats`
Expected: FAIL — `bin/fleet-config: No such file or directory`.

- [ ] **Step 3: Implement `bin/fleet-config` with the validator**

Create `bin/fleet-config`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-config - the single door for configuration writes and the schema check
# behind them (spec "bin/fleet-config"). Setup and pipeline definition are things
# the Commander does, not things the user does by hand. Dual-use: sourceable
# (fleet_config_*) and runnable. Sourced section has no side effects on source.

fleet_config_prompt_path() {  # <file> -> resolved path or "" if missing
  local p
  for p in "$FLEET_HOME/prompts/$1" "$FLEET_ROOT/prompts/$1"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  printf ''
}

# Emits "<file>\t<error>" lines on stdout; returns 1 if any were emitted.
fleet_config_validate_type() {  # <type>
  local t=$1 f="$FLEET_CONFIG/missions/$1.json" bad=0 driver
  [ -f "$f" ] || { printf '%s\tno such mission type\n' "$f"; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { printf '%s\tmalformed JSON\n' "$f"; return 1; }
  [ -n "$(jq -r '.type // ""' "$f")" ] || { printf '%s\tmissing .type\n' "$f"; bad=1; }
  driver="$(jq -r '.driver // "machine"' "$f")"
  case "$driver" in
    machine|commander) ;;
    *) printf '%s\tunknown driver "%s"\n' "$f" "$driver"; bad=1 ;;
  esac

  local names entry
  if [ "$driver" = commander ]; then
    names="$(jq -r '.palette[]?.name' "$f")"
    [ -n "$names" ] || { printf '%s\tcommander type has an empty palette\n' "$f"; bad=1; }
  else
    names="$(jq -r '.stages[]?.name' "$f")"
    [ -n "$names" ] || { printf '%s\tmachine type has no stages\n' "$f"; bad=1; }
    entry="$(jq -r '.entry // ""' "$f")"
    if [ -z "$entry" ]; then
      printf '%s\tmissing .entry\n' "$f"; bad=1
    elif ! printf '%s\n' "$names" | grep -qx "$entry"; then
      printf '%s\tentry "%s" is not one of the stages\n' "$f" "$entry"; bad=1
    fi
  fi

  local key n role prompt
  [ "$driver" = commander ] && key=palette || key=stages
  while IFS=$'\t' read -r n role prompt; do
    [ -n "$n" ] || continue
    if [ -z "$role" ]; then
      printf '%s\t%s: missing role\n' "$f" "$n"; bad=1
    elif [ "$(jq -r --arg r "$role" '(.[$r].cmd // "")' "$FLEET_CONFIG/roles.json" 2>/dev/null)" = "" ]; then
      printf '%s\t%s: unknown role "%s" (not in roles.json)\n' "$f" "$n" "$role"; bad=1
    fi
    if [ -z "$prompt" ]; then
      printf '%s\t%s: missing prompt\n' "$f" "$n"; bad=1
    elif [ -z "$(fleet_config_prompt_path "$prompt")" ]; then
      printf '%s\t%s: prompt file "%s" not found\n' "$f" "$n" "$prompt"; bad=1
    fi
  done < <(jq -r --arg k "$key" '.[$k][]? | [.name, (.role // ""), (.prompt // "")] | @tsv' "$f")

  [ "$bad" -eq 0 ]
}

fleet_config_validate_all() {  # -> "<file>\t<error>" lines; 1 if any
  local bad=0 f t
  if [ ! -f "$FLEET_CONFIG/roles.json" ]; then
    printf '%s\tmissing (run: fleet-config bootstrap)\n' "$FLEET_CONFIG/roles.json"; bad=1
  elif ! jq -e . "$FLEET_CONFIG/roles.json" >/dev/null 2>&1; then
    printf '%s\tmalformed JSON\n' "$FLEET_CONFIG/roles.json"; bad=1
  fi
  for f in "$FLEET_CONFIG"/missions/*.json; do
    [ -e "$f" ] || continue
    t="$(basename "$f" .json)"
    fleet_config_validate_type "$t" || bad=1
  done
  for f in "$FLEET_PROJECTS"/*/project.json; do
    [ -e "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || { printf '%s\tmalformed JSON\n' "$f"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fleet-common
  . "$SCRIPT_DIR/fleet-common"
  fleet_roots

  cmd="${1:-}"; shift || true
  case "$cmd" in
    validate)
      findings="$(fleet_config_validate_all || true)"
      if [ "${1:-}" = "--json" ]; then
        printf '%s' "$findings" | jq -Rsc 'split("\n") | map(select(length > 0))
          | map(split("\t") | {file: .[0], error: .[1]})'
      elif [ -z "$findings" ]; then
        echo "ok: configuration validates"
      else
        printf '%s\n' "$findings" | while IFS=$'\t' read -r file err; do
          echo "error: $file: $err" >&2
        done
      fi
      [ -z "$findings" ] ;;
    *) fleet_die "usage: fleet-config {validate} ..." ;;
  esac
fi
```

- [ ] **Step 4: Wire the fail-closed checks**

In `bin/fleet-pipeline`, make `fleet_pipeline_file` reject unparseable JSON. Every accessor
(`fleet_pipeline_field`, `_driver`, `_cap`, `_palette_field`, …) calls this, so it roughly doubles
jq invocations on the pipeline read path, including inside each watcher tick. That cost is
deliberate: a half-loaded mission type is exactly what fail-closed reads exist to catch, and the
alternative — validating only in `fleet-mission` and `fleet-spawn` — leaves the watcher reading a
corrupt graph. Keep it here.

```bash
fleet_pipeline_file() {  # <type>
  local f="$FLEET_CONFIG/missions/$1.json"
  [ -f "$f" ] || fleet_die "unknown mission type '$1' (no $f)"
  jq -e . "$f" >/dev/null 2>&1 || fleet_die "mission type '$1' is not valid JSON ($f)"
  printf '%s' "$f"
}
```

In `bin/fleet-spawn`, add the deep check — source the library with the others:

```bash
# shellcheck source=bin/fleet-config
. "$SCRIPT_DIR/fleet-config"
```

and immediately after `TYPE="$(fleet_json_get "$mj" '.type')"`:

```bash
errs="$(fleet_config_validate_type "$TYPE" || true)"
[ -z "$errs" ] || fleet_die "mission type $TYPE is invalid: $errs"
```

- [ ] **Step 5: Make it executable and run the tests**

```bash
chmod +x bin/fleet-config
bats tests/fleet-config-validate.bats && make check
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-config bin/fleet-pipeline bin/fleet-spawn tests/fleet-config-validate.bats
git commit -m "feat: fleet-config validate, with fail-closed reads and spawns"
```

---

### Task 3: `fleet-config bootstrap` and automatic first-run setup

**Files:**
- Modify: `bin/fleet-config`, `bin/fleet-session-start`
- Test: `tests/fleet-config-bootstrap.bats` (create), `tests/fleet-session-start.bats`

**Interfaces:**
- Consumes: `command -v`, `$FLEET_CONFIG`, `fleet_journal`.
- Produces: `fleet_config_bootstrap [--force]` → writes `config/roles.json`, prints the chosen mapping; `fleet-config bootstrap` subcommand. `fleet-session-start` runs it when `roles.json` is absent and runs `validate` always.

Detection lists, in priority order: frontier `claude`, `codex`, `grok`; executor `pi`, `opencode`. A harness found in the frontier list fills `frontier`; one from the executor list fills `executor`; if only one harness exists anywhere it fills both roles. The executor role is written with `"bunker": true`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-config-bootstrap.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
  mkdir -p "$FLEET_CONFIG_OVERRIDE/missions"
  cp "$REPO_ROOT"/config/missions/*.json "$FLEET_CONFIG_OVERRIDE/missions/"
  cp -r "$REPO_ROOT"/prompts "$FLEET_HOME/prompts"
  FAKEHARNESS="$FLEET_TMP/harness"; mkdir -p "$FAKEHARNESS"
  export PATH="$FAKEHARNESS:$PATH"
}
teardown() { fleet_teardown_home; }

fake() { printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEHARNESS/$1"; chmod +x "$FAKEHARNESS/$1"; }
roles() { echo "$FLEET_CONFIG_OVERRIDE/roles.json"; }

@test "bootstrap maps a frontier and an executor harness" {
  fake claude; fake pi
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "pi" ]
  [ "$(jq -r .executor.bunker "$(roles)")" = "true" ]
  [[ "$output" == *"frontier"* ]]
}

@test "a single harness fills both roles" {
  fake claude
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "claude" ]
  [[ "$output" == *"both roles"* ]]
}

@test "no harness at all dies with the list it looked for" {
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"pi"* ]]
  [ ! -f "$(roles)" ]
}

@test "bootstrap refuses to clobber without --force" {
  fake claude; fake pi
  "$REPO_ROOT/bin/fleet-config" bootstrap >/dev/null
  jq '.frontier.cmd="handmade"' "$(roles)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(roles)"
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -ne 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "handmade" ]
  run "$REPO_ROOT/bin/fleet-config" bootstrap --force
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
}

@test "the bootstrapped config validates" {
  fake claude; fake pi
  "$REPO_ROOT/bin/fleet-config" bootstrap >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}
```

Append to `tests/fleet-session-start.bats`:

```bash
@test "session start bootstraps a missing roles.json" {
  rm -f "$FLEET_CONFIG_OVERRIDE/roles.json"
  harness="$FLEET_TMP/harness"; mkdir -p "$harness"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$harness/claude"; chmod +x "$harness/claude"
  PATH="$harness:$PATH" run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_CONFIG_OVERRIDE/roles.json" ]
  [ "$(jq -r .frontier.cmd "$FLEET_CONFIG_OVERRIDE/roles.json")" = "claude" ]
}

@test "session start reports config problems without failing the session" {
  jq '.driver="autopilot"' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"config"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-config-bootstrap.bats tests/fleet-session-start.bats`
Expected: FAIL — `error: usage: fleet-config {validate} ...`, and session start writes no `roles.json`.

- [ ] **Step 3: Implement bootstrap**

Add to the sourced section of `bin/fleet-config`:

```bash
fleet_config_first_on_path() {  # <candidates…> -> first command that exists, or ""
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }; done
  printf ''
}

fleet_config_bootstrap() {  # [--force] -> writes roles.json, prints the mapping
  # Harness lists live inside the function: this library is sourced by fleet-spawn
  # and fleet-watch, and libraries here define functions only — no side effects.
  local frontier_harnesses="claude codex grok"
  local executor_harnesses="pi opencode"
  local force=0 f="$FLEET_CONFIG/roles.json" frontier executor note=""
  [ "${1:-}" = "--force" ] && force=1
  if [ -f "$f" ] && [ "$force" -eq 0 ]; then
    fleet_die "$f already exists (use --force to overwrite)"
  fi
  # shellcheck disable=SC2086  # deliberate word splitting: these are candidate lists
  frontier="$(fleet_config_first_on_path $frontier_harnesses)"
  # shellcheck disable=SC2086
  executor="$(fleet_config_first_on_path $executor_harnesses)"
  if [ -z "$frontier" ] && [ -z "$executor" ]; then
    fleet_die "no harness found on PATH (looked for: $frontier_harnesses $executor_harnesses)"
  fi
  if [ -z "$frontier" ]; then frontier="$executor"; note=" (fills both roles)"; fi
  if [ -z "$executor" ]; then executor="$frontier"; note=" (fills both roles)"; fi
  mkdir -p "$FLEET_CONFIG"
  jq -n --arg f "$frontier" --arg e "$executor" \
    '{frontier: {harness: $f, cmd: $f}, executor: {harness: $e, cmd: $e, bunker: true}}' > "$f"
  fleet_journal config-bootstrap "frontier=$frontier executor=$executor"
  printf 'roles.json written: frontier=%s executor=%s%s\n' "$frontier" "$executor" "$note"
}
```

Add the subcommand before the `*)` arm:

```bash
    bootstrap) fleet_config_bootstrap "${1:-}" ;;
```

and update the usage line to `usage: fleet-config {bootstrap|validate} ...`.

- [ ] **Step 4: Wire session start**

In `bin/fleet-session-start`, add the source line after `fleet-pipeline`:

```bash
# shellcheck source=bin/fleet-config
. "$SCRIPT_DIR/fleet-config"
```

and insert this immediately after `fleet_roots`:

```bash
if [ ! -f "$FLEET_CONFIG/roles.json" ]; then
  fleet_config_bootstrap || fleet_die "no roles.json and bootstrap failed"
fi
config_errs="$(fleet_config_validate_all || true)"
if [ -n "$config_errs" ]; then
  printf 'config problems found (fleet-config validate for detail):\n%s\n' "$config_errs" >&2
  fleet_journal config-invalid "$(printf '%s' "$config_errs" | wc -l | tr -d ' ') problems"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-config-bootstrap.bats tests/fleet-session-start.bats && make check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-config bin/fleet-session-start tests/fleet-config-bootstrap.bats tests/fleet-session-start.bats
git commit -m "feat: bootstrap roles.json from detected harnesses at session start"
```

---

### Task 4: `fleet-config roles set` and `project` passthrough

**Files:**
- Modify: `bin/fleet-config`
- Test: `tests/fleet-config-roles.bats` (create)

**Interfaces:**
- Consumes: `bin/fleet-project` (unchanged, still the implementation).
- Produces: `fleet-config roles set --role <r> --harness <h> --cmd <c> [--bunker true|false]`; `fleet-config project <args…>` forwarding verbatim to `fleet-project`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-config-roles.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

roles() { echo "$FLEET_CONFIG_OVERRIDE/roles.json"; }

@test "roles set writes harness, cmd and bunker" {
  run "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness ollama --cmd "oll run" --bunker true
  [ "$status" -eq 0 ]
  [ "$(jq -r .executor.harness "$(roles)")" = "ollama" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "oll run" ]
  [ "$(jq -r .executor.bunker "$(roles)")" = "true" ]
}

@test "roles set leaves other roles alone" {
  before="$(jq -r .frontier.cmd "$(roles)")"
  "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness pi --cmd pi
  [ "$(jq -r .frontier.cmd "$(roles)")" = "$before" ]
}

@test "roles set needs role, harness and cmd" {
  run "$REPO_ROOT/bin/fleet-config" roles set --role executor
  [ "$status" -ne 0 ]
}

@test "project passthrough creates a project" {
  run "$REPO_ROOT/bin/fleet-config" project create --name acme
  [ "$status" -eq 0 ]
  [ -f "$FLEET_PROJECTS_OVERRIDE/acme/project.json" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-config-roles.bats`
Expected: FAIL — `error: usage: fleet-config {bootstrap|validate} ...`.

- [ ] **Step 3: Implement**

Add to the `case "$cmd"` block of `bin/fleet-config`, before the `*)` arm:

```bash
    roles)
      [ "${1:-}" = set ] || fleet_die "usage: fleet-config roles set --role <r> --harness <h> --cmd <c> [--bunker true|false]"
      shift
      ROLE="" HARNESS="" RCMD="" BUNKER=""
      while [ $# -gt 0 ]; do case "$1" in
        --role) ROLE=$2; shift 2 ;;
        --harness) HARNESS=$2; shift 2 ;;
        --cmd) RCMD=$2; shift 2 ;;
        --bunker) BUNKER=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$ROLE" ] && [ -n "$HARNESS" ] && [ -n "$RCMD" ] \
        || fleet_die "need --role --harness --cmd"
      f="$FLEET_CONFIG/roles.json"
      [ -f "$f" ] || printf '{}\n' > "$f"
      tmp="$(mktemp)"
      jq --arg r "$ROLE" --arg h "$HARNESS" --arg c "$RCMD" --arg b "$BUNKER" \
        '.[$r] = ({harness: $h, cmd: $c} + (if $b == "" then {} else {bunker: ($b == "true")} end))' \
        "$f" > "$tmp" && mv "$tmp" "$f"
      fleet_journal config-roles-set "$ROLE=$RCMD"
      echo "roles.json: $ROLE -> $RCMD" ;;
    project)
      "$SCRIPT_DIR/fleet-project" "$@" ;;
```

Update the usage line to `usage: fleet-config {bootstrap|validate|roles|project} ...`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-config-roles.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-config tests/fleet-config-roles.bats
git commit -m "feat: fleet-config roles set and project passthrough"
```

---

### Task 5: `fleet-config type` — Commander-authored pipelines

**Files:**
- Modify: `bin/fleet-config`
- Test: `tests/fleet-config-type.bats` (create)

**Interfaces:**
- Consumes: `fleet_pipeline_ceiling` (Task 1), `fleet_config_validate_type` (Task 2).
- Produces: `fleet-config type create --name <t> --driver <machine|commander> [--palette <name>:<role>:<prompt> …] [--stage <name>:<role>:<prompt>:<next> …] [--entry <name>] [--max-spawns N] [--max-seconds S]`; `fleet-config type set --name <t> [--max-spawns N] [--max-seconds S] [--palette …]`; `fleet-config type show --name <t>`.

A write whose cap exceeds the ceiling is refused with the ceiling in the message. A write that would not validate is refused and the file is left untouched — build in a temp file, validate, then move.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-config-type.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mt() { echo "$FLEET_CONFIG_OVERRIDE/missions/$1.json"; }

@test "create writes a commander type with a palette" {
  run "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --palette recon:frontier:recon.txt --palette execute:executor:execute.txt --max-spawns 4
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver "$(mt probe)")" = "commander" ]
  [ "$(jq -r '.palette | length' "$(mt probe)")" = "2" ]
  [ "$(jq -r '.palette[0].prompt' "$(mt probe)")" = "recon.txt" ]
  [ "$(jq -r .max_spawns "$(mt probe)")" = "4" ]
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "a created type is immediately usable by fleet-mission" {
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --palette execute:executor:execute.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-mission" --type probe --project a --repo id:r --desc x --id p1
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver "$FLEET_STATE_OVERRIDE/missions/p1/mission.json")" = "commander" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/p1/mission.json")" = "driving" ]
}

@test "a cap above the ceiling is refused" {
  run "$REPO_ROOT/bin/fleet-config" type create --name greedy --driver commander \
    --palette execute:executor:execute.txt --max-spawns 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceiling"* ]]
  [ ! -f "$(mt greedy)" ]
}

@test "a type that would not validate is refused and nothing is written" {
  run "$REPO_ROOT/bin/fleet-config" type create --name broken --driver commander \
    --palette execute:executor:missing.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing.txt"* ]]
  [ ! -f "$(mt broken)" ]
}

@test "set changes a cap without touching the palette" {
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --palette execute:executor:execute.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-config" type set --name probe --max-spawns 2
  [ "$status" -eq 0 ]
  [ "$(jq -r .max_spawns "$(mt probe)")" = "2" ]
  [ "$(jq -r '.palette | length' "$(mt probe)")" = "1" ]
}

@test "show prints the type as JSON" {
  run "$REPO_ROOT/bin/fleet-config" type show --name sortie
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .type)" = "sortie" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-config-type.bats`
Expected: FAIL — usage error from the `*)` arm.

- [ ] **Step 3: Implement**

`bin/fleet-config` needs the pipeline library for the ceiling; add the source line in the runnable section after `fleet-common`:

```bash
  # shellcheck source=bin/fleet-pipeline
  . "$SCRIPT_DIR/fleet-pipeline"
```

Add the subcommand before the `*)` arm:

```bash
    type)
      sub="${1:-}"; shift || true
      NAME="" DRIVER="commander" ENTRY="" MAXSP="" MAXSEC="" PAL="[]" STG="[]"
      while [ $# -gt 0 ]; do case "$1" in
        --name) NAME=$2; shift 2 ;;
        --driver) DRIVER=$2; shift 2 ;;
        --entry) ENTRY=$2; shift 2 ;;
        --max-spawns) MAXSP=$2; shift 2 ;;
        --max-seconds) MAXSEC=$2; shift 2 ;;
        --palette) IFS=: read -r pn pr pp <<<"$2"
          PAL="$(printf '%s' "$PAL" | jq --arg n "$pn" --arg r "$pr" --arg p "$pp" \
                 '. + [{name: $n, role: $r, prompt: $p}]')"; shift 2 ;;
        --stage) IFS=: read -r sn sr sp sx <<<"$2"
          STG="$(printf '%s' "$STG" | jq --arg n "$sn" --arg r "$sr" --arg p "$sp" --arg x "$sx" \
                 '. + [{name: $n, role: $r, prompt: $p, next: $x}]')"; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$NAME" ] || fleet_die "need --name"
      f="$FLEET_CONFIG/missions/$NAME.json"

      case "$sub" in
        show)
          [ -f "$f" ] || fleet_die "no mission type $NAME"
          jq . "$f"; exit 0 ;;
        create|set) ;;
        *) fleet_die "usage: fleet-config type {create|set|show} --name <t> ..." ;;
      esac

      # Caps are clamped at read time; refusing here is the readable error.
      for pair in "max_spawns:$MAXSP" "max_mission_seconds:$MAXSEC"; do
        capname="${pair%%:*}"; capval="${pair#*:}"
        [ -n "$capval" ] || continue
        ceiling="$(fleet_pipeline_ceiling "$capname")"
        [ "$capval" -le "$ceiling" ] \
          || fleet_die "$capname $capval exceeds the fleet ceiling ($ceiling) — lower it or edit config/fleet.json yourself"
      done

      tmp="$(mktemp)"
      if [ "$sub" = create ]; then
        [ -f "$f" ] && fleet_die "mission type $NAME already exists (use: fleet-config type set)"
        jq -n --arg t "$NAME" --arg d "$DRIVER" --arg e "$ENTRY" \
              --argjson pal "$PAL" --argjson stg "$STG" \
          '{type: $t, driver: $d}
           + (if ($pal | length) > 0 then {palette: $pal} else {} end)
           + (if ($stg | length) > 0 then {stages: $stg} else {} end)
           + (if $e == "" then {} else {entry: $e} end)' > "$tmp"
      else
        [ -f "$f" ] || fleet_die "no mission type $NAME"
        jq --argjson pal "$PAL" --argjson stg "$STG" --arg e "$ENTRY" \
          '. + (if ($pal | length) > 0 then {palette: $pal} else {} end)
             + (if ($stg | length) > 0 then {stages: $stg} else {} end)
             + (if $e == "" then {} else {entry: $e} end)' "$f" > "$tmp"
      fi
      [ -n "$MAXSP" ]  && { jq --argjson v "$MAXSP"  '.max_spawns=$v'          "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"; }
      [ -n "$MAXSEC" ] && { jq --argjson v "$MAXSEC" '.max_mission_seconds=$v' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"; }

      # Validate the candidate in place before it becomes the real file.
      backup=""
      [ -f "$f" ] && { backup="$(mktemp)"; cp "$f" "$backup"; }
      cp "$tmp" "$f"
      if ! errs="$(fleet_config_validate_type "$NAME")"; then
        if [ -n "$backup" ]; then cp "$backup" "$f"; else rm -f "$f"; fi
        fleet_die "refused: $errs"
      fi
      fleet_journal config-type "$sub $NAME"
      echo "$f" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-config-type.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-config tests/fleet-config-type.bats
git commit -m "feat: fleet-config type create/set/show with ceiling refusal"
```

---

### Task 6: `fleet-config prompt write` and `promote`

**Files:**
- Modify: `bin/fleet-config`
- Test: `tests/fleet-config-prompt.bats` (create)

**Interfaces:**
- Consumes: `$FLEET_HOME/prompts`, mission `worktree_path`.
- Produces: `fleet-config prompt write --name <f> --text <t>`; `fleet-config prompt promote --mission <id> --label <l> --name <f>` — copies `<worktree>/.devfleet/<mission>.<label>.brief` into `prompts/<name>`, stripping the appended `fleet-done` contract footer (which `fleet-spawn` re-appends on every launch).

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-config-prompt.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id w1 >/dev/null
}
teardown() { fleet_teardown_home; }

@test "prompt write creates a usable template" {
  run "$REPO_ROOT/bin/fleet-config" prompt write --name bench.txt \
    --text "Benchmark {mission_id} in {worktree}."
  [ "$status" -eq 0 ]
  [ -f "$FLEET_HOME/prompts/bench.txt" ]
  grep -q "Benchmark {mission_id}" "$FLEET_HOME/prompts/bench.txt"
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --palette bench:executor:bench.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "promote turns an ad-hoc brief into a template without the contract footer" {
  "$REPO_ROOT/bin/fleet-spawn" --mission w1 --role executor \
    --prompt-text "Profile the hot path in {worktree}." --label prof --dry-run >/dev/null
  run "$REPO_ROOT/bin/fleet-config" prompt promote --mission w1 --label prof --name profile.txt
  [ "$status" -eq 0 ]
  grep -q "Profile the hot path" "$FLEET_HOME/prompts/profile.txt"
  ! grep -q "fleet-done" "$FLEET_HOME/prompts/profile.txt"
}

@test "promote fails when the brief does not exist" {
  run "$REPO_ROOT/bin/fleet-config" prompt promote --mission w1 --label nope --name x.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"no brief"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-config-prompt.bats`
Expected: FAIL — usage error from the `*)` arm.

- [ ] **Step 3: Implement**

Add before the `*)` arm of `bin/fleet-config`:

```bash
    prompt)
      sub="${1:-}"; shift || true
      PNAME="" PTEXT="" PMISSION="" PLABEL=""
      while [ $# -gt 0 ]; do case "$1" in
        --name) PNAME=$2; shift 2 ;;
        --text) PTEXT=$2; shift 2 ;;
        --mission) PMISSION=$2; shift 2 ;;
        --label) PLABEL=$2; shift 2 ;;
        *) fleet_die "unknown flag: $1" ;;
      esac; done
      [ -n "$PNAME" ] || fleet_die "need --name"
      mkdir -p "$FLEET_HOME/prompts"
      case "$sub" in
        write)
          [ -n "$PTEXT" ] || fleet_die "need --text"
          printf '%s\n' "$PTEXT" > "$FLEET_HOME/prompts/$PNAME"
          fleet_journal config-prompt "write $PNAME" ;;
        promote)
          [ -n "$PMISSION" ] && [ -n "$PLABEL" ] || fleet_die "need --mission and --label"
          wt="$(fleet_json_get "$(fleet_mission_json "$PMISSION")" '.worktree_path')"
          brief="$wt/.devfleet/$PMISSION.$PLABEL.brief"
          [ -f "$brief" ] || fleet_die "no brief at $brief"
          # Drop the completion-contract footer fleet-spawn appends on every launch.
          sed '/^When finished, run: fleet-done /,$d' "$brief" > "$FLEET_HOME/prompts/$PNAME"
          fleet_journal config-prompt "promote $PMISSION/$PLABEL -> $PNAME" ;;
        *) fleet_die "usage: fleet-config prompt {write|promote} ..." ;;
      esac
      echo "$FLEET_HOME/prompts/$PNAME" ;;
```

Update the usage line to `usage: fleet-config {bootstrap|validate|roles|project|type|prompt} ...`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-config-prompt.bats && make check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-config tests/fleet-config-prompt.bats
git commit -m "feat: fleet-config prompt write and promote"
```

---

### Task 7: Ceiling drift detection

Prevention is impossible — the Commander has file-write tools. Detection is not.

**Files:**
- Modify: `bin/fleet-config` (hash helper), `bin/fleet-session-start` (record), `bin/fleet-watch` (compare)
- Test: `tests/fleet-ceiling-drift.bats` (create)

**Interfaces:**
- Consumes: `sha256sum`, `fleet_decision_create`, `fleet_journal`, `fleet_mode`, `bin/fleet-wake`.
- Produces: `fleet_config_ceiling_hash` → hex digest or `none`; `fleet_config_ceiling_check` → opens one decision per change and re-records the hash. State file: `state/.fleet-config-hash`.

- [ ] **Step 1: Write the failing test**

Create `tests/fleet-ceiling-drift.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  printf '{"max_spawns_ceiling":24,"max_mission_seconds_ceiling":28800}\n' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
}
teardown() { fleet_teardown_home; }

hashfile() { echo "$FLEET_STATE_OVERRIDE/.fleet-config-hash"; }

@test "session start records the ceiling hash" {
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -s "$(hashfile)" ]
}

@test "a changed ceiling opens exactly one decision" {
  "$REPO_ROOT/bin/fleet-session-start" --no-watch >/dev/null
  printf '{"max_spawns_ceiling":999}\n' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  "$REPO_ROOT/bin/fleet-watch" --tick
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"ceiling"* ]]
  n_before="$(ls "$FLEET_STATE_OVERRIDE"/decisions/*.json | wc -l | tr -d ' ')"
  "$REPO_ROOT/bin/fleet-watch" --tick
  n_after="$(ls "$FLEET_STATE_OVERRIDE"/decisions/*.json | wc -l | tr -d ' ')"
  [ "$n_before" = "$n_after" ]
  grep -q ceiling-drift "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "an unchanged ceiling opens nothing" {
  "$REPO_ROOT/bin/fleet-session-start" --no-watch >/dev/null
  "$REPO_ROOT/bin/fleet-watch" --tick
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-ceiling-drift.bats`
Expected: FAIL — no `.fleet-config-hash` is written and no decision appears.

- [ ] **Step 3: Implement the helpers**

Add to the sourced section of `bin/fleet-config`:

```bash
fleet_config_ceiling_hash() {  # -> digest of config/fleet.json, or "none"
  local f="$FLEET_CONFIG/fleet.json"
  if [ -f "$f" ]; then sha256sum < "$f" | cut -d' ' -f1; else printf 'none'; fi
}

fleet_config_ceiling_record() {  # store the current digest as the accepted one
  fleet_config_ceiling_hash > "$FLEET_STATE/.fleet-config-hash"
}

# Ceilings are the user's. A change the user did not announce is worth one
# decision record — the file is off-limits to the Commander.
fleet_config_ceiling_check() {  # -> decision id if drift was found
  local now stored did
  now="$(fleet_config_ceiling_hash)"
  stored="$(cat "$FLEET_STATE/.fleet-config-hash" 2>/dev/null || true)"
  [ -n "$stored" ] || { printf '%s' "$now" > "$FLEET_STATE/.fleet-config-hash"; return 0; }
  [ "$now" = "$stored" ] && return 0
  printf '%s' "$now" > "$FLEET_STATE/.fleet-config-hash"   # fire once per change
  fleet_journal ceiling-drift "config/fleet.json changed"
  did="$(fleet_decision_create "fleet" "-" "ceiling" \
    "config/fleet.json changed — was that you?" "ceiling drift detected" \
    '[{"key":"ack","label":"ack","description":"the change was intentional"}]')"
  [ "$(fleet_mode)" = day ] && "$SCRIPT_DIR/fleet-wake" "decision $did: config/fleet.json changed" 2>/dev/null || true
  printf '%s' "$did"
}
```

- [ ] **Step 4: Record at session start, compare on every tick**

In `bin/fleet-session-start`, add before the final `printf`:

```bash
fleet_config_ceiling_record
```

In `bin/fleet-watch`, add the source line after `fleet-decision`:

```bash
# shellcheck source=bin/fleet-config
. "$SCRIPT_DIR/fleet-config"
```

and call the check once per tick, as the first statement of `fleet_watch_tick`:

```bash
  fleet_config_ceiling_check >/dev/null
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-ceiling-drift.bats && make check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-config bin/fleet-session-start bin/fleet-watch tests/fleet-ceiling-drift.bats
git commit -m "feat: detect drift in user-owned ceilings"
```

---

### Task 8: Documentation — zero-setup README and the Commander's config rules

**Files:**
- Modify: `README.md`, `AGENTS.md`
- Test: none (documentation); `make check` still runs

**Interfaces:**
- Consumes: everything above.
- Produces: the documented contract that setup is `git clone && make check`, and that `config/fleet.json` is off-limits to the Commander.

- [ ] **Step 1: Rewrite the README Setup section**

Replace the Setup block in `README.md` with:

```markdown
## Setup

```bash
git clone <this-repo> devfleet && cd devfleet
make check                                        # shellcheck + bats
```

That is the whole setup. On the first Commander session, `fleet-session-start` detects the
harnesses on your `PATH` and writes `config/roles.json` for you (`claude`/`codex`/`grok` fill
`frontier`, `pi`/`opencode` fill `executor`); it also validates every config file each session.
Override anything it guessed with:

```bash
bin/fleet-config roles set --role executor --harness pi --cmd pi --bunker true
bin/fleet-config validate
```

`config/roles.json` and `config/fleet.json` are git-ignored; their `.example` files are the
documentation.
```

- [ ] **Step 2: Add a Configuration section to the README**

Insert after *Mission types*:

```markdown
## Configuration is the Commander's job

`fleet-config` is the single validated door for every config write, and every write is
journaled:

| Command | Purpose |
|---|---|
| `fleet-config bootstrap [--force]` | detect harnesses, write `roles.json` |
| `fleet-config roles set --role --harness --cmd [--bunker]` | override a role |
| `fleet-config project …` | passthrough to `fleet-project` |
| `fleet-config type {create\|set\|show} --name …` | write a mission type: stage graph or palette |
| `fleet-config prompt {write\|promote} …` | add a prompt template, or promote an ad-hoc brief into one |
| `fleet-config validate [--json]` | schema-check roles, mission types, projects, prompt refs |

Anything that reads config fails closed on malformed JSON, so a bad hand edit is caught rather
than half-loaded.

### Ceilings

`config/fleet.json` holds the caps the Commander cannot raise:

```json
{ "max_spawns_ceiling": 24, "max_mission_seconds_ceiling": 28800 }
```

A mission type's `max_spawns` / `max_mission_seconds` are clamped to `min(type, ceiling)` where
they are read, so editing a type file cannot route around them. `fleet-config` refuses such a
write outright, and a change to `config/fleet.json` itself opens a decision record.
```

Also add `fleet-config {bootstrap|roles|project|type|prompt|validate}` to the command-reference table.

- [ ] **Step 3: Add the config rules to `AGENTS.md`**

Append to `AGENTS.md`:

```markdown
## Configuration

Setup, projects, repos, mission types, palettes, and prompt templates are yours to write.

- Always write them with `fleet-config`, never by hand-editing JSON — the command validates the
  result and journals the change.
- `fleet-config validate` after any config change you depend on. On a drive mission a validation
  failure also arrives as an event in your next brief.
- A step you improvised that worked is worth keeping:
  `fleet-config prompt promote --mission <id> --label <l> --name <file>`, then add it to a type's
  palette with `fleet-config type set`.
- `config/fleet.json` holds the ceilings on your own caps. It is not yours to edit. A change to
  it opens a decision record for the user.
```

- [ ] **Step 4: Verify and commit**

Run: `make check`
Expected: PASS.

```bash
git add README.md AGENTS.md
git commit -m "docs: zero-setup README and Commander config rules"
```

---

## Definition of done

- `make check` green: `shellcheck bin/*` clean, all bats tests passing.
- A fresh clone with `claude` and `pi` on `PATH` needs no manual file editing: `fleet-session-start` writes `roles.json`, and `fleet-config type create` can add a new pipeline that `fleet-mission` uses immediately.
- A mission type asking for `max_spawns: 999` yields an effective cap of 24, both through `fleet-config` (refused) and through a raw file edit (clamped).
- Changing `config/fleet.json` opens exactly one decision record and journals `ceiling-drift`.
