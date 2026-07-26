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