setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mt() { echo "$FLEET_CONFIG_OVERRIDE/missions/$1.json"; }

@test "the shipped configuration validates" {
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "malformed JSON is caught" {
  printf '{ this is not json' > "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"sortie"* ]]
}

@test "a palette entry pointing at a missing prompt is caught" {
  jq '.palette[0].prompt="nope.txt"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope.txt"* ]]
}

@test "an unknown role is caught" {
  jq '.palette[0].role="wizard"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"wizard"* ]]
}

@test "an unknown driver is caught" {
  jq '.driver="autopilot"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"autopilot"* ]]
}

@test "a machine type whose entry is not a stage is caught" {
  jq '.entry="nowhere"' "$(mt campaign)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt campaign)"
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nowhere"* ]]
}

@test "--json lists findings as an array" {
  jq '.driver="autopilot"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-config" validate --json
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.[0].file')" != "null" ]
  [ "$(echo "$output" | jq -r '.[0].error')" != "null" ]
}

@test "spawn fails closed on an invalid type" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id c1 >/dev/null
  jq '.palette[2].prompt="gone.txt"' "$(mt sortie)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mt sortie)"
  run "$REPO_ROOT/bin/fleet-spawn" --mission c1 --stage execute --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"gone.txt"* ]]
}