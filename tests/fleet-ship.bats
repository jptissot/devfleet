setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }
mj() { echo "$FLEET_STATE_OVERRIDE/missions/$1/mission.json"; }

# Create a mission, then repoint it at a real repo+worktree and register the repo.
seed_shipping_mission() {  # <id> <ship-mode> [--unattended]
  local id=$1 mode=$2; shift 2
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project acme --repo id:r --desc x --id "$id" >/dev/null
  IFS=$'\t' read -r repo wt <<<"$(fleet_make_repo_worktree "$id")"
  jq --arg wt "$wt" '.worktree_path=$wt | .orca_worktree_id="id:r::x"' "$(mj "$id")" > "$FLEET_TMP/t" \
    && mv "$FLEET_TMP/t" "$(mj "$id")"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r \
    --path "$repo" --default-branch main --forge github --ship-mode "$mode" "$@" >/dev/null
  echo "$repo"
}

@test "local-merge fast-forwards the branch into main and marks the mission done" {
  repo="$(seed_shipping_mission s1 local-merge)"
  before="$(git -C "$repo" rev-parse main)"
  run "$REPO_ROOT/bin/fleet-ship" s1
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" != "$before" ]     # main advanced
  [ "$(jq -r .stage "$(mj s1)")" = "done" ]
  [ "$(jq -r .ship.mode "$(mj s1)")" = "local-merge" ]
}

@test "direct-PR calls the forge and records the PR url" {
  fleet_install_fake_forge
  seed_shipping_mission s2 direct-PR >/dev/null
  run "$REPO_ROOT/bin/fleet-ship" s2
  [ "$status" -eq 0 ]
  forge_log_has $'gh\x1fpr\x1fcreate'
  [[ "$(jq -r .ship.result "$(mj s2)")" == *"forge.example/pr/1"* ]]
  [ "$(jq -r .stage "$(mj s2)")" = "done" ]
}

@test "report-only records a manual note without touching git history" {
  repo="$(seed_shipping_mission s3 report-only)"
  before="$(git -C "$repo" rev-parse main)"
  run "$REPO_ROOT/bin/fleet-ship" s3
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse main)" = "$before" ]      # untouched
  [ "$(jq -r .ship.mode "$(mj s3)")" = "report-only" ]
  [ "$(jq -r .stage "$(mj s3)")" = "done" ]
}
@test "local-merge refuses when the repo is off its default branch" {
  repo="$(seed_shipping_mission g1 local-merge)"
  git -C "$repo" checkout -q -b sidetrack     # repo no longer on main
  run "$REPO_ROOT/bin/fleet-ship" g1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on main"* ]]
  [ "$(jq -r .stage "$(mj g1)")" != "done" ]  # nothing shipped
}