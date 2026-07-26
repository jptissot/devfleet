setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "add cache" --id b1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "json brief carries state, palette and caps" {
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .mission)" = "b1" ]
  [ "$(echo "$output" | jq -r .stage)" = "driving" ]
  [ "$(echo "$output" | jq -r .description)" = "add cache" ]
  [ "$(echo "$output" | jq -r '.palette | length')" = "7" ]
  [ "$(echo "$output" | jq -r .spawns_left)" = "12" ]
  [ "$(echo "$output" | jq -r '.unread | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.open_decisions | length')" = "0" ]
  [ "$(echo "$output" | jq -r .seconds_left)" -gt 0 ]
}

@test "unread events appear in the brief and ack clears them" {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; fleet_events_append b1 marker done'
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$(echo "$output" | jq -r '.unread | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.unread[0].detail')" = "done" ]
  "$REPO_ROOT/bin/fleet-drive" ack --mission b1
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1 --json
  [ "$(echo "$output" | jq -r '.unread | length')" = "0" ]
}

@test "text brief is human readable" {
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b1
  [ "$status" -eq 0 ]
  [[ "$output" == *"b1"* ]]
  [[ "$output" == *"driving"* ]]
  [[ "$output" == *"palette:"* ]]
}

@test "brief refuses a machine-driven mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id b2 >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" brief --mission b2
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
}