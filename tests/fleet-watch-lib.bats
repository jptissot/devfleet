setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

wl() { bash -c 'export REPO_ROOT; . "$REPO_ROOT/bin/fleet-watch-lib"; '"$1"; }

@test "hash is stable and changes with content" {
  d="$FLEET_TMP/wt"; mkdir -p "$d"; fleet_git_init "$d"
  h1="$(wl 'fleet_watch_hash "'"$d"'"')"
  h2="$(wl 'fleet_watch_hash "'"$d"'"')"
  [ "$h1" = "$h2" ]
  echo change >> "$d/seed.txt"
  h3="$(wl 'fleet_watch_hash "'"$d"'"')"
  [ "$h1" != "$h3" ]
}

@test "stalled only when unchanged AND past the threshold" {
  run wl 'fleet_watch_stalled A A 100 1000 900'; [ "$status" -eq 0 ]   # 900s elapsed, same hash
  run wl 'fleet_watch_stalled A A 100 200 900';  [ "$status" -ne 0 ]   # only 100s
  run wl 'fleet_watch_stalled A B 100 1000 900'; [ "$status" -ne 0 ]   # hash changed
}

@test "cycle needs a repeated oscillation, not one return" {
  f="$FLEET_TMP/h"
  wl 'fleet_watch_cycle "'"$f"'" A' || true
  wl 'fleet_watch_cycle "'"$f"'" B' || true
  run wl 'fleet_watch_cycle "'"$f"'" A'      # A,B,A — one return, not yet a loop
  [ "$status" -ne 0 ]
  wl 'fleet_watch_cycle "'"$f"'" B' || true
  run wl 'fleet_watch_cycle "'"$f"'" A'      # A,B,A,B,A — now it is oscillating
  [ "$status" -eq 0 ]
}

@test "over_budget past the cap" {
  run wl 'fleet_watch_over_budget 0 2700 2700'; [ "$status" -eq 0 ]
  run wl 'fleet_watch_over_budget 0 100 2700';  [ "$status" -ne 0 ]
}
@test "a digest that keeps recurring among changing ones is a loop" {
  # What a looping local model looks like: it moves — new output every sample —
  # but keeps arriving back at a screen it has already rendered.
  h="$FLEET_TMP/screens"
  for d in a b c a b c a; do
    run bash -c '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_screen_loop '"$h $d 8 3"
  done
  [ "$status" -eq 0 ]
}

@test "a frozen screen is not a loop" {
  # Every sample identical means nothing is happening at all — that is idle or
  # stalled, and answering it with the loop ladder would mislabel it.
  h="$FLEET_TMP/screens"
  for _ in 1 2 3 4 5; do
    run bash -c '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_screen_loop '"$h same 8 3"
  done
  [ "$status" -ne 0 ]
}

@test "steady new output is not a loop" {
  h="$FLEET_TMP/screens"
  for d in a b c d e f g; do
    run bash -c '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_screen_loop '"$h $d 8 3"
  done
  [ "$status" -ne 0 ]
}

@test "a repeat that has scrolled out of the window is forgotten" {
  h="$FLEET_TMP/screens"
  for d in a b c d e f g h i j k a; do
    run bash -c '. "$REPO_ROOT/bin/fleet-watch-lib"; fleet_watch_screen_loop '"$h $d 4 3"
  done
  [ "$status" -ne 0 ]
}

@test "a state that persists is one visit, not a loop" {
  # m001 was parked at fix for this: three consecutive samples of an unchanged
  # tree, with older different values still in the window, counted as three
  # returns. Steady work is not an oscillation.
  f="$FLEET_TMP/h"
  for v in P Q R S S S; do wl 'fleet_watch_cycle "'"$f"'" '"$v" || true; done
  run wl 'fleet_watch_cycle "'"$f"'" S'
  [ "$status" -ne 0 ]
}

@test "text after the last prompt marker is an operator's draft" {
  run wl 'fleet_watch_human_draft "$(printf %s\\n "some output" "❯ I am not sure I")"'
  [ "$status" -eq 0 ]
}

@test "a bare prompt marker is not a draft" {
  run wl 'fleet_watch_human_draft "$(printf %s\\n "some output" "❯ ")"'
  [ "$status" -ne 0 ]
}

@test "only the last prompt line counts — earlier ones are scrollback" {
  # Every turn the operator has ever typed is still on screen. Judging the pane
  # by any of those would make a busy terminal permanently "occupied".
  run wl 'fleet_watch_human_draft "$(printf %s\\n "❯ an earlier question" "the agent answered" "❯")"'
  [ "$status" -ne 0 ]
}

@test "a screen with no prompt marker at all is not a draft" {
  # Unknown TUI: say nothing rather than guess, and leave detection as it was.
  run wl 'fleet_watch_human_draft "$(printf %s\\n "working on it" "no prompt here")"'
  [ "$status" -ne 0 ]
}

@test "an empty screen is not a draft" {
  run wl 'fleet_watch_human_draft ""'
  [ "$status" -ne 0 ]
}
