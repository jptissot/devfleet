setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_curl
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id h1 >/dev/null
  MJ="$FLEET_STATE_OVERRIDE/missions/h1/mission.json"
  WT="$(jq -r .worktree_path "$MJ")"
  jq '.terminal="term_001"' "$MJ" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$MJ"
  export ORCA_AGENT_HOOK_ENDPOINT="$FLEET_TMP/endpoint.env"
  printf 'ORCA_AGENT_HOOK_PORT=41999\nORCA_AGENT_HOOK_TOKEN=tok\nORCA_AGENT_HOOK_ENV=production\nORCA_AGENT_HOOK_VERSION=1\n' \
    > "$ORCA_AGENT_HOOK_ENDPOINT"
  mkdir -p "$WT/.devfleet"
}
teardown() { fleet_teardown_home; }
spool() { printf '%s\n' "$1" >> "$WT/.devfleet/orca-hooks.jsonl"; }

@test "a spooled event is posted with the mission's pane key" {
  # The agent cannot post these itself: the receiver is on the host's loopback,
  # and the pane key is the terminal's, which only the host can resolve.
  spool '{"hook_event_name":"PostToolUse"}'
  run "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ "$status" -eq 0 ]
  curl_log_has 'http://127.0.0.1:41999/hook/claude'
  curl_log_has 'X-Orca-Agent-Hook-Token: tok'
  curl_log_has 'paneKey=tab_1:leaf_1'
}

@test "each event is posted once, however often the relay runs" {
  spool '{"hook_event_name":"A"}'
  "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ "$(grep -c 'hook/claude' "$FLEET_CURL_LOG")" = "1" ]
  spool '{"hook_event_name":"B"}'
  "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ "$(grep -c 'hook/claude' "$FLEET_CURL_LOG")" = "2" ]
}

@test "the cursor lives beside the mission, not in the worktree the agent can write" {
  spool '{"hook_event_name":"A"}'
  "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ -f "$FLEET_STATE_OVERRIDE/missions/h1/hook-cursor" ]
  [ ! -e "$WT/.devfleet/hook-cursor" ]
}

@test "no endpoint on this host is not an error" {
  rm -f "$ORCA_AGENT_HOOK_ENDPOINT"
  spool '{"hook_event_name":"A"}'
  run "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ "$status" -eq 0 ]
  [ ! -s "$FLEET_CURL_LOG" ]
}

@test "an empty spool posts nothing" {
  run "$REPO_ROOT/bin/fleet-hooks" relay --mission h1
  [ "$status" -eq 0 ]
  [ ! -s "$FLEET_CURL_LOG" ]
}
