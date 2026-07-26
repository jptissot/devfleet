setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

roles() { echo "$FLEET_CONFIG_OVERRIDE/roles.json"; }

@test "roles set writes harness, cmd and bunker" {
  run "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness ollama --cmd "oll run" --bunker true
  [ "$status" -eq 0 ]
  [ "$(jq -r .executor.harness "$(roles)")" = "ollama" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "oll run" ]
  [ "$(jq -r .executor.bunker "$(roles)")" = "true" ]
}

@test "roles set records repeatable provision commands" {
  run "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness omp --cmd omp --bunker true \
    --provision "omp plugin install https://github.com/obra/superpowers" \
    --provision "omp plugin list"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.executor.provision | length' "$(roles)")" = "2" ]
  [ "$(jq -r '.executor.provision[0]' "$(roles)")" = "omp plugin install https://github.com/obra/superpowers" ]
}

@test "roles set without --provision drops a stale list" {
  "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness omp --cmd omp --provision "x"
  "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness omp --cmd omp
  [ "$(jq -r '.executor.provision // "absent"' "$(roles)")" = "absent" ]
}

@test "roles set leaves other roles alone" {
  before="$(jq -r .frontier.cmd "$(roles)")"
  "$REPO_ROOT/bin/fleet-config" roles set --role executor --harness pi --cmd pi
  [ "$(jq -r .frontier.cmd "$(roles)")" = "$before" ]
}

@test "roles set needs role, harness and cmd" {
  run "$REPO_ROOT/bin/fleet-config" roles set --role executor
  [ "$status" -ne 0 ]
}

@test "project passthrough creates a project" {
  run "$REPO_ROOT/bin/fleet-config" project create --name acme
  [ "$status" -eq 0 ]
  [ -f "$FLEET_PROJECTS_OVERRIDE/acme/project.json" ]
}

@test "a mission type without a description is rejected" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/nodesc.json" <<'JSON'
{ "type": "nodesc", "when_to_use": "never", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *description* ]]
}

@test "a mission type without when_to_use is rejected" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/nowhen.json" <<'JSON'
{ "type": "nowhen", "description": "a thing", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
  [[ "$output" == *when_to_use* ]]
}

@test "an empty description is rejected, not just a missing one" {
  cat > "$FLEET_CONFIG_OVERRIDE/missions/blank.json" <<'JSON'
{ "type": "blank", "description": "", "when_to_use": "never", "entry": "a",
  "stages": [ { "name": "a", "role": "frontier", "prompt": "spec.txt" } ] }
JSON
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -ne 0 ]
}

@test "the shipped mission types all declare both fields" {
  # The backfill is part of this change; without it validate goes red on the
  # configs the repo ships.
  for f in "$REPO_ROOT"/config/missions/*.json; do
    [ -n "$(jq -r '.description // ""' "$f")" ] || { echo "no description: $f"; false; }
    [ -n "$(jq -r '.when_to_use // ""' "$f")" ] || { echo "no when_to_use: $f"; false; }
  done
}

@test "type create writes description and when_to_use" {
  run "$REPO_ROOT/bin/fleet-config" type create --name probe \
    --driver machine --entry a \
    --description "a probe type" --when-to-use "testing only" \
    --stage 'a:frontier:spec.txt:b' --stage 'b:frontier:review.txt:'
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$FLEET_CONFIG_OVERRIDE/missions/probe.json")" = "a probe type" ]
  [ "$(jq -r .when_to_use "$FLEET_CONFIG_OVERRIDE/missions/probe.json")" = "testing only" ]
}

@test "a type created through fleet-config passes its own validation" {
  # The property that matters: the supported path must not produce config the
  # validator rejects.
  "$REPO_ROOT/bin/fleet-config" type create --name probe2 \
    --driver machine --entry a \
    --description "a probe type" --when-to-use "testing only" \
    --stage 'a:frontier:spec.txt:' >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "type set can add the fields to an existing type" {
  run "$REPO_ROOT/bin/fleet-config" type set --name campaign \
    --description "changed" --when-to-use "changed too"
  [ "$status" -eq 0 ]
  [ "$(jq -r .description "$FLEET_CONFIG_OVERRIDE/missions/campaign.json")" = "changed" ]
}

@test "the roles example documents how skills reach a frontier agent" {
  # roles.json is git-ignored, so the example file is the only committed record
  # of what a working configuration looks like.
  ex="$REPO_ROOT/config/roles.json.example"
  [ "$(jq -r '.frontier.provision | length' "$ex")" -gt 0 ]
  jq -r '.frontier.provision[]' "$ex" | grep -q 'mattpocock-skills@mattpocock'
  jq -r '.frontier.provision[]' "$ex" | grep -q 'superpowers'
}

@test "the roles example is valid json and names both roles" {
  ex="$REPO_ROOT/config/roles.json.example"
  run jq -e '.frontier.cmd and .executor.cmd' "$ex"
  [ "$status" -eq 0 ]
}