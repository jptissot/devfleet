setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
stage_of() { jq -r .stage "$(mj "$1")"; }
mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }
gitify() { fleet_git_init "$(jq -r .worktree_path "$(mj "$1")")"; }

@test "tick advances a mission with a fresh marker" {
  mk w1; gitify w1
  "$REPO_ROOT/bin/fleet-done" w1 done
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ "$(stage_of w1)" = "plan" ]
}

@test "tick writes the beacon" {
  mk w2; gitify w2
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
  [ -n "$(cat "$FLEET_STATE_OVERRIDE/.watch-beacon")" ]
}

@test "dead terminal with no marker restarts the stage once, then parks" {
  mk w3; gitify w3
  jq '.terminal="term_dead"' "$(mj w3)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj w3)"
  # first anomaly: terminal gone -> restart (restarts 0 -> 1), stage stays spec
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of w3)" = "spec" ]
  [ "$(jq -r .restarts "$(mj w3)")" = "1" ]
  # second anomaly: now parks
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of w3)" = "parked" ]
}

@test "stuck-on-trust-prompt is an anomaly -> restart" {
  mk w4; gitify w4
  jq '.terminal="term_trust"' "$(mj w4)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj w4)"
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"codex-trust-workspace"' run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w4)")" = "1" ]
}

@test "over-budget stage restarts" {
  mk w5; gitify w5
  wt="$(jq -r .worktree_path "$(mj w5)")"
  # state_hash is "<worktree>:<terminal screen>". The worktree half hashes empty
  # input (clean checkout); the screen half hashes jq's "" plus its newline.
  wt_h="$(sha256sum < /dev/null | cut -d' ' -f1)"
  scr_h="$(printf '\n' | sha256sum | cut -d' ' -f1)"
  jq --arg h "$wt_h:$scr_h" '.terminal="term_budget" | .stage_started_at=0 | .state_hash=$h' "$(mj w5)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj w5)"
  FLEET_BUDGET_SECONDS=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w5)")" = "1" ]
}

@test "progress (hash changed) is recorded, no restart" {
  mk w6; gitify w6
  "$REPO_ROOT/bin/fleet-watch" --tick   # records initial hash, restarts stays 0-ish
  wt="$(jq -r .worktree_path "$(mj w6)")"; echo work >> "$wt/seed.txt"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj w6)")" = "0" ]
  [ "$(jq -r .stage "$(mj w6)")" = "spec" ]
}

@test "daemon --ticks runs a bounded number of passes and drives the pipeline" {
  mk d1; gitify d1
  "$REPO_ROOT/bin/fleet-done" d1 done
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  [ "$(stage_of d1)" = "plan" ]
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
}
@test "cycle (A,B,A) across ticks triggers a restart" {
  mk c1; wt="$(jq -r .worktree_path "$(mj c1)")"; fleet_git_init "$wt"
  # three distinct working-tree states A,B,A (uncommitted edits to a tracked file)
  for v in A B A B A; do
    echo "$v" > "$wt/seed.txt"; "$REPO_ROOT/bin/fleet-watch" --tick
  done
  [ "$(jq -r .restarts "$(mj c1)")" = "1" ]
}

@test "watcher park records last_stage as the stopped stage" {
  mk pk1; fleet_git_init "$(jq -r .worktree_path "$(mj pk1)")"
  "$REPO_ROOT/bin/fleet-done" pk1 done; "$REPO_ROOT/bin/fleet-advance" pk1 >/dev/null  # -> plan
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # restart
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # park
  [ "$(jq -r .stage "$(mj pk1)")" = "parked" ]
  [ "$(jq -r .last_stage "$(mj pk1)")" = "plan" ]
}

@test "restart stops the old terminal before respawning" {
  mk r1; fleet_git_init "$(jq -r .worktree_path "$(mj r1)")"
  "$REPO_ROOT/bin/fleet-done" r1 done; "$REPO_ROOT/bin/fleet-advance" r1 >/dev/null  # -> plan, terminal recorded
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick   # anomaly -> restart
  grep -q $'terminal\x1fclose' "$FLEET_ORCA_LOG"
}

@test "a restart that cannot stop the old agent parks instead of double-spawning" {
  # Two agents in one worktree edit each other's work. If the old one will not
  # die, the mission is a question for the Commander, not a race.
  mk r5; fleet_git_init "$(jq -r .worktree_path "$(mj r5)")"
  "$REPO_ROOT/bin/fleet-done" r5 done; "$REPO_ROOT/bin/fleet-advance" r5 >/dev/null
  before="$(jq -r .terminal "$(mj r5)")"
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_CLOSE_FAIL=1 FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"permission"' \
    "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .stage "$(mj r5)")" = "parked" ]
  [ "$(jq -r .terminal "$(mj r5)")" = "$before" ]      # the live agent is left alone
  ! orca_log_has $'terminal\x1fcreate'                 # and nothing was spawned beside it
  grep -q 'watch-restart-blocked' "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a night-mode tick pumps the queue" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id w1 >/dev/null
  fleet_git_init "$(jq -r .worktree_path "$(mj w1)")"
  "$REPO_ROOT/bin/fleet-night" queue --mission w1
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .terminal "$(mj w1)")" != "null" ]   # tick kicked it off
}

@test "a non-git worktree does not kill the tick" {
  mk n1                                  # campaign mission; worktree NOT git-inited
  "$REPO_ROOT/bin/fleet-watch" --tick    # must not abort
  [ "$(stage_of n1)" != "" ]             # tick completed, mission still readable
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]   # beacon written => tick reached its end
}

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

@test "an idle agent is nudged, not restarted" {
  # Restarting replays the opening turn that already ended in prose. A nudge
  # costs one line and keeps the context the agent has built.
  mk n5; gitify n5
  "$REPO_ROOT/bin/fleet-done" n5 done; "$REPO_ROOT/bin/fleet-advance" n5 >/dev/null
  FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick     # records the baseline
  jq '.last_progress_at=0' "$(mj n5)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n5)"
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  orca_log_has $'terminal\x1fsend'
  [ "$(jq -r .stage "$(mj n5)")" = "plan" ]        # still in flight
  [ "$(jq -r .restarts "$(mj n5)")" = "0" ]        # restart budget untouched
  [ "$(jq -r .nudges "$(mj n5)")" = "1" ]
  refute_orca $'terminal\x1fcreate'
}

@test "an agent that ignores its nudges escalates to the restart ladder" {
  mk n6; gitify n6
  "$REPO_ROOT/bin/fleet-done" n6 done; "$REPO_ROOT/bin/fleet-advance" n6 >/dev/null
  FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick     # records the baseline
  jq '.last_progress_at=0 | .nudges=2' "$(mj n6)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n6)"
  FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$(mj n6)")" = "1" ]        # became a restart
}

@test "progress does not buy a nudged stage more nudges" {
  # This asserted the opposite until m002. Retiring the tally on progress cannot
  # work when the nudge itself provokes the progress: the agent answers with a
  # burst of output, the next tick reads it as healthy movement, and the limit is
  # never reached. A stage that works, stops, works and stops again is precisely
  # what the ladder is for, so within a stage the tally only rises.
  mk n7; gitify n7
  "$REPO_ROOT/bin/fleet-done" n7 done; "$REPO_ROOT/bin/fleet-advance" n7 >/dev/null
  jq '.nudges=1' "$(mj n7)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n7)"
  wt="$(jq -r .worktree_path "$(mj n7)")"; echo work >> "$wt/seed.txt"
  "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .nudges "$(mj n7)")" = "1" ]
}

@test "a nudge does not retire itself by landing on the screen" {
  # m002: the nudge is typed into the pane, so the tick after one always sees a
  # changed screen. Counting that as progress reset the tally to zero and the
  # nudge limit was never reachable — two nudges both journalled "nudge 1" and
  # the agent was told to continue forever instead of escalating.
  mk n8; gitify n8
  "$REPO_ROOT/bin/fleet-done" n8 done; "$REPO_ROOT/bin/fleet-advance" n8 >/dev/null
  FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick     # records the baseline
  # Six chances to stall. The stage does no work in the worktree throughout.
  for _ in 1 2 3 4 5 6; do
    jq '.last_progress_at=0' "$(mj n8)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n8)"
    FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  done
  grep -q 'watch-nudge.*nudge 2' "$FLEET_STATE_OVERRIDE/journal.log"   # the tally accumulates
  [ "$(jq -r .restarts "$(mj n8)")" = "1" ]                            # and the ladder is reached
}

@test "a new stage starts with a full nudge allowance" {
  # The tally must not be one-way for the whole mission, or a stage nudged early
  # would leave every later stage starting part-way up the ladder. Spawning is
  # the reset boundary, which covers both a fresh stage and a restart.
  mk n8b; gitify n8b
  jq '.nudges=2' "$(mj n8b)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n8b)"
  "$REPO_ROOT/bin/fleet-done" n8b done
  "$REPO_ROOT/bin/fleet-advance" n8b >/dev/null      # spec -> plan, respawns
  [ "$(jq -r .nudges "$(mj n8b)")" = "0" ]
}

@test "a pane with an operator's draft on the input line is left alone" {
  # m002: the operator was mid-sentence answering the agent's question when the
  # nudge was typed into the same line and submitted with it. A pane a human is
  # composing in is not an idle pane, whatever the agent's hooks report.
  mk n9; gitify n9
  "$REPO_ROOT/bin/fleet-done" n9 done; "$REPO_ROOT/bin/fleet-advance" n9 >/dev/null
  draft='❯ I am not sure I completely follow'
  FLEET_FAKE_TERM_TAIL="$draft" FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  jq '.last_progress_at=0' "$(mj n9)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n9)"
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_TERM_TAIL="$draft" FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  refute_orca $'terminal\x1fsend'                    # nothing typed over the operator
  [ "$(jq -r .nudges "$(mj n9)")" = "0" ]
  [ "$(jq -r .restarts "$(mj n9)")" = "0" ]          # and no restart behind their back
  [ "$(stage_of n9)" = "plan" ]
}

@test "an empty prompt line is still an idle pane" {
  # The draft guard has to be specific: an agent sitting at a bare prompt with
  # nobody typing is the case the nudge exists for.
  mk n10; gitify n10
  "$REPO_ROOT/bin/fleet-done" n10 done; "$REPO_ROOT/bin/fleet-advance" n10 >/dev/null
  FLEET_FAKE_TERM_TAIL='❯ ' FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  jq '.last_progress_at=0' "$(mj n10)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n10)"
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_TERM_TAIL='❯ ' FLEET_FAKE_SAT=true "$REPO_ROOT/bin/fleet-watch" --tick
  orca_log_has $'terminal\x1fsend'
  [ "$(jq -r .nudges "$(mj n10)")" = "1" ]
}

@test "a looping agent is stopped and told to continue before anything heavier" {
  mk lp1; gitify lp1
  "$REPO_ROOT/bin/fleet-done" lp1 done; "$REPO_ROOT/bin/fleet-advance" lp1 >/dev/null
  wt="$(jq -r .worktree_path "$(mj lp1)")"
  : > "$FLEET_ORCA_LOG"
  for i in 1 2 3 4 5 6 7; do
    echo "$i" > "$wt/seed.txt"
    FLEET_FAKE_TERM_TAIL="$(( i % 3 ))" "$REPO_ROOT/bin/fleet-watch" --tick
  done
  grep -q 'watch-nudge' "$FLEET_STATE_OVERRIDE/journal.log"
  orca_log_has $'terminal\x1fsend'
  [ "$(jq -r .restarts "$(mj lp1)")" = "0" ]      # not yet a restart
  [ "$(jq -r .stage "$(mj lp1)")" = "plan" ]      # and still in flight
}

@test "a loop that survives its nudges is restarted" {
  # The full ladder the operator described: stop-and-continue twice, and if it
  # is still going in circles, stop it completely and start over.
  mk lp2; gitify lp2
  "$REPO_ROOT/bin/fleet-done" lp2 done; "$REPO_ROOT/bin/fleet-advance" lp2 >/dev/null
  wt="$(jq -r .worktree_path "$(mj lp2)")"
  nudges_seen=0
  for i in $(seq 1 14); do
    echo "$i" > "$wt/seed.txt"
    FLEET_FAKE_TERM_TAIL="$(( i % 3 ))" "$REPO_ROOT/bin/fleet-watch" --tick
    n="$(jq -r '.nudges // 0' "$(mj lp2)")"
    [ "$n" -gt "$nudges_seen" ] && nudges_seen="$n"
  done
  [ "$nudges_seen" -eq 2 ]                        # nudged twice
  [ "$(jq -r .restarts "$(mj lp2)")" = "1" ]      # then restarted
}

@test "a bunkered agent that survives its pane is killed inside the container" {
  # Closing an orca pane detaches a pty; it does not reach a process the sandbox
  # owns. Without this the restart ladder parks every bunkered mission it tries
  # to restart, because the stop can never be confirmed.
  fleet_install_fake_bunker
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id k1 >/dev/null
  gitify k1
  wt="$(jq -r .worktree_path "$(mj k1)")"
  jq '.terminal="term_stuck"' "$(mj k1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj k1)"
  FLEET_FAKE_CLOSE_FAIL=1 FLEET_STOP_TRIES=1 \
    FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"permission"' \
    "$REPO_ROOT/bin/fleet-watch" --tick
  bunker_log_has $'airlock\x1f-C\x1f'"$FLEET_TMP/repo"
  grep -q 'bunker-killed' "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a tick relays whatever the agent spooled for orca" {
  mk hr1; gitify hr1
  wt="$(jq -r .worktree_path "$(mj hr1)")"
  jq '.terminal="term_001"' "$(mj hr1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj hr1)"
  fleet_install_fake_curl
  export ORCA_AGENT_HOOK_ENDPOINT="$FLEET_TMP/endpoint.env"
  printf 'ORCA_AGENT_HOOK_PORT=41999\nORCA_AGENT_HOOK_TOKEN=tok\n' > "$ORCA_AGENT_HOOK_ENDPOINT"
  mkdir -p "$wt/.devfleet"; printf '%s\n' '{"hook_event_name":"PostToolUse"}' > "$wt/.devfleet/orca-hooks.jsonl"
  "$REPO_ROOT/bin/fleet-watch" --tick
  curl_log_has 'hook/claude'
}
