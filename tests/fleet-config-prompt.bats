setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id w1 >/dev/null
}
teardown() { fleet_teardown_home; }

@test "prompt write creates a usable template" {
  run "$REPO_ROOT/bin/fleet-config" prompt write --name bench.txt \
    --text "Benchmark {mission_id} in {worktree}."
  [ "$status" -eq 0 ]
  [ -f "$FLEET_HOME/prompts/bench.txt" ]
  grep -q "Benchmark {mission_id}" "$FLEET_HOME/prompts/bench.txt"
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --description "a probe type" --when-to-use "tests only" \
    --palette bench:executor:bench.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "promote turns an ad-hoc brief into a template without the contract footer" {
  "$REPO_ROOT/bin/fleet-spawn" --mission w1 --role executor \
    --prompt-text "Profile the hot path in {worktree}." --label prof --dry-run >/dev/null
  run "$REPO_ROOT/bin/fleet-config" prompt promote --mission w1 --label prof --name profile.txt
  [ "$status" -eq 0 ]
  grep -q "Profile the hot path" "$FLEET_HOME/prompts/profile.txt"
  ! grep -q "fleet-done" "$FLEET_HOME/prompts/profile.txt"
}

@test "promote fails when the brief does not exist" {
  run "$REPO_ROOT/bin/fleet-config" prompt promote --mission w1 --label nope --name x.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"no brief"* ]]
}