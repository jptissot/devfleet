setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
}
teardown() { fleet_teardown_home; }

mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }
mk() { "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc x --id "$1" >/dev/null; }

@test "terminal states are recorded with a reason" {
  mk t1
  run "$REPO_ROOT/bin/fleet-drive" state --mission t1 --set blocked --reason "needs a key"
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t1)")" = "blocked" ]
  grep -q "needs a key" "$FLEET_STATE_OVERRIDE/missions/t1/events"
}

@test "an unknown state is refused" {
  mk t2
  run "$REPO_ROOT/bin/fleet-drive" state --mission t2 --set shipping
  [ "$status" -ne 0 ]
  [ "$(jq -r .stage "$(mj t2)")" = "driving" ]
}

@test "ready opens a ship decision when the repo is attended" {
  mk t3
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode report-only >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" state --mission t3 --set ready
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t3)")" = "ready" ]
  run "$REPO_ROOT/bin/fleet-decision" list --open
  [[ "$output" == *"t3"* ]]
  [[ "$output" == *"ship"* ]]
}

@test "ready auto-ships an unattended repo" {
  mk t4
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree t4)"
  jq --arg wt "$wt" '.worktree_path=$wt' "$(mj t4)" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$(mj t4)"
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$repo" \
    --default-branch main --forge github --ship-mode local-merge --unattended >/dev/null
  run "$REPO_ROOT/bin/fleet-drive" state --mission t4 --set ready
  [ "$status" -eq 0 ]
  [ "$(jq -r .stage "$(mj t4)")" = "done" ]
  [ "$(jq -r '.ship.mode' "$(mj t4)")" = "local-merge" ]
}