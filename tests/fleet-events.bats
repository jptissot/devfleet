setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id e1 >/dev/null
}
teardown() { fleet_teardown_home; }

ev() {
  bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-events"; fleet_roots; '"$1"
}
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "append writes one JSON object per line" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 anomaly stalled'
  f="$FLEET_STATE_OVERRIDE/missions/e1/events"
  [ "$(wc -l < "$f" | tr -d ' ')" = "2" ]
  [ "$(head -n1 "$f" | jq -r .kind)" = "marker" ]
  [ "$(head -n1 "$f" | jq -r .detail)" = "done" ]
  [ "$(tail -n1 "$f" | jq -r .detail)" = "stalled" ]
  [ -n "$(head -n1 "$f" | jq -r .ts)" ]
}

@test "count is 0 before any event" {
  run ev 'fleet_events_count e1'
  [ "$output" = "0" ]
}

@test "unread respects the cursor and ack advances it" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 marker blocked:why'
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "2" ]
  ev 'fleet_events_ack e1'
  [ "$(jq -r .event_cursor "$(mj e1)")" = "2" ]
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "0" ]
  ev 'fleet_events_append e1 anomaly stalled'
  run ev 'fleet_events_unread e1 | jq -r .detail'; [ "$output" = "stalled" ]
}

@test "ack with an explicit count is honored" {
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_append e1 marker done'
  ev 'fleet_events_ack e1 1'
  run ev 'fleet_events_unread e1 | wc -l | tr -d " "'; [ "$output" = "1" ]
}

@test "unread on a mission with no events prints nothing" {
  run ev 'fleet_events_unread e1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}