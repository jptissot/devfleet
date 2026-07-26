setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "empty fleet prints nothing, exits 0" {
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lists one line per mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m001 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc y --id m002 >/dev/null
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "m001"*"campaign"*"spec"* ]]
  [[ "${lines[1]}" == "m002"*"recon"*"recon"* ]]
}

@test "--json emits missions and decisions" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m001 >/dev/null
  run "$REPO_ROOT/bin/fleet-status" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.missions[0].id')" = "m001" ]
  [ "$(echo "$output" | jq -r '.decisions | type')" = "array" ]
}

@test "status appends the open-decision footer" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m1 >/dev/null
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key" >/dev/null
  run "$REPO_ROOT/bin/fleet-status"
  [[ "$output" == *"pending"* ]]
  [[ "$output" == *"[d1]"* ]]
}

@test "status --json carries the mission ship result" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id j1 >/dev/null
  jq '.ship={mode:"local-merge",result:"merged",at:"now"}' "$FLEET_STATE_OVERRIDE/missions/j1/mission.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/j1/mission.json"
  run "$REPO_ROOT/bin/fleet-status" --json
  [ "$(echo "$output" | jq -r '.missions[0].ship.mode')" = "local-merge" ]
}

@test "status flags drive missions and their unread events" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id q1 >/dev/null
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; fleet_events_append q1 marker done'
  run "$REPO_ROOT/bin/fleet-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"q1"* ]]
  [[ "$output" == *"drive"* ]]
  [[ "$output" == *"1 unread"* ]]
}
