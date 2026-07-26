setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  HOOK="$REPO_ROOT/.githooks/commit-msg"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-hook.XXXXXX")"
  MSG="$TMP/msg"
}
teardown() { rm -rf "$TMP"; }

# Write a message, run the hook over it, leave the result in $MSG.
hook() { printf '%s' "$1" > "$MSG"; run "$HOOK" "$MSG"; }

@test "hook is executable" {
  [ -x "$HOOK" ]
}

@test "an agent co-author trailer is removed" {
  hook 'fix: the thing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
'
  [ "$status" -eq 0 ]
  ! grep -qi 'co-authored-by' "$MSG"
  grep -q 'fix: the thing' "$MSG"
}

@test "a lower-case agent trailer is removed too" {
  hook 'fix: the thing

Co-authored-by: Claude <noreply@anthropic.com>
'
  [ "$status" -eq 0 ]
  ! grep -qi 'co-authored-by' "$MSG"
}

@test "a human co-author survives" {
  hook 'feat: two of us wrote this

Co-authored-by: Jane Roe <jane@example.com>
'
  [ "$status" -eq 0 ]
  grep -q 'Co-authored-by: Jane Roe <jane@example.com>' "$MSG"
}

@test "a human whose name happens to be Claude survives" {
  hook 'feat: a change

Co-authored-by: Claude Dupont <claude.dupont@example.org>
'
  [ "$status" -eq 0 ]
  grep -q 'Claude Dupont' "$MSG"
}

@test "the generated-with line is removed" {
  hook 'docs: a change

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'
  [ "$status" -eq 0 ]
  ! grep -q 'Generated with' "$MSG"
  grep -q 'docs: a change' "$MSG"
}

@test "a message with nothing to strip is unchanged" {
  printf 'refactor: tidy the parser\n\nThe old one read the file twice.\n' > "$TMP/orig"
  cp "$TMP/orig" "$MSG"
  run "$HOOK" "$MSG"
  [ "$status" -eq 0 ]
  cmp "$TMP/orig" "$MSG"
}

@test "blank lines left behind by a deletion are collapsed" {
  hook 'fix: the thing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

'
  [ "$status" -eq 0 ]
  # The body ends at its last real line: no trailing blank run.
  [ "$(tail -c 2 "$MSG" | head -c 1)" != "" ]
  [ "$(wc -l < "$MSG")" -eq 1 ]
}

@test "a commented-out trailer in the git template is left alone" {
  hook 'fix: the thing

# Co-authored-by: Claude <noreply@anthropic.com>
'
  [ "$status" -eq 0 ]
  grep -q '^# Co-authored-by' "$MSG"
}

@test "the hook exits 0 on a missing message file" {
  run "$HOOK" "$TMP/does-not-exist"
  [ "$status" -eq 0 ]
}
