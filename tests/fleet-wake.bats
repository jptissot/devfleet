setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "wakes the recorded Commander terminal via the backend" {
  echo "term_cmd" > "$FLEET_STATE_OVERRIDE/.commander-terminal"
  run "$REPO_ROOT/bin/fleet-wake" "decision d1: need a key"
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'
}

@test "no Commander terminal -> pending file, still exits 0" {
  run "$REPO_ROOT/bin/fleet-wake" "hello"
  [ "$status" -eq 0 ]
  grep -q "hello" "$FLEET_STATE_OVERRIDE/.wake-pending"
}