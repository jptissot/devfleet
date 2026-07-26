setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

bp() { echo "$REPO_ROOT/config/missions/blueprint.json"; }

@test "blueprint declares what it is for" {
  [ -n "$(jq -r '.description // ""' "$(bp)")" ]
  [ -n "$(jq -r '.when_to_use // ""' "$(bp)")" ]
}

@test "the interview stage is interactive and the others are not" {
  [ "$(jq -r '.stages[] | select(.name=="blueprint") | .interactive' "$(bp)")" = true ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .interactive // false' "$(bp)")" = false ]
  [ "$(jq -r '.stages[] | select(.name=="refine") | .interactive // false' "$(bp)")" = false ]
}

@test "refine runs on frontier, not executor" {
  # Deliberate divergence from campaign, where fix is the executor. Revising a
  # spec is judgment work and the executor's brief is code-shaped.
  [ "$(jq -r '.stages[] | select(.name=="refine") | .role' "$(bp)")" = frontier ]
}

@test "the review stage carries the review contract" {
  [ "$(jq -r '.stages[] | select(.name=="review") | .review' "$(bp)")" = true ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .on_pass' "$(bp)")" = ready ]
  [ "$(jq -r '.stages[] | select(.name=="review") | .on_fail' "$(bp)")" = refine ]
}

@test "the mission cap leaves room for review and refine after a maximal interview" {
  # The invariant: interactive stage cap < mission cap <= ceiling. Equal caps
  # would kill a mission for succeeding slowly.
  mission="$(jq -r '.max_mission_seconds' "$(bp)")"
  [ "$mission" -gt 14400 ]
  ceiling="$(bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_pipeline_ceiling max_mission_seconds')"
  [ "$mission" -le "$ceiling" ]
}

@test "every stage's prompt file exists" {
  while read -r p; do
    [ -n "$p" ] || continue
    [ -f "$REPO_ROOT/prompts/$p" ] || { echo "missing prompt: $p"; false; }
  done < <(jq -r '.stages[].prompt // empty' "$(bp)")
}

@test "blueprint validates" {
  run "$REPO_ROOT/bin/fleet-config" validate
  [ "$status" -eq 0 ]
}

@test "every next, on_pass and on_fail names a real stage or a state word" {
  names="$(jq -r '.stages[].name' "$(bp)")"
  while read -r t; do
    [ -n "$t" ] || continue
    case "$t" in ready|done|parked|blocked|failed) continue ;; esac
    printf '%s\n' "$names" | grep -qx "$t" || { echo "dangling target: $t"; false; }
  done < <(jq -r '.stages[] | (.next // empty), (.on_pass // empty), (.on_fail // empty)' "$(bp)")
}
