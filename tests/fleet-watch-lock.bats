setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "a live lock makes a second watcher exit 0 without starting" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"   # $$ is bats: alive
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  ! grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a stale lock is claimed, not honored" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  # A pid that cannot be alive: reap a real child, then reuse its pid.
  sleep 0 & dead=$!; wait $dead 2>/dev/null || true
  echo "$dead" > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "a lock with no pid file is claimed" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  grep -q "watch-start" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "the lock is released when the watcher exits" {
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  [ ! -d "$FLEET_STATE_OVERRIDE/.watch-lock" ]
  # Absence alone is vacuous. A second sequential run must also start: that only
  # holds if the first released, rather than never having claimed.
  run "$REPO_ROOT/bin/fleet-watch" --ticks 1 --interval 0
  [ "$status" -eq 0 ]
  [ "$(grep -c watch-start "$FLEET_STATE_OVERRIDE/journal.log")" -eq 2 ]
}

@test "--tick is not guarded by the lock" {
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  run "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$status" -eq 0 ]
}
