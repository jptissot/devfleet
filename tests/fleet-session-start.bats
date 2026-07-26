setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

mk() { "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id "$1" >/dev/null; }

@test "reconcile journals drift for a gone terminal and writes a beacon" {
  mk s1
  jq '.terminal="term_dead"' "$FLEET_STATE_OVERRIDE/missions/s1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/s1/mission.json"
  FLEET_FAKE_TERM_GONE=1 run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_STATE_OVERRIDE/.watch-beacon" ]
  grep -q "session-drift" "$FLEET_STATE_OVERRIDE/journal.log"
  grep -q "s1" "$FLEET_STATE_OVERRIDE/journal.log"
  # observe-only: stage unchanged
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/s1/mission.json")" = "spec" ]
}

@test "no drift when terminals exist" {
  mk s2
  jq '.terminal="term_live"' "$FLEET_STATE_OVERRIDE/missions/s2/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/s2/mission.json"
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  ! grep -q "session-drift s2" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "session start bootstraps a missing roles.json" {
  rm -f "$FLEET_CONFIG_OVERRIDE/roles.json"
  harness="$FLEET_TMP/harness"; mkdir -p "$harness"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$harness/claude"; chmod +x "$harness/claude"
  PATH="$harness:$PATH" run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_CONFIG_OVERRIDE/roles.json" ]
  [ "$(jq -r .frontier.cmd "$FLEET_CONFIG_OVERRIDE/roles.json")" = "claude" ]
}

@test "session start reports config problems without failing the session" {
  jq '.driver="autopilot"' "$FLEET_CONFIG_OVERRIDE/missions/sortie.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_CONFIG_OVERRIDE/missions/sortie.json"
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"config"* ]]
}
@test "session start briefs the Commander and both root modes" {
  run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"you are the Commander of this fleet"* ]]
  [[ "$output" == *"operate"* ]]
  [[ "$output" == *"develop"* ]]
  [[ "$output" == *"reconciled 0 missions, 0 drifted"* ]]
}

@test "session start in a mission worktree briefs an executor, not a Commander" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree w1)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/w1.execute.brief"
  run bash -c "cd '$wt' && '$REPO_ROOT/bin/fleet-session-start' --no-watch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the Commander"* ]]
  [[ "$output" != *"you are the Commander of this fleet"* ]]
}

@test "session start refuses a worktree with no brief and creates no state" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree w2)"
  run bash -c "cd '$wt' && FLEET_HOME='$wt' '$REPO_ROOT/bin/fleet-session-start' --no-watch"
  [ "$status" -ne 0 ]
  [ ! -d "$wt/state" ]
}

@test "bootstrap still runs at the fleet root when roles.json is absent" {
  rm -f "$FLEET_CONFIG_OVERRIDE/roles.json"
  harness="$FLEET_TMP/harness"; mkdir -p "$harness"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$harness/claude"; chmod +x "$harness/claude"
  PATH="$harness:$PATH" run "$REPO_ROOT/bin/fleet-session-start" --no-watch
  [ "$status" -eq 0 ]
  [ -f "$FLEET_CONFIG_OVERRIDE/roles.json" ]
  [[ "$output" == *"you are the Commander of this fleet"* ]]
}

@test "session start registers the Commander terminal so wakes land" {
  ORCA_PANE_KEY=tab_1:leaf_1 "$REPO_ROOT/bin/fleet-session-start" --no-watch >/dev/null
  [ "$(cat "$FLEET_STATE_OVERRIDE/.commander-terminal")" = "term_001" ]
}

@test "a session outside an orca pane leaves any existing registration alone" {
  echo term_old > "$FLEET_STATE_OVERRIDE/.commander-terminal"
  ORCA_PANE_KEY= "$REPO_ROOT/bin/fleet-session-start" --no-watch >/dev/null
  [ "$(cat "$FLEET_STATE_OVERRIDE/.commander-terminal")" = "term_old" ]
}

@test "registering drains wakes that queued while nobody was listening" {
  printf 'decision d7 needs you\n' > "$FLEET_STATE_OVERRIDE/.wake-pending"
  ORCA_PANE_KEY=tab_1:leaf_1 "$REPO_ROOT/bin/fleet-session-start" --no-watch >/dev/null
  orca_log_has $'terminal\x1fsend\x1f--terminal\x1fterm_001'
  [ ! -s "$FLEET_STATE_OVERRIDE/.wake-pending" ]
}
