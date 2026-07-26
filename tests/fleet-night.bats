setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

@test "start sets night mode, cap, and an empty queue" {
  run "$REPO_ROOT/bin/fleet-night" start --cap 2
  [ "$status" -eq 0 ]
  [ -f "$FLEET_STATE_OVERRIDE/.night" ]
  [ "$(cat "$FLEET_STATE_OVERRIDE/.night-cap")" = "2" ]
  [ -f "$FLEET_STATE_OVERRIDE/queue" ]
}

@test "end clears night mode" {
  "$REPO_ROOT/bin/fleet-night" start >/dev/null
  run "$REPO_ROOT/bin/fleet-night" end
  [ "$status" -eq 0 ]
  [ ! -f "$FLEET_STATE_OVERRIDE/.night" ]
}

@test "start defaults cap to 1 and does not truncate an existing queue" {
  echo m001 > "$FLEET_STATE_OVERRIDE/queue"
  "$REPO_ROOT/bin/fleet-night" start >/dev/null
  [ "$(cat "$FLEET_STATE_OVERRIDE/queue")" = "m001" ]
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-night"; fleet_roots; fleet_night_cap'
  [ "$output" = "1" ]
}

@test "queue admits a strike with an issue and a recon" {
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 42 --id q1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon  --project acme --repo id:r --desc "why slow" --id q2 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission q1
  "$REPO_ROOT/bin/fleet-night" queue --mission q2
  run cat "$FLEET_STATE_OVERRIDE/queue"
  [[ "$output" == *"q1"* ]]
  [[ "$output" == *"q2"* ]]
}

@test "queue admits a fortify mission" {
  "$REPO_ROOT/bin/fleet-mission" --type fortify --project acme --repo id:r --desc "harden ingress" --id q5 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission q5
  run grep -c q5 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "1" ]
}

@test "queue rejects a campaign with no spec (no unattended brainstorming)" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id q3 >/dev/null
  run "$REPO_ROOT/bin/fleet-night" queue --mission q3
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec"* ]]
  : > "$FLEET_STATE_OVERRIDE/queue"
  run grep -c q3 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "0" ]
}

@test "queue admits a campaign that has a spec" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --spec docs/s.md --id q4 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission q4
  run grep -c q4 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "1" ]
}
@test "queue rejects a strike with no issue" {
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --id q6 >/dev/null
  run "$REPO_ROOT/bin/fleet-night" queue --mission q6
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue"* ]]
  : > "$FLEET_STATE_OVERRIDE/queue"
  run grep -c q6 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "0" ]
}

@test "queue rejects a mission with an unknown type" {
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc x --id q7 >/dev/null
  jq --arg t 'bogus' '.type=$t' "$(mj q7)" > "$(mj q7).tmp" && mv "$(mj q7).tmp" "$(mj q7)"
  run "$REPO_ROOT/bin/fleet-night" queue --mission q7
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown type"* ]]
  : > "$FLEET_STATE_OVERRIDE/queue"
  run grep -c q7 "$FLEET_STATE_OVERRIDE/queue"
  [ "$output" = "0" ]
}
@test "pump starts up to cap missions and leaves the rest queued" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id p1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id p2 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission p1
  "$REPO_ROOT/bin/fleet-night" queue --mission p2
  "$REPO_ROOT/bin/fleet-night" pump
  [ "$(jq -r .terminal "$(mj p1)")" != "null" ]   # p1 started
  [ "$(jq -r .terminal "$(mj p2)")" = "null" ]    # p2 held (cap 1)
  [ "$(cat "$FLEET_STATE_OVERRIDE/queue")" = "p2" ]
}

@test "pump pulls the next mission once a slot frees" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id p3 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id p4 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission p3
  "$REPO_ROOT/bin/fleet-night" queue --mission p4
  "$REPO_ROOT/bin/fleet-night" pump                       # starts p3
  jq '.stage="done"' "$(mj p3)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj p3)"   # p3 frees its slot
  "$REPO_ROOT/bin/fleet-night" pump                       # now starts p4
  [ "$(jq -r .terminal "$(mj p4)")" != "null" ]
  [ ! -s "$FLEET_STATE_OVERRIDE/queue" ]                  # queue drained
}
@test "pump re-queues a mission when spawn fails" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id rf1 >/dev/null
  "$REPO_ROOT/bin/fleet-night" queue --mission rf1
  mv "$REPO_ROOT/bin/fleet-spawn" "$REPO_ROOT/bin/fleet-spawn.bak"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO_ROOT/bin/fleet-spawn"
  chmod +x "$REPO_ROOT/bin/fleet-spawn"
  "$REPO_ROOT/bin/fleet-night" pump >/dev/null 2>&1 || true
  mv "$REPO_ROOT/bin/fleet-spawn.bak" "$REPO_ROOT/bin/fleet-spawn"
  [ "$(cat "$FLEET_STATE_OVERRIDE/queue")" = "rf1" ]
  grep -q night-pump-fail "$FLEET_STATE_OVERRIDE/journal.log"
}
@test "debrief buckets missions by outcome" {
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id d1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc b --id d2 >/dev/null
  jq '.stage="done" | .ship={mode:"local-merge",result:"merged",at:"now"}' "$(mj d1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj d1)"
  jq '.stage="parked"' "$(mj d2)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj d2)"
  run "$REPO_ROOT/bin/fleet-night" debrief
  [ "$status" -eq 0 ]
  [[ "$output" == *"shipped:"*"d1"* ]]
  [[ "$output" == *"parked:"*"d2"* ]]
}

@test "end prints the debrief and clears night mode" {
  run "$REPO_ROOT/bin/fleet-night" end
  [ "$status" -eq 0 ]
  [[ "$output" == *"shipped:"* ]]
  [ ! -f "$FLEET_STATE_OVERRIDE/.night" ]
}
@test "commander-driven missions are never admitted to the night queue" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id n9 >/dev/null
  run "$REPO_ROOT/bin/fleet-night" queue --mission n9
  [ "$status" -ne 0 ]
  [[ "$output" == *"commander-driven"* ]]
  [ ! -s "$FLEET_STATE_OVERRIDE/queue" ] || ! grep -q n9 "$FLEET_STATE_OVERRIDE/queue"
}
