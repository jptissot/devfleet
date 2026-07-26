setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }
fresh_beacon() { date +%s > "$FLEET_STATE_OVERRIDE/.watch-beacon"; }
stale_beacon() { echo 0 > "$FLEET_STATE_OVERRIDE/.watch-beacon"; }

@test "blocks when a mission is in flight and the beacon is stale" {
  mk g1; stale_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 2 ]
  [[ "$output" == *"watcher"* ]]
}

@test "allows when the beacon is fresh" {
  mk g2; fresh_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 0 ]
}

@test "allows when no mission is in flight (even with stale beacon)" {
  stale_beacon
  run "$REPO_ROOT/bin/fleet-turnend-guard"
  [ "$status" -eq 0 ]
}