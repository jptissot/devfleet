setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id x1 >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
setj() { jq "$2" "$(mj "$1")" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj "$1")"; }
spawns() { grep -cF $'orca\x1fterminal\x1fcreate' "$FLEET_ORCA_LOG" || true; }

@test "extend clears the caps, un-parks, and does not spawn" {
  setj x1 '.spawn_count=12'
  run "$REPO_ROOT/bin/fleet-drive" spawn --mission x1 --stage plan
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "parked" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | awk -F'\t' '{print $1}' | head -n1)"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" extend
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "driving" ]
  [ "$(jq -r .spawn_count "$(mj x1)")" = "0" ]
  [ "$(jq -r .extends "$(mj x1)")" = "1" ]
  [ "$(jq -r .mission_started_at "$(mj x1)")" -gt 0 ]
  [ "$(spawns)" = "$before" ]
}

@test "resume on a drive mission hands back without spawning" {
  "$REPO_ROOT/bin/fleet-drive" spawn --mission x1 --stage plan >/dev/null
  setj x1 '.stage="parked"'
  did="$("$REPO_ROOT/bin/fleet-decision" create --mission x1 --stage plan --question "resume?")"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x1)")" = "driving" ]
  [ "$(jq -r .terminal "$(mj x1)")" = "null" ]
  [ "$(spawns)" = "$before" ]
}

@test "resume on a machine mission still re-spawns the last stage" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc y --id x2 >/dev/null
  setj x2 '.stage="parked" | .last_stage="plan"'
  did="$("$REPO_ROOT/bin/fleet-decision" create --mission x2 --stage plan --question "resume?")"
  before="$(spawns)"
  run "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj x2)")" = "plan" ]
  [ "$(spawns)" -gt "$before" ]
}