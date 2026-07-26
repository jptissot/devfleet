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

# --- single-instance hardening -----------------------------------------------

@test "a claim publishes its pid with the lock, never an empty lock" {
  . "$REPO_ROOT/bin/fleet-watch-lib"
  FLEET_STATE="$FLEET_STATE_OVERRIDE" fleet_watch_claim
  [ -d "$FLEET_STATE_OVERRIDE/.watch-lock" ]
  [ "$(cat "$FLEET_STATE_OVERRIDE/.watch-lock/pid")" = "$$" ]
}

@test "a second claim loses while the first holder is alive" {
  . "$REPO_ROOT/bin/fleet-watch-lib"
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  run env FLEET_STATE="$FLEET_STATE_OVERRIDE" bash -c \
    '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_claim'
  [ "$status" -ne 0 ]
  [ "$(cat "$FLEET_STATE_OVERRIDE/.watch-lock/pid")" = "$$" ]
}

@test "release leaves a lock this process does not own" {
  . "$REPO_ROOT/bin/fleet-watch-lib"
  mkdir -p "$FLEET_STATE_OVERRIDE/.watch-lock"
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  FLEET_STATE="$FLEET_STATE_OVERRIDE" bash -c \
    '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_release'
  [ -d "$FLEET_STATE_OVERRIDE/.watch-lock" ]
}

@test "a watcher whose lock was taken evicts itself and leaves the new lock alone" {
  "$REPO_ROOT/bin/fleet-watch" --ticks 20 --interval 1 >/dev/null 2>&1 &
  watcher=$!
  # Wait for it to claim, then simulate a thief taking the lock.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$FLEET_STATE_OVERRIDE/.watch-lock/pid" ] && break
    sleep 0.2
  done
  echo $$ > "$FLEET_STATE_OVERRIDE/.watch-lock/pid"
  # It notices on its next tick and stands down.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$watcher" 2>/dev/null || break
    sleep 0.5
  done
  ! kill -0 "$watcher" 2>/dev/null
  grep -q "watch-evicted" "$FLEET_STATE_OVERRIDE/journal.log"
  # The thief's lock survives the evicted watcher's exit.
  [ -d "$FLEET_STATE_OVERRIDE/.watch-lock" ]
  [ "$(cat "$FLEET_STATE_OVERRIDE/.watch-lock/pid")" = "$$" ]
}
