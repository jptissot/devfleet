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
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-backend"; . "$REPO_ROOT/bin/fleet-pipeline"; . "$REPO_ROOT/bin/fleet-watch-lib"; . "$REPO_ROOT/bin/fleet-detect"; fleet_roots; fleet_detect_anomaly '"$*"
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
  FLEET_FAKE_SAT=false run detect d1 100 900 2700    # first call records the hash
  FLEET_FAKE_SAT=false run detect d1 100000 900 2700 # unchanged, way past the window
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

@test "a working terminal is progress even when the tree is untouched" {
  # Research, reading, long reasoning: the agent is plainly alive and writes
  # nothing for stretches. Judging it by the worktree alone parks exactly the
  # stages that think hardest — three false parks on m001 before this existed.
  setj d1 '.terminal="term_x" | .last_progress_at=0'
  FLEET_FAKE_TERM_TAIL="reading tea source" run detect d1 100 900 2700
  FLEET_FAKE_TERM_TAIL="found it, drafting the plan" run detect d1 100000 900 2700
  [ -z "$output" ]
  [ "$(jq -r .last_progress_at "$(mj d1)")" = "100000" ]
}

@test "a frozen terminal and a frozen tree still stall" {
  setj d1 '.terminal="term_x" | .last_progress_at=0'
  # busy (not idle at a prompt), yet nothing moves on screen or on disk
  FLEET_FAKE_SAT=false FLEET_FAKE_TERM_TAIL="waiting" run detect d1 100 900 2700
  FLEET_FAKE_SAT=false FLEET_FAKE_TERM_TAIL="waiting" run detect d1 100000 900 2700
  [ "$output" = "stalled" ]
}

@test "over-budget reported once the tree is quiet" {
  setj d1 '.terminal="term_x" | .stage_started_at=0'
  run detect d1 100 900 2700
  run detect d1 100 900 1             # budget of 1s, elapsed 100s
  [ "$output" = "over-budget" ]
}
@test "cycle detection ignores the screen and watches the worktree alone" {
  # A,B,A in the working tree is an edit-revert loop. Composing the screen into
  # that hash would hide it: the screen never returns to a previous state, so no
  # third sample would ever equal the first.
  setj d1 '.terminal="term_x"'
  wt="$(jq -r .worktree_path "$(mj d1)")"
  i=0
  for v in A B A B A; do
    i=$(( i + 1 )); echo "$v" > "$wt/seed.txt"
    FLEET_FAKE_TERM_TAIL="screen$i" run detect d1 "$(( 100 + i ))" 900 2700
  done
  [ "$output" = "cycle" ]
}

@test "an agent idle at its prompt with no marker reports idle" {
  # The turn ended without finishing the mission: no tool calls, no marker, and
  # the agent is back at its prompt waiting for input that will never come.
  setj d1 '.terminal="term_x" | .last_progress_at=0'
  FLEET_FAKE_TERM_TAIL=same run detect d1 100 900 2700
  FLEET_FAKE_TERM_TAIL=same FLEET_FAKE_SAT=true run detect d1 400 900 2700
  [ "$output" = "idle" ]
}

@test "a busy agent is never idle, however long the tree is quiet" {
  setj d1 '.terminal="term_x" | .last_progress_at=0'
  FLEET_FAKE_TERM_TAIL=same run detect d1 100 900 2700
  FLEET_FAKE_TERM_TAIL=same FLEET_FAKE_SAT=false run detect d1 400 900 2700
  [ -z "$output" ]
}

@test "a screen that keeps returning to the same state reports loop" {
  setj d1 '.terminal="term_x"'
  wt="$(jq -r .worktree_path "$(mj d1)")"
  # the tree keeps changing, so this is never a stall; the screen repeats
  for i in 1 2 3 4 5 6 7; do
    echo "$i" > "$wt/seed.txt"
    FLEET_FAKE_TERM_TAIL="$(( i % 3 ))" run detect d1 "$(( 100 + i ))" 900 2700
  done
  [ "$output" = "loop" ]
}

@test "a reported done state is idle without waiting out the nudge window" {
  # The agent said so itself. No need to watch a screen for two minutes to guess.
  cat > "$FLEET_TMP/hooks.json" <<'JSON'
{"version":1,"entries":{"tab_1:leaf_1":{"payload":{"state":"done"},"stateStartedAt":1}}}
JSON
  setj d1 '.terminal="term_001"'
  ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json" FLEET_FAKE_TERM_TAIL=x run detect d1 100 900 2700
  ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json" FLEET_FAKE_TERM_TAIL=x run detect d1 110 900 2700
  [ "$output" = "idle" ]
}

@test "a reported working state is never idle, whatever the screen says" {
  cat > "$FLEET_TMP/hooks.json" <<'JSON'
{"version":1,"entries":{"tab_1:leaf_1":{"payload":{"state":"working"},"stateStartedAt":1}}}
JSON
  setj d1 '.terminal="term_001" | .last_progress_at=0'
  ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json" FLEET_FAKE_SAT=true FLEET_FAKE_TERM_TAIL=x run detect d1 100 900 2700
  ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json" FLEET_FAKE_SAT=true FLEET_FAKE_TERM_TAIL=x run detect d1 400 900 2700
  [ -z "$output" ]
}

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
  #
  # Two calls, not one: the first always records the fresh mission's initial
  # state as progress (state_hash starts unset), whatever agent_state says, and
  # only the second tick — state_hash unchanged since the first — reaches the
  # idle check this test means to exercise.
  mk_interactive_type
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_AGENT_STATE=done run detect d1 1 1 999999999   # record the baseline
  FLEET_FAKE_AGENT_STATE=done run detect d1 999999999 1 999999999
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a non-interactive stage with the same state is still idle" {
  # The control. Without this, the test above passes for the wrong reason.
  setj d1 '.terminal="term_001"'
  FLEET_FAKE_AGENT_STATE=done run detect d1 1 1 999999999   # record the baseline
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

@test "an interactive stage goes over budget on its own larger cap" {
  # The caller passes the normal stage budget. An interactive stage ignores it
  # and uses the interactive one, so a five-second budget must not fire.
  #
  # Two calls, not one: state_hash starts unset on a fresh mission, so the
  # first call always takes the "record progress" branch and returns before
  # reaching the over-budget check (bin/fleet-detect:86). Only the second
  # tick, with state_hash unchanged, reaches the check this test exercises.
  mk_interactive_type
  setj d1 '.terminal="term_001" | .stage_started_at=0'
  FLEET_INTERACTIVE_BUDGET_SECONDS=999999 run detect d1 20000 999999999 5   # record the baseline
  FLEET_INTERACTIVE_BUDGET_SECONDS=999999 run detect d1 20000 999999999 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an interactive stage does eventually go over budget" {
  # An abandoned interview must not pin a worktree and a container open forever.
  mk_interactive_type
  setj d1 '.terminal="term_001" | .stage_started_at=0'
  FLEET_INTERACTIVE_BUDGET_SECONDS=10 run detect d1 100000 999999999 999999999   # record the baseline
  FLEET_INTERACTIVE_BUDGET_SECONDS=10 run detect d1 100000 999999999 999999999
  [ "$status" -eq 0 ]
  [ "$output" = over-budget ]
}
