setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  # The example roles now bunker the executor role by default, so a real spawn
  # of an executor stage (execute/fix) needs a registered repo path or
  # fleet-spawn blocks on "no-repo-path" before the pipeline ever advances.
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode local-merge >/dev/null
}
teardown() { fleet_teardown_home; }

stage_of() { jq -r .stage "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
wt_of() { jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

# Simulate a stage agent finishing: (optionally drop findings.json) then mark done.
finish() {  # <id> [findings-result]
  [ -n "${2:-}" ] && echo "{\"result\":\"$2\",\"findings\":[]}" > "$(wt_of "$1")/findings.json"
  "$REPO_ROOT/bin/fleet-done" "$1" done
  "$REPO_ROOT/bin/fleet-advance" "$1" >/dev/null
}

@test "campaign runs spec->plan->execute->review(PASS)->ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc "add login" --id m001 >/dev/null
  [ "$(stage_of m001)" = "spec" ]
  finish m001;         [ "$(stage_of m001)" = "plan" ]
  finish m001;         [ "$(stage_of m001)" = "execute" ]
  finish m001;         [ "$(stage_of m001)" = "review" ]
  finish m001 PASS;    [ "$(stage_of m001)" = "ready" ]
  # the journal recorded each transition
  grep -q "advance" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "campaign review FAIL loops through fix then PASS to ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m002 >/dev/null
  finish m002; finish m002; finish m002              # spec->plan->execute->review
  [ "$(stage_of m002)" = "review" ]
  finish m002 FAIL                       # review FAIL -> fix
  [ "$(stage_of m002)" = "fix" ]
  [ "$(jq -r .fix_round "$FLEET_STATE_OVERRIDE/missions/m002/mission.json")" = "1" ]
  finish m002                            # fix done -> review
  [ "$(stage_of m002)" = "review" ]
  finish m002 PASS                       # review PASS -> ready
  [ "$(stage_of m002)" = "ready" ]
}

@test "each spawned stage created an orca terminal" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id m003 >/dev/null
  finish m003; finish m003
  # spec-mission created worktree; plan+execute spawns created terminals
  [ "$(grep -c $'terminal\x1fcreate' "$FLEET_ORCA_LOG")" -ge 2 ]
}

@test "watcher ticks drive campaign spec->plan->execute->review(PASS)->ready" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id t1 >/dev/null
  wt="$(wt_of t1)"; fleet_git_init "$wt"
  tick() { "$REPO_ROOT/bin/fleet-watch" --tick; }
  fin() { "$REPO_ROOT/bin/fleet-done" t1 done; }
  fin; tick; [ "$(stage_of t1)" = "plan" ]
  fin; tick; [ "$(stage_of t1)" = "execute" ]
  fin; tick; [ "$(stage_of t1)" = "review" ]
  echo '{"result":"PASS","findings":[]}' > "$wt/findings.json"; fin; tick
  [ "$(stage_of t1)" = "ready" ]
}

@test "persistently dead agent restarts once then parks" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id t2 >/dev/null
  fleet_git_init "$(wt_of t2)"
  jq '.terminal="term_dead"' "$FLEET_STATE_OVERRIDE/missions/t2/mission.json" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$FLEET_STATE_OVERRIDE/missions/t2/mission.json"
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(jq -r .restarts "$FLEET_STATE_OVERRIDE/missions/t2/mission.json")" = "1" ]
  FLEET_FAKE_TERM_GONE=1 "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of t2)" = "parked" ]
  grep -q "watch-park" "$FLEET_STATE_OVERRIDE/journal.log"
}

@test "block -> decision record -> answer(resume) -> back in flight" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc x --id b1 >/dev/null
  fleet_git_init "$(wt_of b1)"
  "$REPO_ROOT/bin/fleet-done" b1 done; "$REPO_ROOT/bin/fleet-watch" --tick    # spec -> plan
  "$REPO_ROOT/bin/fleet-done" b1 "blocked:need creds"; "$REPO_ROOT/bin/fleet-watch" --tick
  [ "$(stage_of b1)" = "blocked" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | head -1 | cut -f1)"
  "$REPO_ROOT/bin/fleet-decision" answer "$did" resume
  [ "$(stage_of b1)" = "plan" ]   # resumed from last_stage
}

@test "review PASS -> approval decision -> answer ship -> merged & done" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id sh1 >/dev/null
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree sh1)"
  jq --arg wt "$wt" '.stage="review" | .worktree_path=$wt' "$(mj sh1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj sh1)"
  echo '{"result":"PASS"}' > "$wt/findings.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  before="$(git -C "$repo" rev-parse main)"
  "$REPO_ROOT/bin/fleet-done" sh1 done; "$REPO_ROOT/bin/fleet-watch" --tick   # advance: PASS -> ready + decision
  [ "$(stage_of sh1)" = "ready" ]
  did="$("$REPO_ROOT/bin/fleet-decision" list --open | grep sh1 | head -1 | cut -f1)"
  "$REPO_ROOT/bin/fleet-decision" answer "$did" ship
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]     # shipped
  [ "$(stage_of sh1)" = "done" ]
}
@test "night: queue two, cap 1 runs one, freed slot runs next, debrief reports" {
  "$REPO_ROOT/bin/fleet-night" start --cap 1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc a --id n1 >/dev/null
  "$REPO_ROOT/bin/fleet-mission" --type recon --project acme --repo id:r --desc b --id n2 >/dev/null
  fleet_git_init "$(wt_of n1)"; fleet_git_init "$(wt_of n2)"
  "$REPO_ROOT/bin/fleet-night" queue --mission n1
  "$REPO_ROOT/bin/fleet-night" queue --mission n2
  "$REPO_ROOT/bin/fleet-watch" --tick                  # pump starts n1 (cap 1)
  [ "$(jq -r .terminal "$(mj n1)")" != "null" ]
  [ "$(jq -r .terminal "$(mj n2)")" = "null" ]
  jq '.stage="done"' "$(mj n1)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj n1)"   # n1 finishes
  "$REPO_ROOT/bin/fleet-watch" --tick                  # freed slot -> n2 starts
  [ "$(jq -r .terminal "$(mj n2)")" != "null" ]
  run "$REPO_ROOT/bin/fleet-night" debrief
  [[ "$output" == *"completed:"*"n1"* ]]
}

@test "bunkered executor launches through airlock; ship stays host-side" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"                    # loadout ready (fake airlock status=ready)
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id bk1 >/dev/null
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/bk1/mission.json")"
  run "$REPO_ROOT/bin/fleet-spawn" --mission bk1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"airlock -C $wt -- "* ]]     # executor bunkered, in its own worktree
  # the frontier plan stage is NOT bunkered (executor-only v1)
  run "$REPO_ROOT/bin/fleet-spawn" --mission bk1 --stage plan --dry-run
  [[ "$output" != *"airlock"* ]]
}