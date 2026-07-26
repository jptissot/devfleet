setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  REPO="$FLEET_TMP/repo"; mkdir -p "$REPO"
}
teardown() { fleet_teardown_home; }

@test "init scaffolds unattended, with the executor's harness" {
  # airlock init prompts for a harness on a terminal; --yes forbids that, so the
  # answer comes from roles.json rather than a spawn hanging on stdin.
  run "$REPO_ROOT/bin/fleet-loadout" init --path "$REPO"
  [ "$status" -eq 0 ]
  # -C leads: airlock's global -C loop stops at `init`, which parses its own
  # flags and rejects a trailing -C.
  bunker_log_has $'airlock\x1f-C\x1f'"$REPO"$'\x1finit\x1f--yes\x1f--harness\x1fpi'
}

@test "init takes an explicit --harness over the role's" {
  run "$REPO_ROOT/bin/fleet-loadout" init --path "$REPO" --harness claude-code
  [ "$status" -eq 0 ]
  bunker_log_has $'--harness\x1fclaude-code'
}

@test "build builds the image without launching an agent" {
  run "$REPO_ROOT/bin/fleet-loadout" build --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has $'airlock\x1fbuild\x1f-C'
}

@test "provision runs each role's commands inside the bunker" {
  # Harness extensions (plugins, skills) install into the agent's home, and the
  # persisted home is mounted over whatever the image put there — so this cannot
  # be a Containerfile step. It runs in the container, once, and survives every
  # later rebuild because the home outlives the image.
  jq '.executor.provision = ["omp plugin install sp", "omp plugin list"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run "$REPO_ROOT/bin/fleet-loadout" provision --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has $'airlock\x1f-C\x1f'"$REPO"$'\x1f--\x1fbash\x1f-lc\x1fomp plugin install sp'
  bunker_log_has $'omp plugin list'
  grep -q 'loadout-provision' "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a provision command that reads stdin does not eat the ones behind it" {
  jq '.executor.provision = ["first", "second", "third"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run "$REPO_ROOT/bin/fleet-loadout" provision --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has 'first'
  bunker_log_has 'second'
  bunker_log_has 'third'
}

@test "provision skips roles that declare nothing" {
  # The example roles now document the frontier's mattpocock/superpowers
  # install commands (task 7), so the seeded default is no longer "nothing
  # declared" — clear both roles' lists explicitly to exercise that case.
  jq '.frontier.provision = [] | .executor.provision = []' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run "$REPO_ROOT/bin/fleet-loadout" provision --path "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to provision"* ]]
}

@test "a failing provision command fails the run and names itself" {
  jq '.frontier.provision = ["boom"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  FLEET_FAKE_BUNKER_EXEC_FAIL=1 run "$REPO_ROOT/bin/fleet-loadout" provision --path "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boom"* ]]
}

@test "status passes airlock's word and exit code straight through" {
  run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -eq 0 ]; [[ "$output" == *"ready"* ]]

  FLEET_FAKE_AIRLOCK_STATE=not-scaffolded run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -eq 20 ]; [[ "$output" == *"not-scaffolded"* ]]

  FLEET_FAKE_AIRLOCK_STATE=no-image run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -eq 21 ]
}

@test "status on a blocking state names the remedy" {
  FLEET_FAKE_AIRLOCK_STATE=unapproved run "$REPO_ROOT/bin/fleet-loadout" status --path "$REPO"
  [ "$status" -eq 10 ]
  [[ "$output" == *"build"* ]]
}

@test "each subcommand journals what it did" {
  run "$REPO_ROOT/bin/fleet-loadout" init --path "$REPO"
  run "$REPO_ROOT/bin/fleet-loadout" build --path "$REPO"
  grep -q 'loadout-init' "$FLEET_STATE_OVERRIDE/journal.log"
  grep -q 'loadout-build' "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a multi-line provision command is one command, not several" {
  # A provisioning step is often a whole script — a heredoc that installs a hook,
  # a multi-line jq program. Splitting on newlines hands the shell a fragment,
  # and an unterminated heredoc then waits on stdin for the rest of the mission.
  jq '.executor.provision = ["printf one\nprintf two", "printf three"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run "$REPO_ROOT/bin/fleet-loadout" provision --path "$REPO"
  [ "$status" -eq 0 ]
  bunker_log_has $'printf one\nprintf two'      # arrived whole
  bunker_log_has 'printf three'
}
