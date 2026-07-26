setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
  fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "status_ready returns 0 when runtime reachable" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_status_ready'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fstatus\x1f--json'
}

@test "ORCA_BIN overrides the orca binary name (e.g. orca-ide)" {
  # A fake binary under a different name; prove the backend invokes IT.
  cat > "$FAKEBIN/orca-ide" <<'ALT'
#!/usr/bin/env bash
set -u
{ printf 'orca-ide'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_ORCA_LOG"
printf '{"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
ALT
  chmod +x "$FAKEBIN/orca-ide"
  ORCA_BIN=orca-ide run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_status_ready'
  [ "$status" -eq 0 ]
  orca_log_has $'orca-ide\x1fstatus\x1f--json'
  # No line is the literal `orca` (field sep right after the name, not `orca-ide`).
  ! grep -q $'^orca\x1f' "$FLEET_ORCA_LOG"
}

@test "worktree_create returns id and path, tab-joined, and calls orca correctly" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_worktree_create id:repo1 fleet-m001'
  [ "$status" -eq 0 ]
  id="${output%%$'\t'*}"; path="${output#*$'\t'}"
  [[ "$id" == "repo1::"* ]]
  [ -d "$path" ]
  orca_log_has $'orca\x1fworktree\x1fcreate\x1f--repo\x1fid:repo1\x1f--name\x1ffleet-m001\x1f--no-parent\x1f--setup\x1fskip\x1f--json'
}

@test "terminal_create returns a handle" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_create "r::/w" title "claude"'
  [ "$status" -eq 0 ]
  [[ "$output" == term_* ]]
}

@test "terminal_enter uses --enter not --key" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_enter term_001'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_001\x1f--enter'
  ! orca_log_has '--key'
}

@test "terminal_idle reports satisfied and blockedReason" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_idle term_001 5000'
  [ "$status" -eq 0 ]
  [[ "$output" == "true"$'\t'"null" ]]
}

@test "terminal_exists reflects the fake gone flag" {
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_1'
  [ "$status" -eq 0 ]
  FLEET_FAKE_TERM_GONE=1 run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_1'
  [ "$status" -ne 0 ]
}

@test "terminal_state emits satisfied/blocked/exit" {
  FLEET_FAKE_SAT=false FLEET_FAKE_BLOCKED='"codex-trust-workspace"' \
    run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_state term_1 5000'
  [ "$status" -eq 0 ]
  [[ "$output" == "false"$'\t'"codex-trust-workspace"$'\t'"null" ]]
}

@test "terminal_stop closes by handle, because stop is worktree-scoped" {
  # `orca terminal stop` takes --worktree and answers ok:false to --terminal,
  # while still exiting 0 — so the old call was a no-op that read as success and
  # left the previous agent running beside the one the restart spawned.
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_stop term_1'
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fclose\x1f--terminal\x1fterm_1'
}

@test "terminal_stop reports failure when the terminal outlives the call" {
  FLEET_FAKE_CLOSE_FAIL=1 FLEET_STOP_TRIES=2 run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_stop term_1'
  [ "$status" -ne 0 ]
}

@test "terminal_stop waits out a close that has not landed yet" {
  # close is asynchronous: the terminal answers one more read before it goes.
  # Checking once and calling it a failure parks missions whose agent did stop —
  # which is exactly what happened to m001 at review.
  FLEET_FAKE_CLOSE_LAG=2 run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_stop term_1'
  [ "$status" -eq 0 ]
}

@test "terminal_stop treats an already-gone terminal as stopped" {
  FLEET_FAKE_TERM_GONE=1 run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_stop term_1'
  [ "$status" -eq 0 ]
}

@test "terminal_self resolves this session's handle from ORCA_PANE_KEY" {
  # ORCA_PANE_KEY is "<tabId>:<leafId>", and terminal list carries both. Without
  # this the Commander cannot name its own terminal, and every wake it is sent
  # falls into .wake-pending unread.
  run bash -c 'export ORCA_PANE_KEY=tab_2:leaf_2; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_self'
  [ "$status" -eq 0 ]
  [ "$output" = "term_002" ]
}

@test "terminal_self is empty when the pane key matches nothing" {
  run bash -c 'export ORCA_PANE_KEY=tab_9:leaf_9; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_self'
  [ -z "$output" ]
}

@test "terminal_self is empty outside an orca pane" {
  run bash -c 'unset ORCA_PANE_KEY; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_self'
  [ -z "$output" ]
}

@test "agent_state reads orca's hook feed for a terminal's pane" {
  # Orca's agent hooks report state directly — "working" or "done" — instead of
  # us inferring it from a screen that stopped changing.
  cat > "$FLEET_TMP/hooks.json" <<'JSON'
{"version":1,"entries":{
  "tab_1:leaf_1":{"paneKey":"tab_1:leaf_1","payload":{"state":"working"},"stateStartedAt":1000},
  "tab_2:leaf_2":{"paneKey":"tab_2:leaf_2","payload":{"state":"done"},"stateStartedAt":2000}}}
JSON
  run bash -c 'export ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json"; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_agent_state term_002'
  [ "$output" = "done"$'\t'"2000" ]
  run bash -c 'export ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json"; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_agent_state term_001'
  [ "$output" = "working"$'\t'"1000" ]
}

@test "agent_state is empty when the agent does not report" {
  # A bunkered agent cannot reach the hook endpoint on the host, so it has no
  # entry. Empty means "no signal", never "idle" — the caller must fall back.
  printf '{"version":1,"entries":{}}\n' > "$FLEET_TMP/hooks.json"
  run bash -c 'export ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/hooks.json"; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_agent_state term_001'
  [ -z "$output" ]
}

@test "agent_state is empty when there is no hook feed at all" {
  run bash -c 'export ORCA_AGENT_HOOK_STATUS="$FLEET_TMP/nope.json"; . "$REPO_ROOT/bin/fleet-backend"; fleet_backend_agent_state term_001'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "terminal_exists is false for a terminal that has exited but still reads" {
  # orca answers `terminal read` for an exited terminal, so readability is not
  # liveness. m001 parked twice on a stop that could never be confirmed.
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_003'
  [ "$status" -eq 0 ]
  echo term_003 >> "$FLEET_TMP/.term-closed"      # process gone; read still works
  run bash -c '. "$REPO_ROOT/bin/fleet-backend"; fleet_backend_terminal_exists term_003'
  [ "$status" -ne 0 ]
}
