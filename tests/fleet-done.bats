setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  ID=$("$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id m001)
  WT=$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m001/mission.json")
}
teardown() { fleet_teardown_home; }

@test "fleet-done writes a marker into the worktree" {
  run "$REPO_ROOT/bin/fleet-done" m001 done
  [ "$status" -eq 0 ]
  [ -f "$WT/.devfleet/m001.status" ]
  [[ "$(cat "$WT/.devfleet/m001.status")" == *$'\t'"done" ]]
}

@test "fleet_done_latest returns the last status verb" {
  "$REPO_ROOT/bin/fleet-done" m001 done
  "$REPO_ROOT/bin/fleet-done" m001 "blocked:need a key"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-done"; fleet_roots; fleet_done_latest m001'
  [ "$status" -eq 0 ]
  [[ "$output" == "blocked:need a key" ]]
}