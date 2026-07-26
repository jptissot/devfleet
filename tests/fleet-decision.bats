setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m1 >/dev/null
}
teardown() { fleet_teardown_home; }

@test "create writes a record and returns an id" {
  run "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key"
  [ "$status" -eq 0 ]
  [[ "$output" == d1* ]]
  rec="$FLEET_STATE_OVERRIDE/decisions/d1.json"
  [ "$(jq -r .status "$rec")" = "open" ]
  [ "$(jq -r .mission "$rec")" = "m1" ]
  [ "$(jq -r .project "$rec")" = "acme" ]
  [ "$(jq -r .question "$rec")" = "need a key" ]
}

@test "create dedups an open record for the same mission+stage" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "x" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "x again"
  [ "$output" = "d1" ]   # same id, not d2
  [ ! -f "$FLEET_STATE_OVERRIDE/decisions/d2.json" ]
}

@test "list --open shows open records; footer summarizes them" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "need a key" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"d1"* ]]
  [[ "$output" == *"need a key"* ]]
  run "$REPO_ROOT/bin/fleet-decision" footer
  [[ "$output" == *"1 pending"* ]]
  [[ "$output" == *"[d1]"* ]]
}

@test "options parse into the record" {
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "merge?" \
    --option "yes:Merge:fast-forward" --option "no:Hold:leave it" >/dev/null
  rec="$FLEET_STATE_OVERRIDE/decisions/d1.json"
  [ "$(jq -r '.options[0].key' "$rec")" = "yes" ]
  [ "$(jq -r '.options[1].label' "$rec")" = "Hold" ]
}

@test "answer resume un-parks the mission from last_stage and respawns" {
  # drive m1 to parked at 'plan'
  jq '.stage="parked" | .last_stage="plan"' "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage plan --question "parked" >/dev/null
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-decision" answer d1 resume
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "answered" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m1/mission.json")" = "plan" ]   # back in flight
  orca_log_has $'orca\x1fterminal\x1fcreate'                                        # respawned
}

@test "resume stops the old (blocked) terminal before respawning" {
  jq '.stage="parked" | .last_stage="plan" | .terminal="term_old"' \
    "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage plan --question "parked" >/dev/null
  : > "$FLEET_ORCA_LOG"
  run "$REPO_ROOT/bin/fleet-decision" answer d1 resume
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fclose\x1f--terminal\x1fterm_old'   # old agent killed
  orca_log_has $'orca\x1fterminal\x1fcreate'                          # then respawned
}

@test "answer ship applies the repo ship mode and marks the mission done" {
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree m1)"
  jq --arg wt "$wt" '.stage="ready" | .worktree_path=$wt' "$FLEET_STATE_OVERRIDE/missions/m1/mission.json" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/m1/mission.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  before="$(git -C "$repo" rev-parse main)"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "ship?" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 ship
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]
  [ "$(jq -r .stage "$FLEET_STATE_OVERRIDE/missions/m1/mission.json")" = "done" ]
}

@test "a non-resume answer marks answered and wakes the Commander" {
  echo term_cmd > "$FLEET_STATE_OVERRIDE/.commander-terminal"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage review --question "merge?" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 "yes, merge"
  [ "$status" -eq 0 ]
  [ "$(jq -r .answer "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "yes, merge" ]
  orca_log_has $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm_cmd'
}

@test "answer init scaffolds the repo loadout" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge gitea --ship-mode direct-PR >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "repo id:r has no built loadout — init now?" --option "init:init loadout:scaffold" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 init
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "answered" ]
  bunker_log_has $'airlock\x1f-C\x1f'"$FLEET_TMP/repo"$'\x1finit\x1f--yes'  # fleet-loadout init ran
}
@test "answer init reports failure when the loadout scaffold fails" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge gitea --ship-mode direct-PR >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "loadout?" >/dev/null
  FLEET_FAKE_LOADOUT_INIT_FAIL=1 run "$REPO_ROOT/bin/fleet-decision" answer d1 init
  [ "$status" -eq 0 ]
  grep -q $'\tloadout-scaffold-fail\t' "$FLEET_STATE_OVERRIDE/journal.log"
  ! grep -q $'\tloadout-scaffold\t' "$FLEET_STATE_OVERRIDE/journal.log"
}
