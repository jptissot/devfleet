setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home; fleet_seed_config; fleet_install_fake_orca
}
teardown() { fleet_teardown_home; }

@test "create writes a project.json skeleton" {
  run "$REPO_ROOT/bin/fleet-project" create --name acme
  [ "$status" -eq 0 ]
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r .name "$pj")" = "acme" ]
  [ "$(jq -r '.repos | length' "$pj")" = "0" ]
}

@test "add-repo registers a repo with mode + forge + unattended" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r \
    --path /srv/acme --default-branch main --forge github --ship-mode local-merge --unattended >/dev/null
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r '.repos[0].selector' "$pj")" = "id:r" ]
  [ "$(jq -r '.repos[0].ship_mode' "$pj")" = "local-merge" ]
  [ "$(jq -r '.repos[0].unattended' "$pj")" = "true" ]
}

@test "add-repo replaces an existing repo rather than duplicating it" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode report-only >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode local-merge >/dev/null
  pj="$FLEET_PROJECTS_OVERRIDE/acme/project.json"
  [ "$(jq -r '.repos | length' "$pj")" = "1" ]
  [ "$(jq -r '.repos[0].ship_mode' "$pj")" = "local-merge" ]
}
@test "fleet_repo_field reads fields and degrades to empty on miss" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch dev --forge gitea --ship-mode direct-PR >/dev/null
  run bash -c '. '"'"$REPO_ROOT/bin/fleet-common"'"'; . '"'"$REPO_ROOT/bin/fleet-project"'"'; fleet_roots; fleet_repo_field acme id:r ship_mode; echo "|"; fleet_repo_field acme id:r default_branch; echo "|"; fleet_repo_field acme nope missing'
  [[ "$output" == "direct-PR"$'\n'"|"$'\n'"dev"$'\n'"|"* ]]
}
@test "show on a missing project fails cleanly (no unbound-variable crash)" {
  run "$REPO_ROOT/bin/fleet-project" show ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"no project ghost"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "add-repo --bunker sets the per-repo override" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path /a --default-branch main --forge github --ship-mode local-merge --bunker >/dev/null
  [ "$(jq -r '.repos[0].bunker' "$FLEET_PROJECTS_OVERRIDE/acme/project.json")" = "true" ]
}