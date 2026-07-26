setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
  mkdir -p "$FLEET_CONFIG_OVERRIDE/missions"
  cp "$REPO_ROOT"/config/missions/*.json "$FLEET_CONFIG_OVERRIDE/missions/"
  cp -r "$REPO_ROOT"/prompts "$FLEET_HOME/prompts"
  FAKEHARNESS="$FLEET_TMP/harness"; mkdir -p "$FAKEHARNESS"
  # Isolate PATH: fake harness + essential system dirs only (no real harnesses)
  export PATH="$FAKEHARNESS:/usr/bin:/bin"
}
teardown() { fleet_teardown_home; }

fake() { printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEHARNESS/$1"; chmod +x "$FAKEHARNESS/$1"; }
roles() { echo "$FLEET_CONFIG_OVERRIDE/roles.json"; }

@test "bootstrap maps a frontier and an executor harness" {
  fake claude; fake pi
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "pi" ]
  [ "$(jq -r .executor.bunker "$(roles)")" = "true" ]
  [[ "$output" == *"frontier"* ]]
}

@test "a single harness fills both roles" {
  fake claude
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
  [ "$(jq -r .executor.cmd "$(roles)")" = "claude" ]
  [[ "$output" == *"both roles"* ]]
}

@test "no harness at all dies with the list it looked for" {
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"pi"* ]]
  [ ! -f "$(roles)" ]
}

@test "bootstrap refuses to clobber without --force" {
  fake claude; fake pi
  "$REPO_ROOT/bin/fleet-config" bootstrap >/dev/null
  jq '.frontier.cmd="handmade"' "$(roles)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(roles)"
  run "$REPO_ROOT/bin/fleet-config" bootstrap
  [ "$status" -ne 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "handmade" ]
  run "$REPO_ROOT/bin/fleet-config" bootstrap --force
  [ "$status" -eq 0 ]
  [ "$(jq -r .frontier.cmd "$(roles)")" = "claude" ]
}

@test "the bootstrapped config validates" {
  fake claude; fake pi
  "$REPO_ROOT/bin/fleet-config" bootstrap >/dev/null
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}