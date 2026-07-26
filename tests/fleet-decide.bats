setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  command -v gum >/dev/null 2>&1 || skip "gum not installed"
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m1 >/dev/null
}
teardown() { fleet_teardown_home; }

@test "fleet-decide exits 0 with no open decisions" {
  run "$REPO_ROOT/bin/fleet-decide"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No open decisions"* ]]
}

@test "fleet-decide requires gum" {
  # gum is installed for this suite; verify the guard works by checking the script
  grep -q "command -v gum" "$REPO_ROOT/bin/fleet-decide"
}