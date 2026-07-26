setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
inflight() {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_mission_in_flight '"$1"
}
set_stage() { jq --arg s "$2" '.stage=$s' "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }

@test "machine mission: graph stage is in flight, terminal state is not" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id f1 >/dev/null
  run inflight f1; [ "$status" -eq 0 ]
  set_stage f1 ready
  run inflight f1; [ "$status" -ne 0 ]
  set_stage f1 done
  run inflight f1; [ "$status" -ne 0 ]
}

@test "drive mission: driving is in flight, terminal states are not" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id f2 >/dev/null
  jq '.driver="commander" | .stage="driving"' "$(mj f2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj f2)"
  run inflight f2; [ "$status" -eq 0 ]
  set_stage f2 execute          # a free-text label is still in flight
  run inflight f2; [ "$status" -eq 0 ]
  for s in ready done parked blocked failed; do
    set_stage f2 "$s"
    run inflight f2; [ "$status" -ne 0 ]
  done
}

@test "unknown mission is not in flight" {
  run inflight nope; [ "$status" -ne 0 ]
}