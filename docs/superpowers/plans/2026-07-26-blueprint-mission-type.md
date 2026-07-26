# Blueprint Mission Type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `blueprint` mission type — an interview that produces a reviewed spec — and the general `interactive` stage property it needs.

**Architecture:** Three separable pieces. (1) A new stage-level boolean `interactive` that `fleet_detect_anomaly` consults to stand down the four "nothing is happening" verdicts while keeping every liveness check, plus its own clamped budget. (2) Two new required mission-type fields, `description` and `when_to_use`, with the writer flag that makes them creatable. (3) The `blueprint` pipeline itself — one JSON file, three prompts, and one provisioning pair in `roles.json`. Pieces 1 and 2 are general; only piece 3 is blueprint-specific.

**Tech Stack:** bash 4+, `jq`, `bats-core` ≥ 1.12, `shellcheck`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-25-blueprint-mission-type-design.md`

## Global Constraints

- Entrypoints use `set -euo pipefail`. Libraries carry `# shellcheck shell=bash` and have **no side effects on source**.
- Every function is named `fleet_<area>_<verb>`.
- All JSON reads and writes go through `jq`. Never parse JSON with `grep`/`sed`.
- `make check` is `shellcheck bin/*` then `bats tests/`. It must be green at the end of **every** task.
- The suite is fully offline. Tests drive the fake `orca` in `tests/helpers/common.bash`; never call a real network or a real container.
- `FLEET_INTERACTIVE_BUDGET_SECONDS` default is **14400**. `blueprint.json` declares `max_mission_seconds: 21600`. The ceiling in `config/fleet.json` is **28800**. The invariant is `interactive stage cap < mission cap ≤ ceiling`.
- `fleet_pipeline_field` returns `""` for unset and the **string** `"true"`/`"false"` for booleans — compare against `true` as a string, never with `[ -n ]`.
- Do not rename `terminal`. It already means "last stage in the graph" (`config/missions/recon.json`, stage `report`).
- Commit after every task. Never commit `config/roles.json` or `config/fleet.json` — both are git-ignored.

---

## File Structure

**Modified**
- `bin/fleet-detect` — consult `interactive`; gate idle/stalled/cycle/loop; substitute the budget.
- `bin/fleet-pipeline` — add `fleet_pipeline_interactive_budget`.
- `bin/fleet-config` — require and write `description` / `when_to_use`.
- `config/roles.json.example` — gain a `provision` list so the skills install has a committed record.
- `config/missions/{campaign,strike,recon,fortify,sortie}.json` — backfill the two new fields.
- `tests/fleet-detect.bats` — harness sources `fleet-pipeline`; new interactive tests.
- `tests/fleet-config-roles.bats` — validator tests for the new fields.
- `README.md`, `docs/SETUP.md` — document the type and the property.

**Created**
- `config/missions/blueprint.json`
- `prompts/blueprint/interview.txt`, `prompts/blueprint/review.txt`, `prompts/blueprint/refine.txt`
- `tests/fleet-blueprint.bats`

**Not touched:** `bin/fleet-advance` (the review ladder already does what blueprint needs), `bin/fleet-night` (its `case` already rejects unknown types — see spec 2 requirements).

---

### Task 1: `interactive` stands down the idle and stalled verdicts

**Files:**
- Modify: `bin/fleet-detect:86-98`
- Test: `tests/fleet-detect.bats` (harness at line 14, new tests at end)

**Interfaces:**
- Consumes: `fleet_pipeline_field <type> <stage> <field>` from `bin/fleet-pipeline:21`, which returns `""` when unset and the string `"true"` for a true boolean.
- Produces: nothing new. `fleet_detect_anomaly` keeps its signature `<id> <now_epoch> <stall_seconds> <budget_seconds>` and its contract of printing a reason word or nothing.

**Context the implementer needs:** `bin/fleet-watch` sources `fleet-pipeline` (line 9) before `fleet-detect` (line 21), so the function is already in scope at runtime. The bats helper does **not**, which is why Step 1 changes it. Verify the same for `bin/fleet-drive` in Step 6.

- [ ] **Step 1: Add the missing source to the test harness**

In `tests/fleet-detect.bats`, the `detect()` helper on line 14. Add `fleet-pipeline` to the source list, before `fleet-detect`:

```bash
detect() {  # <id> <now> <stall> <budget>
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-backend"; . "$REPO_ROOT/bin/fleet-pipeline"; . "$REPO_ROOT/bin/fleet-watch-lib"; . "$REPO_ROOT/bin/fleet-detect"; fleet_roots; fleet_detect_anomaly '"$*"
}
```

- [ ] **Step 2: Run the suite to confirm the harness change broke nothing**

Run: `bats tests/fleet-detect.bats`
Expected: PASS, same count as before the edit.

- [ ] **Step 3: Write the failing tests**

Append to `tests/fleet-detect.bats`. `fleet_seed_config` copies the real `config/missions/*.json` into the temp home, so these write a throwaway type file rather than depending on `blueprint.json`, which does not exist yet.

```bash
# An interactive stage is one a human is expected to be sitting in front of.
# Silence there is the normal state, not a symptom.
mk_interactive_type() {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/talky.json" <<'JSON'
{
  "type": "talky",
  "description": "test type with an interactive stage",
  "when_to_use": "tests only",
  "entry": "chat",
  "stages": [
    { "name": "chat", "role": "frontier", "prompt": "spec.txt", "interactive": true, "next": "done" },
    { "name": "done", "terminal": true }
  ]
}
JSON
  setj d1 '.type="talky" | .stage="chat"'
}

@test "an interactive stage is not idle when its agent reports done" {
  # The agent has asked a question and is waiting. On a normal stage this is
  # `idle` on the very next tick, with no grace period at all.
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_AGENT_STATE=done run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a non-interactive stage with the same state is still idle" {
  # The control. Without this, the test above passes for the wrong reason.
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_AGENT_STATE=done run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ "$output" = idle ]
}

@test "an interactive stage is not stalled however long the screen sits still" {
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_TERM_TAIL=frozen run detect d1 1 1 999999999   # record the baseline
  FLEET_FAKE_TERM_TAIL=frozen run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an interactive stage still reports a terminal that has gone" {
  # Liveness is the half that must survive. A crashed agent in an interactive
  # stage would otherwise sit dead forever with the operator assuming it waits.
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_TERM_GONE=1 run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ "$output" = terminal-gone ]
}

@test "an interactive stage still reports a non-null exit code" {
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_EXIT=3 run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ "$output" = "exit:3" ]
}

@test "an interactive stage still reports a trust prompt" {
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"trust"' run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [[ "$output" == blocked:* ]]
}
```

- [ ] **Step 4: Add the agent-state knob the tests need**

`FLEET_FAKE_AGENT_STATE` does not exist yet. `fleet_backend_agent_state` reads a real JSON feed, so the fake needs an override. In `bin/fleet-backend`, at the top of `fleet_backend_agent_state`:

```bash
fleet_backend_agent_state() {  # <handle> -> "<state>\t<startedAtMs>" or ""
  # Test seam: the real feed is a file orca maintains on the host, which a test
  # cannot produce without reaching outside its temp home.
  if [ -n "${FLEET_FAKE_AGENT_STATE:-}" ]; then
    printf '%s\t0' "$FLEET_FAKE_AGENT_STATE"; return 0
  fi
  local handle=$1 feed pane
```

Leave the rest of the function unchanged.

- [ ] **Step 5: Run the tests to verify they fail**

Run: `bats tests/fleet-detect.bats`
Expected: the two "not idle" / "not stalled" interactive tests FAIL (they report `idle`/`stalled`). The three liveness tests and the non-interactive control PASS already — they are regression guards, not new behaviour.

- [ ] **Step 6: Confirm `fleet-drive` also has `fleet-pipeline` in scope**

Run: `grep -n 'fleet-pipeline\|fleet-detect' bin/fleet-drive`
Expected: `fleet-pipeline` sourced before `fleet-detect`. If it is not, add it — `fleet_drive_check` calls `fleet_detect_anomaly` and would break at runtime with an unbound function.

- [ ] **Step 7: Resolve the flag in `fleet_detect_anomaly`**

In `bin/fleet-detect`, inside `fleet_detect_anomaly`, immediately after the existing `wt=` assignment near the top:

```bash
  local type stage interactive
  type="$(fleet_json_get "$mj" '.type')"
  stage="$(fleet_json_get "$mj" '.stage')"
  # A stage that declares itself interactive is one a human is expected to be
  # sitting in front of. Silence there is the normal state, so the four verdicts
  # that mean "nothing is happening" are not evidence of anything. Liveness still
  # is: a crashed agent must not read as a patient one.
  interactive="$(fleet_pipeline_field "$type" "$stage" interactive)"
```

- [ ] **Step 8: Gate the idle and stalled block**

Replace the `if ! fleet_watch_human_draft ...` condition at `bin/fleet-detect:93` so an interactive stage skips the whole block. Note this also skips the terminal read the draft guard performs, which is a saving, not a loss:

```bash
  if [ "$interactive" != true ] \
     && ! fleet_watch_human_draft "$(fleet_backend_terminal_tail "$term")"; then
    if [ "$agent_state" = "done" ]; then printf 'idle'; return 0; fi
    if [ -z "$agent_state" ] && [ "$satisfied" = true ] \
       && [ "$(( now - last ))" -ge "${FLEET_NUDGE_SECONDS:-120}" ]; then
      printf 'idle'; return 0
    fi
    if fleet_watch_stalled "$old" "$new" "$last" "$now" "$stall"; then printf 'stalled'; return 0; fi
  fi
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bats tests/fleet-detect.bats`
Expected: PASS, all of them.

- [ ] **Step 10: Run the whole suite**

Run: `make check`
Expected: rc 0, shellcheck silent.

- [ ] **Step 11: Commit**

```bash
git add bin/fleet-detect bin/fleet-backend tests/fleet-detect.bats
git commit -m "feat(detect): a stage may declare itself interactive

The machine has never had a concept of a stage that is supposed to be
waiting. Every stage is assumed to be autonomous work, so silence reads
as failure — and with the agent's hook state at done, fleet-detect
returns idle on the very next tick with no grace period at all. An
interview cannot survive that.

A stage that declares interactive: true stands down idle and stalled.
Liveness is untouched: a gone terminal, a non-null exit and a trust
prompt all still report, because a crashed agent must not be mistaken
for a patient one."
```

---

### Task 2: `interactive` stands down cycle and loop

**Files:**
- Modify: `bin/fleet-detect:57-65`
- Test: `tests/fleet-detect.bats`

**Interfaces:**
- Consumes: the `interactive` local from Task 1, resolved before this block runs.
- Produces: nothing new.

**Context:** `fleet_watch_cycle` and `fleet_watch_screen_loop` both **append to a history file as a side effect**. Skipping the calls for an interactive stage means no history accrues, which is correct — there is no loop to detect in a conversation — but it is why the gate goes on the call and not on the result.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-detect.bats`:

```bash
@test "an interactive stage does not report a cycle" {
  # A conversation returns to the same worktree hash constantly: the tree does
  # not change while two people talk. That is not an edit-revert loop.
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  wt="$(jq -r .worktree_path "$(mj d1)")"
  for v in A B A B A B; do
    echo "$v" > "$wt/seed.txt"
    run detect d1 999999999 999999999 999999999
    [ -z "$output" ]
  done
}

@test "an interactive stage does not report a screen loop" {
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  wt="$(jq -r .worktree_path "$(mj d1)")"
  for i in 1 2 3 4 5 6 7 8 9; do
    echo "$i" > "$wt/seed.txt"
    FLEET_FAKE_TERM_TAIL="$(( i % 2 ))" run detect d1 999999999 999999999 999999999
    [ -z "$output" ]
  done
}

@test "a non-interactive stage still reports a cycle" {
  # The control for the pair above.
  setj d1 '.terminal="term_001"'
  wt="$(jq -r .worktree_path "$(mj d1)")"
  seen=""
  for v in A B A B A B; do
    echo "$v" > "$wt/seed.txt"
    run detect d1 999999999 999999999 999999999
    [ "$output" = cycle ] && seen=yes
  done
  [ "$seen" = yes ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-detect.bats -f interactive`
Expected: the two interactive tests FAIL, reporting `cycle` / `loop`. The control PASSES.

- [ ] **Step 3: Gate both detectors**

In `bin/fleet-detect`, inside the `if [ "$new" != "$old" ]` branch:

```bash
    if [ "$interactive" != true ] && fleet_watch_cycle "$hashes" "$tree"; then
      printf 'cycle'; return 0
    fi
    # Looping agents *are* moving, so this has to be judged on the progress path
    # rather than the stall one: same screens coming round again while the files
    # churn underneath.
    if [ "$interactive" != true ] && [ -n "$screen" ] \
       && fleet_watch_screen_loop "$screens" "$screen" \
            "${FLEET_LOOP_WINDOW:-8}" "${FLEET_LOOP_REPEATS:-3}"; then
      printf 'loop'; return 0
    fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/fleet-detect.bats`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-detect tests/fleet-detect.bats
git commit -m "feat(detect): cycle and loop stand down on an interactive stage

Two people talking leave the worktree hash unchanged for minutes at a
time, and a TUI redraws the same frames while they do. Both read as
pathology to detectors built for an agent working alone. The gate is on
the call rather than the result because each detector appends to a
history file as it goes, and an interactive stage has no history worth
keeping."
```

---

### Task 3: The interactive budget, clamped by the ceiling

**Files:**
- Modify: `bin/fleet-pipeline` (new function after `fleet_pipeline_cap`)
- Modify: `bin/fleet-detect` (substitute the budget before the over-budget check)
- Test: `tests/fleet-detect.bats`, `tests/fleet-pipeline.bats`

**Interfaces:**
- Consumes: `fleet_pipeline_ceiling <cap-name>`, already used by `fleet_pipeline_cap` at `bin/fleet-pipeline:79`.
- Produces: `fleet_pipeline_interactive_budget <type> -> integer seconds`, clamped to `min(FLEET_INTERACTIVE_BUDGET_SECONDS, max_mission_seconds_ceiling)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-pipeline.bats`:

```bash
@test "the interactive budget defaults to four hours" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = 14400 ]
}

@test "the interactive budget is clamped by the mission-seconds ceiling" {
  # A cap the operator can raise from the environment is not a cap. This is the
  # same clamp every other budget goes through.
  echo '{"max_spawns_ceiling":24,"max_mission_seconds_ceiling":600}' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  FLEET_INTERACTIVE_BUDGET_SECONDS=99999 run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = 600 ]
}

@test "an interactive budget below the ceiling is honoured as given" {
  FLEET_INTERACTIVE_BUDGET_SECONDS=300 run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = 300 ]
}
```

And to `tests/fleet-detect.bats`:

```bash
@test "an interactive stage goes over budget on its own larger cap" {
  # The caller passes the normal stage budget. An interactive stage ignores it
  # and uses the interactive one, so a five-second budget must not fire.
  mk_interactive_type
  setj d1 '.terminal="term_001" | .stage_started_at=0'
  FLEET_INTERACTIVE_BUDGET_SECONDS=999999 run detect d1 100000 999999999 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an interactive stage does eventually go over budget" {
  # An abandoned interview must not pin a worktree and a container open forever.
  mk_interactive_type
  setj d1 '.terminal="term_001" | .stage_started_at=0'
  FLEET_INTERACTIVE_BUDGET_SECONDS=10 run detect d1 100000 999999999 999999999
  [ "$status" -eq 0 ]
  [ "$output" = over-budget ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-pipeline.bats tests/fleet-detect.bats`
Expected: FAIL — `fleet_pipeline_interactive_budget: command not found`, and the detect pair reporting the wrong verdict.

- [ ] **Step 3: Add the budget function**

In `bin/fleet-pipeline`, immediately after `fleet_pipeline_cap`:

```bash
# The wall clock an interactive stage is allowed. It is not a per-type field:
# a human's pace is a property of there being a human, not of the pipeline, so
# one number covers every interactive stage and the environment can tune it.
#
# Clamped exactly like every other budget. A cap that could be raised from the
# environment would let an interactive stage outrun the mission ceiling, which
# is the one number the Commander may not touch.
fleet_pipeline_interactive_budget() {  # <type> -> seconds
  local want ceiling
  want="${FLEET_INTERACTIVE_BUDGET_SECONDS:-14400}"
  ceiling="$(fleet_pipeline_ceiling max_mission_seconds)"
  if [ "$want" -gt "$ceiling" ]; then printf '%s' "$ceiling"; else printf '%s' "$want"; fi
}
```

- [ ] **Step 4: Substitute the budget in `fleet_detect_anomaly`**

In `bin/fleet-detect`, replace the final over-budget check:

```bash
  # The budget stays hard, but an interview runs on a human clock. Substituting
  # here rather than at the call sites keeps fleet-watch and fleet-drive from
  # having to know which stages are interactive.
  local eff_budget="$budget"
  if [ "$interactive" = true ]; then
    eff_budget="$(fleet_pipeline_interactive_budget "$type")"
  fi
  if fleet_watch_over_budget "$started" "$now" "$eff_budget"; then printf 'over-budget'; return 0; fi
  return 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-pipeline.bats tests/fleet-detect.bats`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-pipeline bin/fleet-detect tests/fleet-pipeline.bats tests/fleet-detect.bats
git commit -m "feat(pipeline): an interactive stage runs on a human clock

Standing down idle and stalled leaves nothing to catch an interview
nobody came back to. The budget stays hard, on a larger number: four
hours by default, clamped by max_mission_seconds_ceiling like every
other cap, so it cannot be used to outrun the one limit the Commander
may not raise.

Substituted inside fleet_detect_anomaly, which already holds the mission
JSON, so neither fleet-watch nor fleet-drive has to learn which stages
are interactive."
```

---

### Task 4: Mission types declare what they are for

**Files:**
- Modify: `bin/fleet-config` (`fleet_config_validate_type`, around line 43-60)
- Modify: `config/missions/campaign.json`, `strike.json`, `recon.json`, `fortify.json`, `sortie.json`
- Test: `tests/fleet-config-roles.bats`

**Interfaces:**
- Consumes: nothing new.
- Produces: two required top-level fields on every mission type — `description` (string, non-empty) and `when_to_use` (string, non-empty). `fleet_config_validate_type` fails closed on either being absent or empty.

**Context:** `fleet_config_validate_type` validates both drivers — machine types key on `.stages`, commander types on `.palette`. The new fields are required of **both**, so the check goes before the driver split. Backfill in the same commit or `make check` goes red on the shipped configs.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-config-roles.bats`:

```bash
@test "a mission type without a description is rejected" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/nodesc.json" <<'JSON'
{ "type": "nodesc", "when_to_use": "never", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *description* ]]
}

@test "a mission type without when_to_use is rejected" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/nowhen.json" <<'JSON'
{ "type": "nowhen", "description": "a thing", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *when_to_use* ]]
}

@test "an empty description is rejected, not just a missing one" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/blank.json" <<'JSON'
{ "type": "blank", "description": "", "when_to_use": "never", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
}

@test "the shipped mission types all declare both fields" {
  # The backfill is part of this change; without it validate goes red on the
  # configs the repo ships.
  for f in "$REPO_ROOT"/config/missions/*.json; do
    [ -n "$(jq -r '.description // ""' "$f")" ] || { echo "no description: $f"; false; }
    [ -n "$(jq -r '.when_to_use // ""' "$f")" ] || { echo "no when_to_use: $f"; false; }
  done
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-config-roles.bats`
Expected: all four FAIL — validation accepts the files, and the shipped configs have neither field.

- [ ] **Step 3: Require both fields in the validator**

In `bin/fleet-config`, inside `fleet_config_validate_type`, before the driver split that reads `.stages` / `.palette`:

```bash
  # With three types you remember what they are. With ten you do not, and
  # neither does the Commander, which picks a type from the user's request and
  # otherwise has only a filename to go on.
  local desc when
  desc="$(jq -r '.description // ""' "$f")"
  when="$(jq -r '.when_to_use // ""' "$f")"
  [ -n "$desc" ] || { printf '%s\tmissing description\n' "$f"; bad=1; }
  [ -n "$when" ] || { printf '%s\tmissing when_to_use\n' "$f"; bad=1; }
```

- [ ] **Step 4: Backfill the five shipped types**

Add both keys after `"type"` in each file. Exact values:

```
campaign  description: "build a feature, spec through ship"
          when_to_use: "a change that needs specifying, planning and implementing"
strike    description: "fix a known bug from an issue reference"
          when_to_use: "the defect is already reported and understood"
recon     description: "investigate and report; ships nothing"
          when_to_use: "you need an answer, not a change"
fortify   description: "refactor, tests, or performance on existing code"
          when_to_use: "the behaviour is right and the code is not"
sortie    description: "commander-driven; stages in any order"
          when_to_use: "the work does not fit a fixed graph"
```

Use `jq` so formatting stays consistent, one file at a time:

```bash
f=config/missions/campaign.json
jq '. + {description:"build a feature, spec through ship", when_to_use:"a change that needs specifying, planning and implementing"}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-config-roles.bats && bin/fleet-config validate`
Expected: PASS, and `ok: configuration validates`.

- [ ] **Step 6: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-config config/missions tests/fleet-config-roles.bats
git commit -m "feat(config): a mission type says what it is for

Types carried a graph and no statement of purpose. That is survivable at
three and not at ten — and the reader who most needs it is the
Commander, which picks a type from the user's request and had only a
filename to go on.

description and when_to_use are required of both drivers and fail
closed, with the five shipped types backfilled in the same change so
validation never goes red."
```

---

### Task 5: `fleet-config type create` can write the fields it now requires

**Files:**
- Modify: `bin/fleet-config` (the `type)` argument parser, around line 203-220)
- Test: `tests/fleet-config-roles.bats`

**Interfaces:**
- Consumes: the validator from Task 4.
- Produces: `fleet-config type {create|set} --description <text> --when-to-use <text>`, written as top-level string fields.

**Context and why this cannot wait for spec 2:** Task 4 made two fields required. `create` is the supported path for writing a new type file. Without these flags, every type created through the supported path fails its own validation the moment it is written — the single validated door would produce invalid config. This is a contradiction, not a backlog item.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fleet-config-roles.bats`:

```bash
@test "type create writes description and when_to_use" {
  run "$REPO_ROOT/bin/fleet-config" type create --name probe \
    --driver machine --entry a \
    --description "a probe type" --when-to-use "testing only" \
    --stage 'a:frontier:spec.txt:b' --stage 'b:frontier:review.txt:'
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$FLEET_CONFIG_OVERRIDE/missions/probe.json")" = "a probe type" ]
  [ "$(jq -r .when_to_use "$FLEET_CONFIG_OVERRIDE/missions/probe.json")" = "testing only" ]
}

@test "a type created through fleet-config passes its own validation" {
  # The property that matters: the supported path must not produce config the
  # validator rejects.
  "$REPO_ROOT/bin/fleet-config" type create --name probe2 \
    --driver machine --entry a \
    --description "a probe type" --when-to-use "testing only" \
    --stage 'a:frontier:spec.txt:' >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "type set can add the fields to an existing type" {
  run "$REPO_ROOT/bin/fleet-config" type set --name campaign \
    --description "changed" --when-to-use "changed too"
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$FLEET_CONFIG_OVERRIDE/missions/campaign.json")" = "changed" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-config-roles.bats -f "type create\|type set"`
Expected: FAIL with `unknown flag: --description`.

- [ ] **Step 3: Parse the two flags**

In `bin/fleet-config`, in the `type)` branch. Add to the variable initialisation line:

```bash
      NAME="" DRIVER="commander" ENTRY="" MAXSP="" MAXSEC="" PAL="[]" STG="[]" DESC="" WHEN=""
```

And two cases to the `while` loop, beside `--name`:

```bash
        --description) DESC=$2; shift 2 ;;
        --when-to-use) WHEN=$2; shift 2 ;;
```

- [ ] **Step 4: Write them into the type file**

Where the branch builds the JSON it writes, add both fields when non-empty. `set` must leave an existing value alone when the flag is not passed:

```bash
      # Empty means "not supplied", so `set` without the flag keeps what is
      # there. Task 4 makes both required, so create without them writes a file
      # that validate will reject — which is the correct, loud failure.
      [ -n "$DESC" ] && obj="$(printf '%s' "$obj" | jq --arg d "$DESC" '.description=$d')"
      [ -n "$WHEN" ] && obj="$(printf '%s' "$obj" | jq --arg w "$WHEN" '.when_to_use=$w')"
```

Match the surrounding style: read how the branch currently assembles and writes its object, and follow it. Do not restructure the branch.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-config-roles.bats`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-config tests/fleet-config-roles.bats
git commit -m "feat(config): type create can write the fields validation requires

Requiring a field that the writer cannot write turns the single
validated door into a door that produces invalid config: every type
created through the supported path would fail its own validation at
birth. --description and --when-to-use close that.

--stage still takes only name:role:prompt:next, so a type with a review
loop is still hand-written JSON. That is the authoring work, and it is
recorded in the spec rather than smuggled in here."
```

---

### Task 6: The `blueprint` pipeline and its prompts

**Files:**
- Create: `config/missions/blueprint.json`
- Create: `prompts/blueprint/interview.txt`, `prompts/blueprint/review.txt`, `prompts/blueprint/refine.txt`
- Create: `tests/fleet-blueprint.bats`
- Modify: `bin/fleet-config` (one `mkdir -p` in `prompt write`)

**Interfaces:**
- Consumes: `interactive` (Task 1-3), `description`/`when_to_use` (Task 4).
- Produces: mission type `blueprint`, runnable as `fleet-mission --type blueprint …`.

**Context:** prompt subdirectories already resolve — `bin/fleet-spawn:79-81` is a plain path join against `$FLEET_HOME/prompts/` then `$FLEET_ROOT/prompts/`. No code change is needed to *read* one. Only `fleet-config prompt write` needs a fix, because it `mkdir -p`s the prompts directory but not a subdirectory inside it.

- [ ] **Step 1: Write the failing tests**

Create `tests/fleet-blueprint.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

bp() { echo "$REPO_ROOT/config/missions/blueprint.json"; }

@test "blueprint declares what it is for" {
  [ -n "$(jq -r '.description // ""' "$(bp)")" ]
  [ -n "$(jq -r '.when_to_use // ""' "$(bp)")" ]
}

@test "the interview stage is interactive and the others are not" {
  [ "$(jq -r '.stages[] | select(.name=="blueprint") | .interactive' "$(bp)")" = true ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .interactive // false' "$(bp)")" = false ]
  [ "$(jq -r '.stages[] | select(.name=="refine") | .interactive // false' "$(bp)")" = false ]
}

@test "refine runs on frontier, not executor" {
  # Deliberate divergence from campaign, where fix is the executor. Revising a
  # spec is judgment work and the executor's brief is code-shaped.
  [ "$(jq -r '.stages[] | select(.name=="refine") | .role' "$(bp)")" = frontier ]
}

@test "the review stage carries the review contract" {
  [ "$(jq -r '.stages[] | select(.name=="review") | .review' "$(bp)")" = true ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .on_pass' "$(bp)")" = ready ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .on_fail' "$(bp)")" = refine ]
}

@test "the mission cap leaves room for review and refine after a maximal interview" {
  # The invariant: interactive stage cap < mission cap <= ceiling. Equal caps
  # would kill a mission for succeeding slowly.
  mission="$(jq -r '.max_mission_seconds' "$(bp)")"
  [ "$mission" -gt 14400 ]
  [ "$mission" -le "$(jq -r '.max_mission_seconds_ceiling' "$REPO_ROOT/config/fleet.json")" ]
}

@test "every stage's prompt file exists" {
  while read -r p; do
    [ -n "$p" ] || continue
    [ -f "$REPO_ROOT/prompts/$p" ] || { echo "missing prompt: $p"; false; }
  done < <(jq -r '.stages[].prompt // empty' "$(bp)")
}

@test "blueprint validates" {
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "every next, on_pass and on_fail names a real stage or a state word" {
  names="$(jq -r '.stages[].name' "$(bp)")"
  while read -r t; do
    [ -n "$t" ] || continue
    case "$t" in ready|done|parked|blocked|failed) continue ;; esac
    printf '%s\n' "$names" | grep -qx "$t" || { echo "dangling target: $t"; false; }
  done < <(jq -r '.stages[] | (.next // empty), (.on_pass // empty), (.on_fail // empty)' "$(bp)")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/fleet-blueprint.bats`
Expected: FAIL — no such file `config/missions/blueprint.json`.

- [ ] **Step 3: Create the type**

`config/missions/blueprint.json`:

```json
{
  "type": "blueprint",
  "description": "interview a human, then write and review a spec",
  "when_to_use": "the work is not written down yet — research, an investigation, or a feature nobody has specified",
  "entry": "blueprint",
  "fix_round_limit": 3,
  "max_mission_seconds": 21600,
  "stages": [
    { "name": "blueprint", "role": "frontier", "prompt": "blueprint/interview.txt", "interactive": true, "next": "review" },
    { "name": "review",    "role": "frontier", "prompt": "blueprint/review.txt",    "review": true, "on_pass": "ready", "on_fail": "refine" },
    { "name": "refine",    "role": "frontier", "prompt": "blueprint/refine.txt",    "next": "review" }
  ]
}
```

- [ ] **Step 4: Write the interview prompt**

`prompts/blueprint/interview.txt`. Note the paragraph resolving the footer contradiction — `fleet-spawn` appends "no one reads this terminal", which is false here:

```
You are running the blueprint stage for mission {mission_id} in {worktree}.
Task: {description}

Someone is sitting at this terminal, reading what you write, right now. This
stage is an interview and they are the point of it. Ask one question at a time
and wait for the answer. Take as long as it takes.

Run mattpocock-skills:grill-with-docs to conduct the interview — it builds the
project's domain model as it goes. Reach for domain-modeling and research when a
question needs grounding in the codebase or in primary sources rather than in
opinion.

When the interview has converged, run mattpocock-skills:to-spec to turn the
conversation into a spec. Write it to
docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md, create the directory if it
does not exist, and commit it on this branch.

Every decision that had an alternative should record what the alternative was
and why it lost. The spec's reader is a cold agent with none of this
conversation, and the reasoning is the part they cannot reconstruct.

The completion footer below says a question belongs in blocked:<question>
because nothing reads this terminal. On this stage that is not true, and the
footer is wrong: ask the human in front of you. Use blocked:<question> only if
they leave and you cannot finish without them.
```

- [ ] **Step 5: Write the review prompt**

`prompts/blueprint/review.txt`. Deliberately not `prompts/review.txt`, which reviews code:

```
You are running the review stage for mission {mission_id} in {worktree}.
Task: {description}

Review the spec this mission produced, under docs/superpowers/specs/. You were
not present for the interview that produced it, and that is the point: the
spec's real reader is a cold agent implementing from it with no more context
than you have.

Judge it on four things, in this order:

1. Placeholders. TBD, TODO, "handle edge cases", "add appropriate validation",
   an empty section. Each is a decision nobody made.
2. Internal contradictions. Does a later section assume something an earlier one
   ruled out? Does the architecture match the feature list?
3. Ambiguity. Could a requirement be read two ways by someone implementing it
   alone at speed? If so it will be, and it belongs in the findings.
4. Scope. Is this one implementable piece of work, or several that should be
   separate specs?

Do not review the underlying idea, and do not restate the design back. You are
testing whether the document survives contact with a stranger.

Write findings.json at the worktree root:
  {"result":"PASS"|"FAIL","findings":[{"severity":"blocking|major|minor","title":"...","detail":"..."}]}

Use the same severity vocabulary the rest of the fleet uses. FAIL on any
blocking or major finding. Write findings.json ONCE, when you have finished
deciding: the pipeline reads it the moment you report completion.
```

- [ ] **Step 6: Write the refine prompt**

`prompts/blueprint/refine.txt`:

```
You are running the refine stage for mission {mission_id} in {worktree}.
Task: {description}

Address every finding in findings.json that the review marked blocking or
major, and each minor you can close without widening the spec.

Widening is the failure mode here. A spec that grows a section in response to
an ambiguity finding has usually answered a different question than the one
asked. Prefer making the existing sentence unambiguous over adding a new
paragraph beside it.

If a finding is wrong, say so in your summary with your reasoning rather than
changing the spec to satisfy it. The reviewer read the document cold and can be
mistaken about intent.

Commit your work on this branch before you finish. Uncommitted changes are
reviewed but never shipped — the ship step merges the branch, not the worktree.
```

- [ ] **Step 7: Fix `prompt write` for subdirectories**

In `bin/fleet-config`, the `prompt` branch currently runs `mkdir -p "$FLEET_HOME/prompts"`. A name like `blueprint/interview.txt` needs its parent created too:

```bash
          mkdir -p "$(dirname "$FLEET_HOME/prompts/$PNAME")"
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bats tests/fleet-blueprint.bats`
Expected: PASS.

- [ ] **Step 9: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 10: Commit**

```bash
git add config/missions/blueprint.json prompts/blueprint bin/fleet-config tests/fleet-blueprint.bats
git commit -m "feat(blueprint): a pipeline that interviews a human for a spec

One interactive stage, then the review ladder that already exists, then
ship. The interview is one stage and not three because the fleet spawns
a fresh agent per stage, and what an interview is worth is the
conversation — which does not survive being handed to a cold agent as a
file.

refine runs on frontier rather than the executor, unlike campaign's fix:
revising a spec is judgment work. Prompts live under prompts/blueprint/,
which needed no code to read — resolution was already a path join — and
one mkdir -p to write."
```

---

### Task 7: Provision the mattpocock skills

**Files:**
- Modify: `config/roles.json.example`
- Test: `tests/fleet-config-roles.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: a documented `provision` list for the `frontier` role that installs the skills the interview prompt names.

**Context:** `config/roles.json` is **git-ignored** — it is machine-local and generated on first session. So the committed record of this change lives in `roles.json.example`, which currently has no `provision` list at all. The live file is updated by hand on each machine, or regenerated. Do not commit `config/roles.json`.

- [ ] **Step 1: Write the failing test**

Append to `tests/fleet-config-roles.bats`:

```bash
@test "the roles example documents how skills reach a frontier agent" {
  # roles.json is git-ignored, so the example file is the only committed record
  # of what a working configuration looks like.
  ex="$REPO_ROOT/config/roles.json.example"
  [ "$(jq -r '.frontier.provision | length' "$ex")" -gt 0 ]
  jq -r '.frontier.provision[]' "$ex" | grep -q 'mattpocock-skills@mattpocock'
  jq -r '.frontier.provision[]' "$ex" | grep -q 'superpowers'
}

@test "the roles example is valid json and names both roles" {
  ex="$REPO_ROOT/config/roles.json.example"
  run jq -e '.frontier.cmd and .executor.cmd' "$ex"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/fleet-config-roles.bats -f roles.example`
Expected: FAIL — `.frontier.provision` is null.

- [ ] **Step 3: Update the example**

`config/roles.json.example`:

```json
{
  "frontier": {
    "harness": "claude",
    "cmd": "claude",
    "bunker": true,
    "provision": [
      "claude plugin marketplace add anthropics/claude-plugins-official",
      "claude plugin install superpowers@claude-plugins-official",
      "claude plugin marketplace add mattpocock/skills",
      "claude plugin install mattpocock-skills@mattpocock"
    ]
  },
  "executor": {
    "harness": "pi",
    "cmd": "pi",
    "bunker": true,
    "provision": []
  }
}
```

- [ ] **Step 4: Apply the same pair to the live config on this machine**

Not committed — `config/roles.json` is git-ignored. Append to the existing `frontier.provision` array, keeping what is already there:

```bash
jq '.frontier.provision += ["claude plugin marketplace add mattpocock/skills", "claude plugin install mattpocock-skills@mattpocock"]' \
  config/roles.json > config/roles.json.tmp && mv config/roles.json.tmp config/roles.json
bin/fleet-config validate
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/fleet-config-roles.bats`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 7: Commit**

```bash
git add config/roles.json.example tests/fleet-config-roles.bats
git commit -m "feat(roles): document how skills reach a frontier agent

The interview stage names skills from mattpocock/skills, and nothing
committed said how they get installed — roles.json is git-ignored and
roles.json.example carried no provision list at all, so the one
configuration that makes the pipeline work existed only on one machine.

Provisioning is role-wide, which puts every mattpocock skill in front of
every frontier stage. Four of them overlap what the fleet already owns:
implement, tdd, code-review, to-tickets. The mitigation is that briefs
name the artifact they want; the risk is recorded in the spec."
```

---

### Task 8: Document the type and the property

**Files:**
- Modify: `README.md` (Mission types table, a new subsection under The watcher, Environment table, Known gaps)
- Modify: `docs/SETUP.md` (§6 Run a mission)

**Interfaces:** none.

- [ ] **Step 1: Add `blueprint` to the mission types table**

In `README.md`, the Mission types table:

```
| `blueprint` | interview a human, then write and review a spec | blueprint → review ⇄ refine → ready → ship |
```

Add a sentence below the table: types now carry `description` and `when_to_use`, and `fleet-config type show <name>` prints them.

- [ ] **Step 2: Document the interactive property**

In `README.md`, a new `### An interactive stage is expected to be waiting` subsection under `## The watcher`, after the draft-guard subsection. Cover: what declaring it does; the behaviour table from the spec; that the budget stays hard on a larger clamped cap; and that it is a general stage property, not a blueprint feature.

State the relationship to the draft guard explicitly — the guard only fires once characters are on the input line, so it cannot help while a human is reading a question, and an interactive stage is the declared form of the same protection.

- [ ] **Step 3: Add the environment variable**

In `README.md`'s Environment table, in cap order:

```
| `FLEET_INTERACTIVE_BUDGET_SECONDS` | `14400` | wall clock for an interactive stage; clamped by `max_mission_seconds_ceiling` |
```

- [ ] **Step 4: Update Known gaps**

Remove nothing. Add the two the spec discovered:

- Night mode's admission gate is a hardcoded `case` on type, so any new type is rejected as unknown — correct for `blueprint`, by accident rather than by rule.
- `fleet-config type create --stage` takes only `name:role:prompt:next`, so a type with a review loop or an interactive stage is still hand-written JSON.

- [ ] **Step 5: Add a blueprint walkthrough to SETUP**

In `docs/SETUP.md` §6, after the campaign example:

```bash
# Produce a spec by interview, then feed it to a campaign
bin/fleet-mission --type blueprint --project acme --repo id:myrepo \
  --desc "rate limiting for the public API"
bin/fleet-spawn --mission m002 --stage blueprint
# …the interview runs in that pane. Answer it. Nothing will type over you.
bin/fleet-mission --type campaign --project acme --repo id:myrepo \
  --desc "rate limiting for the public API" \
  --spec /path/to/docs/superpowers/specs/2026-07-26-rate-limiting-design.md
```

Note that the campaign skips its own `spec` stage because `--spec` was supplied, and that blueprint is never admitted to the night queue.

- [ ] **Step 6: Verify the docs match the code**

Run:
```bash
grep -c 'blueprint' README.md docs/SETUP.md
jq -r '.description' config/missions/blueprint.json
grep -n 'FLEET_INTERACTIVE_BUDGET_SECONDS' README.md bin/fleet-pipeline
```
Expected: `blueprint` present in both docs; the description matches the table entry verbatim; the variable named in both the README and the implementation with the same default.

- [ ] **Step 7: Run the whole suite**

Run: `make check`
Expected: rc 0.

- [ ] **Step 8: Commit**

```bash
git add README.md docs/SETUP.md
git commit -m "docs: the blueprint type and the interactive stage property

Documents what declaring a stage interactive actually changes, and why
it exists alongside the draft guard rather than replacing it: the guard
only fires once characters are on the input line, so it cannot help
while a human is reading a question.

Known gaps gains the two the spec turned up — night mode rejects any new
type by accident of a hardcoded case, and type create still cannot
express a review loop."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: the pipeline → Task 6; the interactive property → Tasks 1-3; type descriptions → Tasks 4-5; skills provisioning → Task 7; prompts → Task 6; testing → distributed through each task's own cycle; requirements for spec 2 → recorded in the spec and surfaced in Task 8's Known gaps. Nothing in the spec lacks a task.

**Placeholders.** None. Every code step carries the actual text to write. The one step that says "match the surrounding style" (Task 5, Step 4) names the exact file, branch and lines to read first, because the assembly there varies with `create` versus `set` and copying a wrong skeleton would be worse than reading it.

**Type consistency.** `fleet_pipeline_interactive_budget` takes `<type>` and returns seconds in both its definition (Task 3, Step 3) and its two call sites (Task 3, Steps 1 and 4). The `interactive` local is introduced in Task 1 Step 7 and consumed with the same `[ "$interactive" != true ]` string comparison in Tasks 1, 2 and 3 — string, not boolean, because `fleet_pipeline_field` stringifies. Stage names `blueprint` / `review` / `refine` are identical across `blueprint.json`, the prompt paths and `tests/fleet-blueprint.bats`.

**One ordering constraint the executor must respect:** Task 4 makes two fields required, which fails validation for any type lacking them. Task 6 creates `blueprint.json` **with** both fields, so it is safe after Task 4 — but if Task 6 is done first, `make check` goes red between the two. Run them in order.
