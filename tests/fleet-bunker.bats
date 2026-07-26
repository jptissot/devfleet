setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
}
teardown() { fleet_teardown_home; }

seam() {  # run <expr> with the seam sourced
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots
               '"$1"
}

@test "enabled is true when the role flags bunker" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  seam 'fleet_bunker_enabled executor acme id:r'
  [ "$output" = "true" ]
}

@test "enabled is false for a bare role with no repo override" {
  seam 'fleet_bunker_enabled frontier acme id:r'
  [ "$output" = "false" ]
}

@test "wrap targets the worktree and passes the command after --" {
  seam 'fleet_bunker_wrap /wt/x "pi \"\$(cat brief)\""'
  [ "$output" = 'airlock -C /wt/x -- pi "$(cat brief)"' ]
}

@test "state prints airlock's word and returns its exit code" {
  seam 'fleet_bunker_state /repo'
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]

  FLEET_FAKE_AIRLOCK_STATE=not-scaffolded seam 'fleet_bunker_state /repo'
  [ "$status" -eq 20 ]
  [ "$output" = "not-scaffolded" ]

  FLEET_FAKE_AIRLOCK_STATE=unapproved seam 'fleet_bunker_state /repo'
  [ "$status" -eq 10 ]

  FLEET_FAKE_AIRLOCK_STATE=no-image seam 'fleet_bunker_state /repo'
  [ "$status" -eq 21 ]
}

@test "state asks airlock about the repo, not the caller's directory" {
  seam 'fleet_bunker_state /repo'
  bunker_log_has $'airlock\x1fstatus\x1f-C\x1f/repo'
}

@test "state reports not-installed when airlock is missing" {
  # PATH without the fake: the seam names the missing tool rather than letting a
  # bare command-not-found surface as an opaque failure.
  run bash -c 'PATH=/usr/bin:/bin; . "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-project"; . "$REPO_ROOT/bin/fleet-bunker"; fleet_roots
               fleet_bunker_state /repo'
  [ "$status" -eq 127 ]
  [ "$output" = "not-installed" ]
}

@test "a rebuild-pending repo can still launch" {
  # 22 means the running container predates the newest image — the sandbox is
  # usable, so it must not block a spawn.
  FLEET_FAKE_AIRLOCK_STATE=rebuild-pending seam 'fleet_bunker_launchable /repo'
  [ "$status" -eq 0 ]
  FLEET_FAKE_AIRLOCK_STATE=ready seam 'fleet_bunker_launchable /repo'
  [ "$status" -eq 0 ]
  FLEET_FAKE_AIRLOCK_STATE=no-image seam 'fleet_bunker_launchable /repo'
  [ "$status" -ne 0 ]
}

@test "each blocking state names what to do about it" {
  seam 'fleet_bunker_remedy 20'
  [[ "$output" == *"init"* ]]
  seam 'fleet_bunker_remedy 10'
  [[ "$output" == *"build"* ]]
  seam 'fleet_bunker_remedy 11'
  [[ "$output" == *"config"* ]]
  seam 'fleet_bunker_remedy 21'
  [[ "$output" == *"build"* ]]
  seam 'fleet_bunker_remedy 127'
  [[ "$output" == *"install"* ]]
}
