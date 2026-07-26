setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mt() { echo "$FLEET_CONFIG_OVERRIDE/missions/$1.json"; }

@test "create writes a commander type with a palette" {
  run "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --description "a probe type" --when-to-use "tests only" \
    --palette recon:frontier:recon.txt --palette execute:executor:execute.txt --max-spawns 4
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver "$(mt probe)")" = "commander" ]
  [ "$(jq -r '.palette | length' "$(mt probe)")" = "2" ]
  [ "$(jq -r '.palette[0].prompt' "$(mt probe)")" = "recon.txt" ]
  [ "$(jq -r .max_spawns "$(mt probe)")" = "4" ]
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "a created type is immediately usable by fleet-mission" {
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --description "a probe type" --when-to-use "tests only" \
    --palette execute:executor:execute.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-mission" --type probe --project a --repo id:r --desc x --id p1
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver "$FLEET_STATE_OVERRIDE/missions/p1/mission.json")" = "commander" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/p1/mission.json")" = "driving" ]
}

@test "a cap above the ceiling is refused" {
  run "$REPO_ROOT/bin/fleet-config" type create --name greedy --driver commander \
    --palette execute:executor:execute.txt --max-spawns 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceiling"* ]]
  [ ! -f "$(mt greedy)" ]
}

@test "a type that would not validate is refused and nothing is written" {
  run "$REPO_ROOT/bin/fleet-config" type create --name broken --driver commander \
    --palette execute:executor:missing.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing.txt"* ]]
  [ ! -f "$(mt broken)" ]
}

@test "set changes a cap without touching the palette" {
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --description "a probe type" --when-to-use "tests only" \
    --palette execute:executor:execute.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-config" type set --name probe --max-spawns 2
  [ "$status" -eq 0 ]
  [ "$(jq -r .max_spawns "$(mt probe)")" = "2" ]
  [ "$(jq -r '.palette | length' "$(mt probe)")" = "1" ]
}

@test "show prints the type as JSON" {
  run "$REPO_ROOT/bin/fleet-config" type show --name sortie
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .type)" = "sortie" ]
}

@test "a stage on a commander type is refused (no stray stages)" {
  "$REPO_ROOT/bin/fleet-config" type create --name probe --driver commander \
    --description "a probe type" --when-to-use "tests only" \
    --palette execute:executor:execute.txt >/dev/null
  run "$REPO_ROOT/bin/fleet-config" type set --name probe --stage x:frontier:plan.txt:y
  [ "$status" -ne 0 ]
  [[ "$output" == *"commander-driven"* ]]
  [ "$(jq -r '.stages // "none"' "$(mt probe)")" = "none" ]
}

@test "a palette on a machine type is refused" {
  run "$REPO_ROOT/bin/fleet-config" type create --name mach --driver machine \
    --entry a --stage a:frontier:plan.txt:b --palette x:frontier:plan.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-driven"* ]]
  [ ! -f "$(mt mach)" ]
}