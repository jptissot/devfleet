setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  # The example roles now bunker the executor role by default, so any real
  # (non-dry-run) spawn of an executor stage needs a registered repo path or
  # fleet-spawn blocks on "no-repo-path" before mk()'s missions ever reach the
  # stage a test is actually about.
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode local-merge >/dev/null
}
teardown() { fleet_teardown_home; }

mk() {  # <type> <id> [extra flags...]
  "$REPO_ROOT/bin/fleet-mission" --type "$1" --project a --repo id:r --desc x --id "$2" "${@:3}" >/dev/null
}
stage_of() { jq -r .stage "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
wt_of() { jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

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

@test "advance is idempotent: second call with no new marker is a no-op" {
  mk campaign m010
  "$REPO_ROOT/bin/fleet-done" m010 done
  run "$REPO_ROOT/bin/fleet-advance" m010
  [ "$(stage_of m010)" = "plan" ]
  run "$REPO_ROOT/bin/fleet-advance" m010     # no new marker
  [ "$status" -eq 0 ]
  [ "$(stage_of m010)" = "plan" ]             # MUST NOT jump to execute
}

@test "entering a stage resets restarts and sets timers" {
  mk campaign m011
  jq '.restarts=2' "$FLEET_STATE_OVERRIDE/missions/m011/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  "$REPO_ROOT/bin/fleet-done" m011 done
  "$REPO_ROOT/bin/fleet-advance" m011 >/dev/null
  mj="$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  [ "$(jq -r .restarts "$mj")" = "0" ]
  [ "$(jq -r .stage_started_at "$mj")" != "null" ]
  [ "$(jq -r .marker_cursor "$mj")" = "1" ]
}

@test "last_stage preserves where the mission stopped (Finding 5)" {
  mk campaign m012
  "$REPO_ROOT/bin/fleet-done" m012 done
  "$REPO_ROOT/bin/fleet-advance" m012 >/dev/null        # spec done -> plan
  [ "$(jq -r .last_stage "$FLEET_STATE_OVERRIDE/missions/m012/mission.json")" = "spec" ]
  # jump to review, PASS -> ready; last_stage must remember "review"
  jq '.stage="review"' "$FLEET_STATE_OVERRIDE/missions/m012/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m012/mission.json"
  echo '{"result":"PASS","findings":[]}' > "$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m012/mission.json")/findings.json"
  "$REPO_ROOT/bin/fleet-done" m012 done
  "$REPO_ROOT/bin/fleet-advance" m012 >/dev/null
  mj="$FLEET_STATE_OVERRIDE/missions/m012/mission.json"
  [ "$(jq -r .stage "$mj")" = "ready" ]
  [ "$(jq -r .last_stage "$mj")" = "review" ]
}

@test "fleet_json_set_str is injection-proof for values with quotes (Finding 3)" {
  f="$FLEET_TMP/j.json"; echo '{}' > "$f"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_json_set_str "'"$f"'" ".x" "a\"b\\c"; jq -r .x "'"$f"'"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'a"b\c' ]]
}

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


@test "advancing stops the finished stage's agent before spawning the next" {
  # Nothing else ever stops it. Left running, the previous stage's agent keeps
  # editing the worktree the next stage is reviewing — for the life of the
  # mission.
  mk campaign a9
  jq '.terminal="term_prev"' "$(mj a9)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj a9)"
  "$REPO_ROOT/bin/fleet-done" a9 done
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-advance" a9
  [ "$status" -eq 0 ]
  orca_log_has $'terminal\x1fclose\x1f--terminal\x1fterm_prev'
  orca_log_has $'terminal\x1fcreate'
}

@test "an outgoing agent that will not stop parks the mission instead of advancing" {
  mk campaign a10
  jq '.terminal="term_prev"' "$(mj a10)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj a10)"
  "$REPO_ROOT/bin/fleet-done" a10 done
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_CLOSE_FAIL=1 run "$REPO_ROOT/bin/fleet-advance" a10
  [ "$(jq -r .stage "$(mj a10)")" = "parked" ]
  refute_orca $'terminal\x1fcreate'
}

@test "a marker is consumed even when the spawn that follows is refused" {
  # The cursor was written after the spawn, and a refused spawn exits early under
  # set -e — so the same marker fired again on the next tick and advanced a
  # mission that had not moved. m001 lost a freshly spawned fix agent to this:
  # the replayed marker declared fix "done" two seconds after it started.
  mk campaign a11
  jq '.terminal="term_prev"' "$(mj a11)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj a11)"
  "$REPO_ROOT/bin/fleet-done" a11 done
  FLEET_FAKE_CLOSE_FAIL=1 FLEET_STOP_TRIES=1 run "$REPO_ROOT/bin/fleet-advance" a11
  [ "$(jq -r .stage "$(mj a11)")" = "parked" ]
  [ "$(jq -r .marker_cursor "$(mj a11)")" = "1" ]   # consumed, not replayable
}

@test "a stage that ends without a successor still stops its agent" {
  # ready/done/parked/blocked/failed spawn nothing, so the stop that lives in
  # spawn() never runs and the finished agent sits in its pane looking like it is
  # still working. m001's passing review stayed on screen for exactly this reason.
  mk recon a12                       # recon's report stage is terminal -> done
  jq '.stage="report" | .terminal="term_prev"' "$(mj a12)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj a12)"
  "$REPO_ROOT/bin/fleet-done" a12 done
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-advance" a12
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj a12)")" = "done" ]
  orca_log_has $'terminal\x1fclose\x1f--terminal\x1fterm_prev'
  [ "$(jq -r .terminal "$(mj a12)")" = "null" ]   # and the handle is cleared
}

@test "a review verdict is read after its agent is stopped, not before" {
  # findings.json and the marker are two separate writes. A reviewer that keeps
  # working after its marker can revise the verdict the pipeline already acted
  # on — m001 shipped-approved a PASS that became FAIL three minutes later.
  mk campaign a13
  wt="$(wt_of a13)"
  jq '.stage="review" | .terminal="term_rev"' "$(mj a13)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj a13)"
  printf '{"result":"PASS","findings":[]}' > "$wt/findings.json"
  "$REPO_ROOT/bin/fleet-done" a13 done
  FLEET_FAKE_CLOSE_WRITES_FILE="$wt/findings.json" \
    FLEET_FAKE_CLOSE_WRITES='{"result":"FAIL","findings":[]}' \
    run "$REPO_ROOT/bin/fleet-advance" a13
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj a13)")" = "fix" ]      # the revised verdict won
}

