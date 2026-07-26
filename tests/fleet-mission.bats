setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "creates mission.json with entry stage and a worktree" {
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:repo1 --desc "add login" --id m001
  [ "$status" -eq 0 ]
  [[ "$output" == "m001" ]]
  mj="$FLEET_STATE_OVERRIDE/missions/m001/mission.json"
  [ -f "$mj" ]
  [ "$(jq -r .stage "$mj")" = "spec" ]
  [ "$(jq -r .type "$mj")" = "campaign" ]
  [ "$(jq -r .description "$mj")" = "add login" ]
  wt="$(jq -r .worktree_path "$mj")"; [ -d "$wt" ]
  [ "$(jq -r .orca_worktree_id "$mj")" != "null" ]
}

@test "campaign with --spec skips to plan" {
  echo "# spec" > "$FLEET_TMP/spec.md"
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --spec "$FLEET_TMP/spec.md" --id m002
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m002/mission.json")" = "plan" ]
}

@test "strike starts at plan" {
  run "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc "bug" --issue 42 --id m003
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m003/mission.json")" = "plan" ]
}

@test "machine missions record driver=machine and zeroed drive fields" {
  run "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m010
  [ "$status" -eq 0 ]
  mj="$FLEET_STATE_OVERRIDE/missions/m010/mission.json"
  [ "$(jq -r .driver "$mj")" = "machine" ]
  [ "$(jq -r .stage "$mj")" = "spec" ]
  [ "$(jq -r .spawn_count "$mj")" = "0" ]
  [ "$(jq -r .event_cursor "$mj")" = "0" ]
  [ "$(jq -r .extends "$mj")" = "0" ]
  [ "$(jq -r .last_anomaly_key "$mj")" = "" ]
  [ "$(jq -r .mission_started_at "$mj")" -gt 0 ]
}

@test "sortie missions are commander-driven and start at driving" {
  run "$REPO_ROOT/bin/fleet-mission" --type sortie --project acme --repo id:r --desc "rate limit" --id m011
  [ "$status" -eq 0 ]
  mj="$FLEET_STATE_OVERRIDE/missions/m011/mission.json"
  [ "$(jq -r .driver "$mj")" = "commander" ]
  [ "$(jq -r .stage "$mj")" = "driving" ]
  [ "$(jq -r .terminal "$mj")" = "null" ]
  [ -d "$(jq -r .worktree_path "$mj")" ]
}