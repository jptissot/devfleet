bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
  fleet_seed_config
}
teardown() { fleet_teardown_home; }

pl() { bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; '"$1"; }

@test "entry stage per type" {
  run pl 'fleet_pipeline_entry campaign'; [ "$output" = "spec" ]
  run pl 'fleet_pipeline_entry strike';   [ "$output" = "plan" ]
  run pl 'fleet_pipeline_entry recon';    [ "$output" = "recon" ]
  run pl 'fleet_pipeline_entry fortify';  [ "$output" = "audit" ]
}

@test "stage fields read from the graph" {
  run pl 'fleet_pipeline_field campaign execute role';  [ "$output" = "executor" ]
  run pl 'fleet_pipeline_field campaign execute next';  [ "$output" = "review" ]
  run pl 'fleet_pipeline_field campaign review on_pass'; [ "$output" = "ready" ]
  run pl 'fleet_pipeline_field campaign review on_fail'; [ "$output" = "fix" ]
  run pl 'fleet_pipeline_field campaign review review';  [ "$output" = "true" ]
}

@test "fix limit and terminal stage" {
  run pl 'fleet_pipeline_fix_limit campaign'; [ "$output" = "3" ]
  run pl 'fleet_pipeline_field recon report terminal'; [ "$output" = "true" ]
}

@test "missing type dies" {
  run pl 'fleet_pipeline_file nope'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}

@test "is_stage recognizes graph stages, rejects terminal states" {
  run pl 'fleet_pipeline_is_stage campaign execute'; [ "$status" -eq 0 ]
  run pl 'fleet_pipeline_is_stage campaign ready';   [ "$status" -ne 0 ]
}

@test "driver defaults to machine; sortie is commander-driven" {
  run pl 'fleet_pipeline_driver campaign'; [ "$output" = "machine" ]
  run pl 'fleet_pipeline_driver sortie';   [ "$output" = "commander" ]
}

@test "palette lookup resolves role and prompt" {
  run pl 'fleet_pipeline_has_palette sortie execute'; [ "$status" -eq 0 ]
  run pl 'fleet_pipeline_has_palette sortie nope';    [ "$status" -ne 0 ]
  run pl 'fleet_pipeline_palette_field sortie execute role';   [ "$output" = "executor" ]
  run pl 'fleet_pipeline_palette_field sortie execute prompt'; [ "$output" = "execute.txt" ]
  run pl 'fleet_pipeline_palette_field sortie review role';    [ "$output" = "frontier" ]
}

@test "palette names list every entry in order" {
  run pl 'fleet_pipeline_palette_names sortie | tr "\n" " "'
  [ "$output" = "spec plan execute review fix audit recon " ]
}

@test "caps come from the type, with built-in defaults" {
  run pl 'fleet_pipeline_cap sortie max_spawns';            [ "$output" = "12" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds';   [ "$output" = "14400" ]
  run pl 'fleet_pipeline_cap campaign max_spawns';          [ "$output" = "12" ]
  run pl 'fleet_pipeline_cap campaign max_mission_seconds'; [ "$output" = "14400" ]
}

@test "unknown cap name dies" {
  run pl 'fleet_pipeline_cap sortie max_bananas'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}

@test "caps are clamped by the built-in ceilings" {
  # sortie asks for more than the built-in ceiling allows
  jq '.max_spawns=999 | .max_mission_seconds=999999' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run pl 'fleet_pipeline_cap sortie max_spawns';          [ "$output" = "24" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds'; [ "$output" = "28800" ]
}

@test "a lower type value wins over the ceiling" {
  jq '.max_spawns=3' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run pl 'fleet_pipeline_cap sortie max_spawns'; [ "$output" = "3" ]
}

@test "config/fleet.json lowers the ceiling" {
  printf '{"max_spawns_ceiling":2,"max_mission_seconds_ceiling":60}\n' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  run pl 'fleet_pipeline_cap sortie max_spawns';          [ "$output" = "2" ]
  run pl 'fleet_pipeline_cap sortie max_mission_seconds'; [ "$output" = "60" ]
  run pl 'fleet_pipeline_ceiling max_spawns';             [ "$output" = "2" ]
}

@test "an unknown ceiling name dies" {
  run pl 'fleet_pipeline_ceiling max_bananas'
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
}
@test "fleet.json present but ceiling key absent uses built-in default" {
  printf '{"some_other_key":1}\n' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  run pl 'fleet_pipeline_ceiling max_spawns'
  [ "$output" = "24" ]
}

@test "the interactive budget defaults to four hours" {
  run pl 'fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = "14400" ]
}

@test "the interactive budget is clamped by the mission-seconds ceiling" {
  # A cap the operator can raise from the environment is not a cap. This is the
  # same clamp every other budget goes through.
  echo '{"max_spawns_ceiling":24,"max_mission_seconds_ceiling":600}' > "$FLEET_CONFIG_OVERRIDE/fleet.json"
  FLEET_INTERACTIVE_BUDGET_SECONDS=99999 run pl 'fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = "600" ]
}

@test "an interactive budget below the ceiling is honoured as given" {
  FLEET_INTERACTIVE_BUDGET_SECONDS=300 run pl 'fleet_pipeline_interactive_budget campaign'
  [ "$status" -eq 0 ]
  [ "$output" = "300" ]
}

@test "field lookup on a commander-driven type (no stages key) is empty and silent" {
  # sortie has a palette, not a stage graph. fleet_detect calls fleet_pipeline_field
  # unconditionally for every mission, sortie included, so `.stages[]` on a missing
  # key must not raise a jq error — the empty result is already the correct answer
  # ("not interactive"), but a stray stderr line would fire on every watch tick for
  # every in-flight commander-driven mission.
  run --separate-stderr pl 'fleet_pipeline_field sortie execute interactive'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "" ]
}

