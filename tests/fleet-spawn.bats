setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca; fleet_install_fake_bunker
  # The example roles bunker the executor role by default, so a real
  # (non-dry-run) spawn of an executor stage needs a registered repo path or
  # fleet-spawn blocks on "no-repo-path" before it ever reaches what a test
  # is actually about.
  "$REPO_ROOT/bin/fleet-project" create --name a >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project a --repo id:r --path "$FLEET_TMP/repo" \
    --default-branch main --forge github --ship-mode local-merge >/dev/null
  ID=$("$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc "add login" --id m001)
  MJ="$FLEET_STATE_OVERRIDE/missions/m001/mission.json"
  WT=$(jq -r .worktree_path "$MJ")
}
teardown() { fleet_teardown_home; }

@test "dry-run prints launch command with the harness, mutates no orca state" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude "* ]]
  [ -f "$WT/.devfleet/m001.spec.brief" ]
  ! orca_log_has $'terminal\x1fcreate'
}

@test "brief substitutes mission fields and adds the done footer" {
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  brief="$WT/.devfleet/m001.spec.brief"
  grep -q "mission m001" "$brief"
  grep -q "add login" "$brief"
  grep -q "fleet-done m001" "$brief"
}

@test "executor stage resolves the pi harness" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi "* ]]
}

@test "non-dry spawn creates an orca terminal and records the handle" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec
  [ "$status" -eq 0 ]
  orca_log_has $'orca\x1fterminal\x1fcreate'
  [ "$(jq -r .terminal "$MJ")" = "term_001" ]
}
@test "brief renders safely with shell/sed metacharacters in --desc" {
  "$REPO_ROOT/bin/fleet-mission" --type campaign --project a --repo id:r --desc 'add a|b & c\d' --id m9 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission m9 --stage spec --dry-run
  [ "$status" -eq 0 ]
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/m9/mission.json")"
  grep -qF 'add a|b & c\d' "$wt/.devfleet/m9.spec.brief"
}

@test "a bunkered executor stage enters the mission worktree through airlock (dry-run)" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s1 >/dev/null
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s1/mission.json")"
  run "$REPO_ROOT/bin/fleet-spawn" --mission s1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"airlock -C $wt -- "* ]]
}

@test "a bunkered brief writes the marker itself, since fleet-done is host-side" {
  # The bunker mounts the target repo and the worktree, never devfleet — so
  # fleet-done is not on PATH in there, and it resolves the marker path out of
  # state/ that is deliberately not mounted either. The marker is the contract;
  # the command is only one way to write it.
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s5 >/dev/null
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s5/mission.json")"
  run "$REPO_ROOT/bin/fleet-spawn" --mission s5 --stage execute --dry-run
  [ "$status" -eq 0 ]
  brief="$wt/.devfleet/s5.execute.brief"
  grep -qF "$wt/.devfleet/s5.status" "$brief"
  grep -q "blocked:<question>" "$brief"
  ! grep -q "fleet-done" "$brief"
}

@test "an unbunkered brief keeps the fleet-done contract" {
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  [ "$status" -eq 0 ]
  grep -q "fleet-done m001" "$WT/.devfleet/m001.spec.brief"
}

@test "a bunkered spawn with no loadout records a decision and does not launch" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s2 >/dev/null
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_AIRLOCK_STATE=not-scaffolded run "$REPO_ROOT/bin/fleet-spawn" --mission s2 --stage execute
  [ "$status" -ne 0 ]
  ! orca_log_has $'terminal\x1fcreate'                       # nothing launched
  [[ "$("$REPO_ROOT/bin/fleet-decision" list --open)" == *"s2"* ]]   # decision recorded
  [[ "$("$REPO_ROOT/bin/fleet-decision" list --open)" == *"not-scaffolded"* ]]
}

@test "the blocking state picks the remedy the decision offers" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s4 >/dev/null
  FLEET_FAKE_AIRLOCK_STATE=no-image run "$REPO_ROOT/bin/fleet-spawn" --mission s4 --stage execute
  [ "$status" -ne 0 ]
  d="$(cat "$FLEET_STATE_OVERRIDE"/decisions/*.json)"
  [[ "$d" == *'"key": "build"'* || "$d" == *'"key":"build"'* ]]
}

@test "a rebuild-pending repo still launches" {
  # The container predates the newest image; that is not a reason to stall every
  # mission in the repo.
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s5 >/dev/null
  FLEET_FAKE_AIRLOCK_STATE=rebuild-pending run "$REPO_ROOT/bin/fleet-spawn" --mission s5 --stage execute
  [ "$status" -eq 0 ]
  orca_log_has $'terminal\x1fcreate'
}

@test "a non-bunkered stage still launches bare" {
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s3 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s3 --stage plan --dry-run   # plan = frontier, not bunkered
  [ "$status" -eq 0 ]
  [[ "$output" != *"airlock"* ]]
}

@test "sortie stage resolves role and prompt from the palette" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s1 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s1 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi "* ]] || [[ "$output" == *"pi\""* ]]
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s1/mission.json")"
  brief="$wt/.devfleet/s1.execute.brief"
  [ -f "$brief" ]
  # execute = executor, and the example roles bunker the executor role, so the
  # completion contract is the bunkered "record the result" marker line, not
  # fleet-done (see "a bunkered brief writes the marker itself" below).
  grep -qF "$wt/.devfleet/s1.status" "$brief"
}

@test "sortie stage outside the palette dies" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s2 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s2 --stage nonsense --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"palette"* ]]
}

@test "ad-hoc brief uses the given text, role, and label" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s3 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s3 --role executor \
      --prompt-text "Run the benchmark in {worktree} for {mission_id}" --label bench --dry-run
  [ "$status" -eq 0 ]
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s3/mission.json")"
  brief="$wt/.devfleet/s3.bench.brief"
  [ -f "$brief" ]
  grep -q "Run the benchmark in" "$brief"
  grep -q "s3" "$brief"
  # --role executor is bunkered by default now; the completion contract is the
  # "record the result" marker line, not fleet-done.
  grep -qF "$wt/.devfleet/s3.status" "$brief"
}

@test "ad-hoc flags must come as a complete set" {
  "$REPO_ROOT/bin/fleet-mission" --type sortie --project a --repo id:r --desc "task" --id s4 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s4 --role executor --dry-run
  [ "$status" -ne 0 ]
  run "$REPO_ROOT/bin/fleet-spawn" --mission s4 --stage plan --role executor \
      --prompt-text x --label l --dry-run
  [ "$status" -ne 0 ]
}
@test "a role's pre_spawn commands run in the bunker with the worktree substituted" {
  # A fresh agent home gates on things no unattended agent can answer: trust this
  # folder?, accept bypass mode?. They are per-worktree, so they cannot be
  # provisioned once per repo — they have to be settled just before launch.
  jq '.executor.bunker=true | .executor.pre_spawn=["seed-trust {worktree}"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s7 >/dev/null
  wt="$(jq -r .worktree_path "$FLEET_STATE_OVERRIDE/missions/s7/mission.json")"
  run "$REPO_ROOT/bin/fleet-spawn" --mission s7 --stage execute
  [ "$status" -eq 0 ]
  bunker_log_has $'airlock\x1f-C\x1f'"$wt"$'\x1f--\x1fbash\x1f-lc\x1fseed-trust '"$wt"
}

@test "an unbunkered role runs no pre_spawn" {
  jq '.frontier.pre_spawn=["seed-trust {worktree}"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec
  [ "$status" -eq 0 ]
  ! bunker_log_has 'seed-trust'
}

@test "a failing pre_spawn stops the launch rather than starting a gated agent" {
  jq '.executor.bunker=true | .executor.pre_spawn=["seed-trust {worktree}"]' \
    "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge github --ship-mode local-merge >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s8 >/dev/null
  : > "$FLEET_ORCA_LOG"
  FLEET_FAKE_BUNKER_EXEC_FAIL=1 run "$REPO_ROOT/bin/fleet-spawn" --mission s8 --stage execute
  [ "$status" -ne 0 ]
  refute_orca $'terminal\x1fcreate'
}

@test "spawning resets the stage clocks so the watcher judges the new agent" {
  # A hand spawn that inherits the previous stage's clocks looks stalled the
  # moment it starts — m001's review was restarted nine minutes into a healthy
  # run for exactly this reason.
  jq '.stage_started_at=1 | .last_progress_at=1 | .state_hash="stale" | .nudges=2' "$MJ" \
    > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$MJ"
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec
  [ "$status" -eq 0 ]
  [ "$(jq -r .state_hash "$MJ")" = "" ]
  [ "$(jq -r .nudges "$MJ")" = "0" ]
  [ "$(jq -r '.last_progress_at > 1' "$MJ")" = "true" ]
  [ "$(jq -r '.stage_started_at > 1' "$MJ")" = "true" ]
}

@test "the launch titles its own pane, so an agent that sets no title is still identifiable" {
  # omp paints a title of its own; claude's pane identity comes from orca's agent
  # hooks, which a bunkered agent cannot reach — so its pane kept the shell's
  # prompt title and looked like nothing was running.
  run "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'\033]0;fleet-m001-spec\007'* ]]
}

@test "the title survives the bunker wrap" {
  jq '.executor.bunker=true' "$FLEET_CONFIG_OVERRIDE/roles.json" > "$FLEET_TMP/r" && mv "$FLEET_TMP/r" "$FLEET_CONFIG_OVERRIDE/roles.json"
  "$REPO_ROOT/bin/fleet-mission" --type strike --project acme --repo id:r --desc x --issue 7 --id s9 >/dev/null
  run "$REPO_ROOT/bin/fleet-spawn" --mission s9 --stage execute --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'\033]0;fleet-s9-execute\007'* ]]
  [[ "$output" == *"airlock -C "* ]]
}

@test "a spawn sets the stage it is spawning" {
  # m002: fleet-spawn set the clocks but not .stage, so a commander-initiated
  # stage left the mission at its previous state word. `ready` is not in the
  # palette, so fleet_mission_in_flight went false and the watcher stopped
  # supervising a live agent — its completion marker would never be read.
  jq '.stage="ready" | .last_stage="review"' "$MJ" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$MJ"
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage fix >/dev/null
  [ "$(jq -r .stage "$MJ")" = "fix" ]
}

@test "a spawned mission is in flight, so the watcher supervises it" {
  # The property that actually matters: the stage word has to be one the
  # pipeline recognises, or supervision silently stops.
  jq '.stage="ready"' "$MJ" > "$FLEET_TMP/t" && mv "$FLEET_TMP/t" "$MJ"
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage fix >/dev/null
  run bash -c '. "$REPO_ROOT/bin/fleet-common"; . "$REPO_ROOT/bin/fleet-pipeline"; fleet_roots; fleet_mission_in_flight m001'
  [ "$status" -eq 0 ]
}

@test "an ad-hoc label becomes the stage it claimed it would" {
  # fleet-spawn already refuses reserved labels *because* "a label becomes
  # .stage". It has to actually become it.
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --role frontier \
    --prompt-text 'do a thing' --label probe >/dev/null
  [ "$(jq -r .stage "$MJ")" = "probe" ]
}

@test "the brief sends a question to the decision record, not the pane" {
  # m002: the plan agent asked its question in its own pane, where nothing in
  # the pipeline reads. The watcher saw an idle terminal and typed over the
  # operator mid-answer. The marker is the only channel that reaches anyone.
  "$REPO_ROOT/bin/fleet-spawn" --mission m001 --stage spec --dry-run >/dev/null
  run cat "$WT/.devfleet/m001.spec.brief"
  [[ "$output" == *"blocked:<question>"* ]]
  [[ "$output" == *"no one reads"* ]]
}
