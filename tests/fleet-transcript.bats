setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id m001 >/dev/null
  MJ="$FLEET_STATE_OVERRIDE/missions/m001/mission.json"
  WT="$(jq -r .worktree_path "$MJ")"
  # Two harnesses, two layouts, one worktree. claude mangles the path with single
  # leading dash; omp wraps it in double dashes.
  MANGLED="${WT//\//-}"
  CH="$FLEET_TMP/agenthome/.claude/projects/$MANGLED"
  OH="$FLEET_TMP/agenthome/.omp/agent/sessions/-${MANGLED}--"
  mkdir -p "$CH" "$OH"
  export FLEET_AGENT_HOME="$FLEET_TMP/agenthome"
}
teardown() { fleet_teardown_home; }

@test "finds a claude session for the mission's worktree" {
  echo '{}' > "$CH/aaaa-1111.jsonl"
  run "$REPO_ROOT/bin/fleet-transcript" m001
  [ "$status" -eq 0 ]
  [[ "$output" == *"aaaa-1111.jsonl"* ]]
  [[ "$output" == *"claude"* ]]
}

@test "finds an omp session, which lives somewhere else entirely" {
  # This is the one that cost an hour: an executor is omp, and looking only
  # where claude keeps transcripts says the record does not exist.
  echo '{}' > "$OH/2026-07-25T21-23-10-621Z_019f.jsonl"
  run "$REPO_ROOT/bin/fleet-transcript" m001
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-07-25T21-23-10-621Z_019f.jsonl"* ]]
  [[ "$output" == *"omp"* ]]
}

@test "lists both harnesses, newest last, when a mission used both" {
  echo '{}' > "$CH/aaaa-1111.jsonl";            touch -d '2020-01-01' "$CH/aaaa-1111.jsonl"
  echo '{}' > "$OH/2026-07-25T21-23-10_b.jsonl"; touch -d '2030-01-01' "$OH/2026-07-25T21-23-10_b.jsonl"
  run "$REPO_ROOT/bin/fleet-transcript" m001
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c jsonl)" -eq 2 ]
  [[ "$(printf '%s\n' "$output" | grep jsonl | tail -1)" == *"21-23-10_b"* ]]
}

@test "says so plainly when a mission has no transcript yet" {
  run "$REPO_ROOT/bin/fleet-transcript" m001
  [ "$status" -eq 0 ]
  [[ "$output" == *"no transcript"* ]]
}

@test "an unknown mission is an error, not an empty answer" {
  run "$REPO_ROOT/bin/fleet-transcript" m404
  [ "$status" -ne 0 ]
}

@test "--path prints only paths, for piping into a reader" {
  echo '{}' > "$CH/aaaa-1111.jsonl"
  run "$REPO_ROOT/bin/fleet-transcript" m001 --path
  [ "$status" -eq 0 ]
  [ "$output" = "$CH/aaaa-1111.jsonl" ]
}
