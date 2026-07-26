setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

# Run a fleet_session_* function with cwd set to $1.
sess() { local d=$1; shift; ( cd "$d" && bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; '"$*" ); }

@test "a mission worktree with a brief is execute mode" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m1)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m1.spec.brief"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = execute ]
}

@test "execute wins even when FLEET_HOME points at a real fleet root" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m2)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m2.plan.brief"
  # fleet_setup_home exports FLEET_HOME at the seeded fleet root and the subshell
  # inherits it — exactly the inheritance detection must not be fooled by.
  [ -d "$FLEET_HOME" ]
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = execute ]
}

@test "the brief file path is reported" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m3)"
  mkdir -p "$wt/.devfleet"; : > "$wt/.devfleet/m3.review.brief"
  run sess "$wt" 'fleet_session_brief_file'
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3.review.brief" ]]
}

@test "a linked worktree with no brief is orphan mode" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m4)"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 3 ]
  [ "$output" = orphan ]
}

@test "a worktree of devfleet itself is root mode, not an orphan" {
  # Develop-mode work belongs on a branch in a worktree, and the first thing
  # CLAUDE.md tells you to run is fleet-session-start. Judging by linkedness
  # alone refused it: a devfleet dev worktree is a linked worktree with no
  # brief, exactly like a stray mission worktree. What separates them is that
  # this one *is* a fleet — it carries the machine and the mission graphs.
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m6)"
  mkdir -p "$wt/bin" "$wt/config/missions"
  : > "$wt/bin/fleet-session-start"; chmod +x "$wt/bin/fleet-session-start"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = root ]
}

@test "a brief still wins over a devfleet-shaped worktree" {
  # An executor's worktree could contain anything, including a checkout of the
  # fleet. The brief is the stronger signal and must not be overridden.
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m7)"
  mkdir -p "$wt/bin" "$wt/config/missions" "$wt/.devfleet"
  : > "$wt/bin/fleet-session-start"; chmod +x "$wt/bin/fleet-session-start"
  : > "$wt/.devfleet/m7.execute.brief"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = execute ]
}

@test "a half-shaped worktree is still an orphan" {
  # bin/fleet-session-start alone is not a fleet: the mission graphs are what
  # make the difference between a checkout and a stray directory that happens
  # to hold a script with the right name.
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m8)"
  mkdir -p "$wt/bin"
  : > "$wt/bin/fleet-session-start"; chmod +x "$wt/bin/fleet-session-start"
  run sess "$wt" 'fleet_session_mode'
  [ "$status" -eq 3 ]
  [ "$output" = orphan ]
}

@test "the main checkout is root mode" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m5)"
  run sess "$repo" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = root ]
}

@test "a directory that is not a git repo at all is root mode" {
  mkdir -p "$FLEET_TMP/plain"
  run sess "$FLEET_TMP/plain" 'fleet_session_mode'
  [ "$status" -eq 0 ]
  [ "$output" = root ]
}

@test "the executor briefing names the mission, the stage, and fleet-done" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_execute /w/.devfleet/m9.review.brief'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the Commander"* ]]
  [[ "$output" == *"m9"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"fleet-done m9"* ]]
  [[ "$output" != *"you are the Commander of this fleet"* ]]
}

@test "the root briefing names both modes and the announce rule" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_root 0 0 "reconciled 0 missions, 0 drifted"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"operate"* ]]
  [[ "$output" == *"develop"* ]]
  [[ "$output" == *"END YOUR TURN"* ]]
  [[ "$output" == *"Announce the inference"* ]]
  [[ "$output" == *"reconciled 0 missions, 0 drifted"* ]]
}

@test "the root briefing renders live counts" {
  run bash -c '. "$REPO_ROOT/bin/fleet-session-lib"; fleet_session_brief_root 2 1 "reconciled 2 missions, 0 drifted"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 missions in flight"* ]]
  [[ "$output" == *"1 open decisions"* ]]
  [[ "$output" != *"idle"* ]]
}
