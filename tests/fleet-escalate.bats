setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  echo "term_cmd" > "$FLEET_STATE_OVERRIDE/.commander-terminal"
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "advance blocked creates a decision record" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id e1 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e1 "blocked:need creds"
  "$REPO_ROOT/bin/fleet-advance" e1 >/dev/null
  [ "$(jq -r .stage "$(mj e1)")" = "blocked" ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"e1"* ]]
}

@test "day mode wakes the Commander on escalation; night mode holds" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id e2 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e2 "blocked:x"; "$REPO_ROOT/bin/fleet-advance" e2 >/dev/null
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'   # day -> woke
  : > "$FLEET_ORCA_LOG"
  touch "$FLEET_STATE_OVERRIDE/.night"
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc y --id e3 >/dev/null
  "$REPO_ROOT/bin/fleet-done" e3 "blocked:y"; "$REPO_ROOT/bin/fleet-advance" e3 >/dev/null
  ! orca_log_has $'terminal\x1fsend'   # night -> no wake, but record exists
  [ -n "$("$REPO_ROOT/bin/fleet-decision" list --open | grep e3)" ]
}