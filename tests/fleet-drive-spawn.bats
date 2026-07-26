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
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id v1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
setj() { jq "$2" "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }

@test "spawn launches a palette stage and counts it" {
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "plan" ]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
  [ "$(jq -r .terminal "$(mj v1)")" != "null" ]
  orca_log_has "terminal"
}

@test "spawn refuses while an agent is in flight" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage execute
  [ "$status" -ne 0 ]
  [[ "$output" == *"in flight"* ]]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
}

@test "spawn refuses on a machine-driven mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id v2 >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v2 --stage plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
}

@test "hitting max_spawns parks the mission and opens an extend decision" {
  setj v1 '.spawn_count=12'
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "parked" ]
  [ "$(grep -c cap "$FLEET_STATE_OVERRIDE/missions/v1/events")" -ge 1 ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"v1"* ]]
  [[ "$output" == *"extend"* ]] || grep -ql extend "$FLEET_STATE_OVERRIDE"/decisions/*.json
}

@test "ad-hoc spawn is counted and labels the stage" {
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --role executor \
      --prompt-text "benchmark {mission_id}" --label bench
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "bench" ]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
}

@test "a label from the state vocabulary is refused" {
  for bad in driving ready done parked blocked failed; do
    run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --role executor --prompt-text hi --label "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
    [ "$(jq -r .stage "$(mj v1)")" = "driving" ]
    [ "$(jq -r .spawn_count "$(mj v1)")" = "0" ]
  done
}

@test "--stage combined with an ad-hoc brief is refused" {
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan \
      --role executor --prompt-text hi --label bench
  [ "$status" -ne 0 ]
  [[ "$output" == *"--stage"* ]]
  [ "$(jq -r .stage "$(mj v1)")" = "driving" ]
  [ "$(jq -r .spawn_count "$(mj v1)")" = "0" ]
}

@test "stop clears a live agent and hands the mission back" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" stop --mission v1
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "driving" ]
  [ "$(jq -r .terminal "$(mj v1)")" = "null" ]
  [ "$(jq -r .last_stage "$(mj v1)")" = "plan" ]
  grep -q '"kind":"note"' "$FLEET_STATE_OVERRIDE/missions/v1/events"
  orca_log_has "close"
}

@test "stop does not spend a spawn and leaves the caps alone" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission v1 --stage plan >/dev/null
  "$REPO_ROOT/bin/fleet-drive" stop --mission v1
  [ "$(jq -r .spawn_count "$(mj v1)")" = "1" ]
}

@test "stop on an idle mission is a no-op that still succeeds" {
  run "$REPO_ROOT/bin/fleet-drive" stop --mission v1
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj v1)")" = "driving" ]
}

@test "stop refuses a machine-driven mission" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id v3 >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" stop --mission v3
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
}