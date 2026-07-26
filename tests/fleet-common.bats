setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

@test "fleet_roots sets and creates state dir from overrides" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; echo "$FLEET_STATE"; [ -d "$FLEET_STATE/missions" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == "$FLEET_STATE_OVERRIDE" ]]
}

@test "fleet_json_get/set round-trips a value" {
  f="$FLEET_TMP/x.json"; echo '{"stage":"spec"}' > "$f"
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_json_set "'"$f"'" ".stage=\"plan\""; fleet_json_get "'"$f"'" ".stage"'
  [ "$status" -eq 0 ]
  [[ "$output" == "plan" ]]
}

@test "fleet_next_id increments" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; echo "$(fleet_next_id)$(fleet_next_id)"'
  [ "$status" -eq 0 ]
  [[ "$output" == "m001m002" ]]
}

@test "fleet_journal appends a tab-separated line" {
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; fleet_roots; fleet_journal spawn "m001 spec"; cat "$FLEET_STATE/journal.log"'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"spawn"$'\t'"m001 spec"* ]]
}