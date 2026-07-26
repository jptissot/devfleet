# shellcheck shell=bash
# Shared bats helpers: temp roots, fake orca, assertions, config seed.

fleet_setup_home() {
  FLEET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
  export FLEET_TMP
  export FLEET_ROOT_OVERRIDE="$REPO_ROOT"
  export FLEET_HOME="$FLEET_TMP/home"
  export FLEET_STATE_OVERRIDE="$FLEET_HOME/state"
  export FLEET_CONFIG_OVERRIDE="$FLEET_HOME/config"
  export FLEET_PROJECTS_OVERRIDE="$FLEET_HOME/projects"
  mkdir -p "$FLEET_HOME" "$FLEET_STATE_OVERRIDE" "$FLEET_CONFIG_OVERRIDE" "$FLEET_PROJECTS_OVERRIDE"
}

fleet_teardown_home() {
  [ -n "${FLEET_TMP:-}" ] && rm -rf "$FLEET_TMP"
}

# Copy the real mission-type configs + roles + prompts into the temp home.
fleet_seed_config() {
  mkdir -p "$FLEET_CONFIG_OVERRIDE/missions"
  cp "$REPO_ROOT"/config/missions/*.json "$FLEET_CONFIG_OVERRIDE/missions/"
  [ -f "$REPO_ROOT"/config/roles.json.example ] && cp "$REPO_ROOT"/config/roles.json.example "$FLEET_CONFIG_OVERRIDE/roles.json" || true
  [ -d "$REPO_ROOT"/prompts ] && cp -r "$REPO_ROOT"/prompts "$FLEET_HOME/prompts" || true
}

# Install a fake `orca` on PATH that logs argv and replays canned responses.
# (firstmate:tests/fm-backend-orca.test.sh:11-40)
fleet_install_fake_orca() {
  FAKEBIN="$FLEET_TMP/fakebin"; mkdir -p "$FAKEBIN"
  export FLEET_ORCA_LOG="$FLEET_TMP/orca.log"; : > "$FLEET_ORCA_LOG"
  export FLEET_FAKE_WT_ROOT="$FLEET_TMP/worktrees"; mkdir -p "$FLEET_FAKE_WT_ROOT"
  export FLEET_FAKE_TERM_SEQ="$FLEET_TMP/.term-seq"; echo 0 > "$FLEET_FAKE_TERM_SEQ"
  cat > "$FAKEBIN/orca" <<'ORCA'
#!/usr/bin/env bash
set -u
{ printf 'orca'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_ORCA_LOG"
val() { local flag=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$flag" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "status --json"|"status ")
    printf '{"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  "worktree create")
    name="$(val --name "$@")"; repo="$(val --repo "$@")"
    path="$FLEET_FAKE_WT_ROOT/$name"; mkdir -p "$path"
    printf '{"result":{"worktree":{"id":"%s::%s","path":"%s"}}}\n' "${repo#id:}" "$path" "$path" ;;
  "worktree rm")   printf '{"result":{"ok":true}}\n' ;;
  "terminal create")
    n=$(( $(cat "$FLEET_FAKE_TERM_SEQ") + 1 )); echo "$n" > "$FLEET_FAKE_TERM_SEQ"
    printf '{"result":{"terminal":{"handle":"term_%03d"}}}\n' "$n" ;;
  "terminal wait")
    printf '{"result":{"wait":{"satisfied":%s,"status":"running","blockedReason":%s,"exitCode":%s}}}\n' \
      "${FLEET_FAKE_SAT:-true}" "${FLEET_FAKE_BLOCKED:-null}" "${FLEET_FAKE_EXIT:-null}" ;;
  "terminal list")
    # tabId/leafId are how a session recognizes its own pane: ORCA_PANE_KEY is
    # exactly "<tabId>:<leafId>".
    printf '{"result":{"terminals":['
    printf '{"handle":"term_001","tabId":"tab_1","leafId":"leaf_1","title":"a"},'
    printf '{"handle":"term_002","tabId":"tab_2","leafId":"leaf_2","title":"b"}'
    printf ']}}\n' ;;
  "terminal show")
    # connected is liveness. An exited terminal still answers `read`, so this is
    # the flag that separates "running" from "finished but still readable".
    h="$(val --terminal "$@")"
    live=true
    [ "${FLEET_FAKE_TERM_GONE:-0}" = "1" ] && live=false
    grep -qxF "$h" "$FLEET_TMP/.term-closed" 2>/dev/null && live=false
    # tab/leaf mirror the list, so pane-key resolution works off either.
    case "$h" in
      term_001) tab=tab_1; leaf=leaf_1 ;;
      term_002) tab=tab_2; leaf=leaf_2 ;;
      *)        tab=tab_x; leaf=leaf_x ;;
    esac
    printf '{"result":{"terminal":{"handle":"%s","connected":%s,"tabId":"%s","leafId":"%s"}}}\n' \
      "$h" "$live" "$tab" "$leaf" ;;
  "terminal read")
    if [ "${FLEET_FAKE_TERM_GONE:-0}" = "1" ]; then exit 1; fi
    h="$(val --terminal "$@")"
    # A closed terminal can still answer a read for a moment: close is async.
    if grep -qxF "$h" "$FLEET_TMP/.term-closed" 2>/dev/null; then
      lag="${FLEET_FAKE_CLOSE_LAG:-0}"
      n=$(( $(cat "$FLEET_TMP/.term-lag" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$FLEET_TMP/.term-lag"
      [ "$n" -gt "$lag" ] && exit 1
    fi
    # Whatever was typed into the pane is on the pane. The watcher's own nudge
    # goes through `terminal send`, so a fake that leaves the tail untouched
    # lets detection read its own echo as the agent doing something — the m002
    # bug is invisible without this. It shows for one read and then scrolls
    # away, which is the size of a one-line notice in a real tail; leaving it
    # there forever would instead swamp the screen identity a test has set.
    sent=""
    if [ -s "$FLEET_TMP/.term-sent" ]; then
      sent="$(cat "$FLEET_TMP/.term-sent")"; : > "$FLEET_TMP/.term-sent"
    fi
    printf '%s\n%s' "${FLEET_FAKE_TERM_TAIL:-}" "$sent" \
      | jq -R -s '{result:{terminal:{tail:(rtrimstr("\n")|split("\n"))}}}' ;;
  "terminal send")
    t="$(val --text "$@")"
    [ -n "$t" ] && printf '%s\n' "$t" >> "$FLEET_TMP/.term-sent"
    printf '{"result":{"ok":true}}\n' ;;
  "terminal stop")
    # orca's stop is worktree-scoped. Handed --terminal it answers ok:false and
    # still exits 0 — the shape that let a no-op read as a successful stop.
    if [ -n "$(val --worktree "$@")" ]; then
      printf '{"ok":true,"result":{}}\n'
    else
      printf '{"ok":false,"error":"stop requires --worktree","result":{}}\n'
    fi ;;
  "terminal close")
    h="$(val --terminal "$@")"
    if [ "${FLEET_FAKE_CLOSE_FAIL:-0}" = "1" ]; then
      printf '{"ok":false,"error":"close failed","result":{}}\n'
    else
      printf '%s\n' "$h" >> "$FLEET_TMP/.term-closed"
      # A real agent can still be writing when the stop lands. Let a test model
      # the revision that actually bit m001: findings rewritten after the marker.
      [ -n "${FLEET_FAKE_CLOSE_WRITES_FILE:-}" ] \
        && printf '%s' "${FLEET_FAKE_CLOSE_WRITES:-}" > "$FLEET_FAKE_CLOSE_WRITES_FILE"
      printf '{"ok":true,"result":{}}\n'
    fi ;;
  *) printf '{"result":{}}\n' ;;
esac
ORCA
  chmod +x "$FAKEBIN/orca"
  export PATH="$FAKEBIN:$PATH"
}

# argv log assertion: every field 0x1f-separated (firstmate:tests/fm-backend-orca.test.sh:84)
orca_log_has() { grep -qF "$1" "$FLEET_ORCA_LOG"; }

# Fake forge tools (gh / tea) on PATH: log argv, print a canned PR URL.
fleet_install_fake_forge() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_FORGE_LOG="$FLEET_TMP/forge.log"; : > "$FLEET_FORGE_LOG"
  local t
  for t in gh tea; do
    cat > "$fb/$t" <<'TOOL'
#!/usr/bin/env bash
set -u
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_FORGE_LOG"
printf 'https://forge.example/pr/1\n'
TOOL
    chmod +x "$fb/$t"
  done
  export PATH="$fb:$PATH"
}
forge_log_has() { grep -qF "$1" "$FLEET_FORGE_LOG"; }
# Fake tea-axi on PATH: logs argv to FLEET_FORGE_LOG, prints a canned PR URL.
fleet_install_fake_tea_axi() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_FORGE_LOG="${FLEET_FORGE_LOG:-$FLEET_TMP/forge.log}"; : > "$FLEET_FORGE_LOG"
  cat > "$fb/tea-axi" <<'TAXI'
#!/usr/bin/env bash
set -u
{ printf 'tea-axi'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_FORGE_LOG"
# TOON, as an AXI renders it. FLEET_FAKE_TEA_AXI_QUOTE picks whether the encoder
# quoted the value — it does when the string carries a colon, which a URL always
# does, but that is the encoder's choice and not a contract.
if [ "${FLEET_FAKE_TEA_AXI_QUOTE:-1}" = "1" ]; then
  printf 'created: pull request #9\nnumber: 9\nurl: "https://forge.example/acme/app/pulls/9"\nstate: open\n'
else
  printf 'created: pull request #9\nnumber: 9\nurl: https://forge.example/acme/app/pulls/9\nstate: open\n'
fi
TAXI
  chmod +x "$fb/tea-axi"; export PATH="$fb:$PATH"
}

# Make $1 a real git repo with one commit; echo nothing. Used for hash tests.
fleet_git_init() {  # <dir>
  git -C "$1" init -q
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  echo seed > "$1/seed.txt"; git -C "$1" add -A; git -C "$1" commit -qm seed
}

# Build a real repo with `main`, plus a linked worktree on branch <mission-id>
# one commit ahead. Echoes "<repo_path>\t<worktree_path>".
fleet_make_repo_worktree() {  # <mission-id>
  local id=$1 repo="$FLEET_TMP/repos/$id" wt="$FLEET_TMP/wt/$id"
  mkdir -p "$FLEET_TMP/repos" "$FLEET_TMP/wt"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  git -C "$repo" worktree add -q -b "fleet-$id" "$wt" >/dev/null
  git -C "$wt" commit -q --allow-empty -m "work for $id"
  printf '%s\t%s' "$repo" "$wt"
}

# Fake forge tools (gh / tea) on PATH: log argv, print a canned PR URL.
fleet_install_fake_forge() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_FORGE_LOG="$FLEET_TMP/forge.log"; : > "$FLEET_FORGE_LOG"
  local t
  for t in gh tea; do
    cat > "$fb/$t" <<'TOOL'
#!/usr/bin/env bash
set -u
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_FORGE_LOG"
printf 'https://forge.example/pr/1\n'
TOOL
    chmod +x "$fb/$t"
  done
  export PATH="$fb:$PATH"
}
forge_log_has() { grep -qF "$1" "$FLEET_FORGE_LOG"; }

# Fake airlock on PATH: logs argv, and answers `status` with the real tool's
# exit-code contract (0 ready, 10/11 unapproved, 20 not-scaffolded, 21 no-image,
# 22 rebuild-pending). FLEET_FAKE_AIRLOCK_STATE picks which, so a test names the
# state it is exercising rather than a boolean.
fleet_install_fake_bunker() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_BUNKER_LOG="$FLEET_TMP/bunker.log"; : > "$FLEET_BUNKER_LOG"
  cat > "$fb/airlock" <<'AS'
#!/usr/bin/env bash
set -u
{ printf 'airlock'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_BUNKER_LOG"
# -C DIR may lead, exactly as the real CLI allows.
while [ "${1:-}" = "-C" ]; do shift 2; done
case "${1:-}" in
  status)
    case "${FLEET_FAKE_AIRLOCK_STATE:-ready}" in
      ready)           printf 'ready\n' ;;
      unapproved)      printf 'unapproved\n'; exit 10 ;;
      config-gate)     printf 'unapproved\n'; exit 11 ;;
      not-scaffolded)  printf 'not-scaffolded\n'; exit 20 ;;
      no-image)        printf 'no-image\n'; exit 21 ;;
      rebuild-pending) printf 'rebuild-pending\n'; exit 22 ;;
      *)               printf 'ready\n' ;;
    esac
    ;;
  --)
    # A provisioning command runs through `airlock -C <repo> -- ...`. Model a
    # command that reads stdin (every TUI does): if the caller leaves its own
    # list on stdin, the next commands vanish into this one.
    cat >/dev/null 2>&1 || true
    [ "${FLEET_FAKE_BUNKER_EXEC_FAIL:-0}" = 1 ] && exit 1
    printf 'ran\n' ;;
  init)
    # init keeps its own argparse and is NOT part of the global -C loop, so a
    # trailing `-C DIR` reaches it as an unrecognized argument. status/build
    # tolerate either order; init does not. Model that, or the suite green-lights
    # a call the real CLI rejects.
    shift
    for a in "$@"; do
      [ "$a" = "-C" ] || continue
      echo "airlock init: error: unrecognized arguments: -C" >&2; exit 2
    done
    [ "${FLEET_FAKE_LOADOUT_INIT_FAIL:-0}" = 1 ] && exit 1; printf 'scaffolded\n' ;;
  build)  printf 'built\n' ;;
  --)     [ "${FLEET_FAKE_BUNKER_EXEC_FAIL:-0}" = 1 ] && exit 1; printf 'ran\n' ;;
  *)      printf 'ran\n' ;;
esac
AS
  chmod +x "$fb/airlock"
  export PATH="$fb:$PATH"
}
# -- : a pattern may start with a dash (e.g. --harness), which grep would
# otherwise read as its own flag and fail with status 2.
bunker_log_has() { grep -qF -- "$1" "$FLEET_BUNKER_LOG"; }
# `! grep -q X file` CANNOT fail a bats test: set -e is ignored for a pipeline
# prefixed with !, so the negation is evaluated and discarded. Use this to assert
# an absence.
refute_orca() {
  if grep -qF -- "$1" "$FLEET_ORCA_LOG"; then
    echo "expected NOT to find in orca log: $1" >&2
    return 1
  fi
}

# Fake curl on PATH: logs argv, prints nothing. Used to assert what the hook
# relay posts without a receiver.
fleet_install_fake_curl() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_CURL_LOG="$FLEET_TMP/curl.log"; : > "$FLEET_CURL_LOG"
  cat > "$fb/curl" <<'CURL'
#!/usr/bin/env bash
set -u
{ printf 'curl'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_CURL_LOG"
cat >/dev/null 2>&1 || true
CURL
  chmod +x "$fb/curl"; export PATH="$fb:$PATH"
}
curl_log_has() { grep -qF -- "$1" "$FLEET_CURL_LOG"; }
