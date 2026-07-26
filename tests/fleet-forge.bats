setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  load helpers/common
  fleet_setup_home
}
teardown() { fleet_teardown_home; }

@test "github PR pushes and calls gh, prints a url" {
  fleet_install_fake_forge
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr github "'"$repo"'" feat main "mission x"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"forge.example/pr/1"* ]]
  forge_log_has $'gh\x1fpr\x1fcreate'
}
@test "missing forge tool returns rc 3 (degrade signal)" {
  # PATH is pinned, not assumed bare: a `tea` installed on the host would
  # otherwise satisfy the lookup and the degrade path would never be reached.
  PATH="/usr/bin:/bin" run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr gitea /nope b main t'
  [ "$status" -eq 3 ]
}
@test "gitea PR prefers tea-axi when present" {
  fleet_install_fake_tea_axi
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base; git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr forgejo "'"$repo"'" feat main "mission x"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulls/9"* ]]
  grep -q $'tea-axi\x1fpr\x1fcreate' "$FLEET_FORGE_LOG"
}
@test "no forge tool: returns 3 without pushing anything" {
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  PATH="/usr/bin:/bin" run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr forgejo "'"$repo"'" feat main "mission x"'
  [ "$status" -eq 3 ]
  [ -z "$(git -C "$FLEET_TMP/origin" for-each-ref)" ]
}

@test "the gitea arm reads the url out of tea-axi's TOON, unquoted" {
  # Plan Task 15. tea-axi renders TOON, so stdout is a record, not a URL — and
  # the encoder quotes any value with a colon in it, which every URL has.
  fleet_install_fake_tea_axi
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base; git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr gitea "'"$repo"'" feat main "mission x"'
  [ "$status" -eq 0 ]
  [ "$output" = "https://forge.example/acme/app/pulls/9" ]   # no quotes, no other fields
}

@test "an unquoted TOON url reads the same" {
  fleet_install_fake_tea_axi
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base; git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  FLEET_FAKE_TEA_AXI_QUOTE=0 run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr gitea "'"$repo"'" feat main "mission x"'
  [ "$output" = "https://forge.example/acme/app/pulls/9" ]
}

@test "plain tea still prints its bare url" {
  fleet_install_fake_forge          # `tea` prints a URL and nothing else
  repo="$FLEET_TMP/repo"; git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base; git -C "$repo" checkout -q -b feat; git -C "$repo" commit -q --allow-empty -m work
  git init -q --bare "$FLEET_TMP/origin"; git -C "$repo" remote add origin "$FLEET_TMP/origin"
  run bash -c '. "$REPO_ROOT/bin/fleet-forge"; fleet_forge_pr gitea "'"$repo"'" feat main "mission x"'
  [ "$output" = "https://forge.example/pr/1" ]
}
