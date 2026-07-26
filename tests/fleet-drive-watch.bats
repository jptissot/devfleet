setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  # The example roles now bunker the executor role by default, so a real spawn
  # of an executor stage needs a registered repo path or fleet-spawn blocks on
  # "no-repo-path" before it ever reaches the assertion a test is about.
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode local-merge >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id k1 >/dev/null
  fleet_git_init "$(jq -r .worktree_path "$(mj k1)")"
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
events() { cat "$FLEET_STATE_OVERRIDE/missions/$1/events" 2>/dev/null; }
spawns() { grep -cF $'orca\x1fterminal\x1fcreate' "$FLEET_ORCA_LOG"; }

@test "a marker becomes an event and hands back to the Commander" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage plan >/dev/null
  "$REPO_ROOT/bin/fleet-done" k1 done
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
  [ "$(jq -r .terminal "$(mj k1)")" = "null" ]
  [ "$(events k1 | jq -r 'select(.kind=="marker") | .detail')" = "done" ]
  [ "$(spawns)" = "$before" ]
}

@test "an anomaly emits an event and never respawns" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  before="$(spawns)"
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(spawns)" = "$before" ]
  [ "$(jq -r .stage "$(mj k1)")" = "execute" ]
  [ "$(jq -r .restarts "$(mj k1)")" = "0" ]
  [ "$(events k1 | jq -r 'select(.kind=="anomaly") | .detail')" = "terminal-gone" ]
}

@test "the same anomaly is not re-emitted every tick" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(events k1 | jq -r 'select(.kind=="anomaly")' | jq -s 'length')" = "1" ]
}

@test "an idle drive mission is never an anomaly" {
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
  [ -z "$(events k1)" ]
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
}

@test "the wall-clock cap parks the mission and stops the terminal" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  jq '.mission_started_at=0' "$(mj k1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj k1)"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .stage "$(mj k1)")" = "parked" ]
  [ "$(events k1 | jq -r 'select(.kind=="cap") | .detail')" = "max_mission_seconds" ]
  orca_log_has "terminal"
}

@test "an unrecognized marker is reported, not parked" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage plan >/dev/null
  # fleet-done's format: "<epoch>\t<status>" appended to <worktree>/.devfleet/<id>.status
  printf '%s\t%s\n' "$(date +%s)" weird >> "$(jq -r .worktree_path "$(mj k1)")/.devfleet/k1.status"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .stage "$(mj k1)")" = "driving" ]
  [[ "$(events k1 | jq -r 'select(.kind=="marker") | .detail')" == unrecognized:* ]]
}

@test "fleet-advance refuses a drive mission" {
  run "$REPO_ROOT/bin/fleet-advance" k1
  [ "$status" -ne 0 ]
  [[ "$output" == *"commander-driven"* ]]
}

@test "after a dead-terminal anomaly the Commander can stop and spawn again" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage execute >/dev/null
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(events k1 | jq -r 'select(.kind=="anomaly") | .detail')" = "terminal-gone" ]
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-drive" stop --mission k1
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission k1 --stage fix
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj k1)")" = "fix" ]
  [ "$(jq -r .spawn_count "$(mj k1)")" = "2" ]
}