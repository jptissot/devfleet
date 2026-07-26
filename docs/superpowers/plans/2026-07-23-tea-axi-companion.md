# tea-axi Companion + DevFleet Swap Implementation Plan (Plan 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build **tea-axi** — the last missing axi, a thin CLI wrapper over the Forgejo/Gitea REST API — with exactly the surface DevFleet's `direct-PR` ship mode needs (`tea-axi pr create`, `tea-axi pr status`), then make `fleet-forge` prefer it over plain `tea`. Plus wire the bunker loadout-gate's `init` answer (Plan 6 review F-B1) so it actually scaffolds the loadout instead of only pinging.

**Architecture:** tea-axi is its **own repo** (companion sub-project, per the design) — a single `bin/tea-axi` bash entrypoint that resolves `{base-url, token, owner/repo}` from flags → env → the git `origin` remote, then speaks the Forgejo/Gitea REST API with `curl` + a `token` header, parsing responses with `jq`. It mirrors DevFleet's own conventions (the two are siblings by the same author). DevFleet consumes it only through those two verbs behind the existing `fleet-forge` seam — swapping `tea` → `tea-axi` touches one arm of one file. The F-B1 fix extends the Plan 3 decision inbox with a third mechanical answer (`init`) that runs `fleet-loadout init`.

**Tech Stack:** Bash, `curl`, `jq`, `git`, `bats-core` 1.12, `shellcheck`. The forge API is stubbed by a **fake `curl` on `PATH`** (new, mirroring the fake `orca`/`gh`/`tea`/`agent-sandbox` idiom) — no live Forgejo needed to test.

**Builds on:** DevFleet Plans 1–6 (the `bunkers` branch — 125 bats green; merge it to `main` first, discarding master's stale `fleet-watch*` edits). tea-axi Tasks (2–4) stand alone in a fresh repo; Tasks 1 and 5 modify DevFleet.

**Spec:** DevFleet design `docs/superpowers/specs/2026-07-22-devfleet-design.md` — "axi integrations" (`tea-axi` — Gitea/Forgejo ops for `direct-PR`, plain `tea` fallback, "companion sub-project (own spec), axi-style wrapper over the Forgejo/Gitea API. DevFleet depends only on its CLI surface `tea-axi pr create`, `tea-axi pr status`"), "Ship modes" (`direct-PR`). Convention reference: DevFleet's own `bin/fleet-forge`/`bin/fleet-backend` seams and its fake-tool test idiom; if an existing **axi template** (e.g. `gh-axi`) should be mirrored instead, point me at it — same way firstmate seeded DevFleet's conventions.

**Interpretation note:** the design calls tea-axi a sub-project with "its own spec." Because DevFleet depends on **only two verbs**, this plan treats that surface as the spec and builds a focused v1. A richer tea-axi (issues, reviews, releases, status checks) would warrant its own brainstorm — out of scope here.

**Out of scope:** tea-axi verbs beyond `pr create`/`pr status`; interactive auth/OAuth (token via env only); `gh-axi`/`lavish-axi` (already handled/optional); the DevFleet bunker/night/ship internals (done in Plans 1–6).

## Global Constraints

- **tea-axi repo** conventions mirror DevFleet: `#!/usr/bin/env bash`; entrypoint `set -euo pipefail`; libs `# shellcheck shell=bash`, no `set`, no side effects on source; all JSON via `jq`; all HTTP via one `curl` seam function; `bats tests/` + `shellcheck bin/*` green after every task.
- **DevFleet-depended surface is frozen** (design): `tea-axi pr create --head <branch> --base <base> --title <title> [--body <b>] [--repo owner/name] [--url <base-url>]` prints the PR URL on stdout, exits 0; `tea-axi pr status --pr <n> [--repo owner/name] [--url <base-url>]` prints one of `open|merged|closed`. `fleet-forge` calls the first with no `--repo`/`--url` (derived from the repo's `origin`), so derivation is mandatory, not optional.
- **Token from env only:** `TEA_AXI_TOKEN` → `FORGEJO_TOKEN` → `GITEA_TOKEN`. Never a flag (avoids process-table leakage). Absent token → exit non-zero with a clear message; `fleet-forge` degrades to report-only (rc 3 contract, Plan 4).
- **Secrets host-side** (DevFleet): tea-axi runs host-side inside `fleet-ship`; a bunkered operator never invokes it and never sees the token.

## Data model

Forgejo/Gitea REST (v1), base `"$URL/api/v1"`, header `Authorization: token <TOKEN>`:
- Create PR: `POST /repos/{owner}/{repo}/pulls` body `{"head","base","title","body"}` → `201` with `.html_url`, `.number`.
- PR status: `GET /repos/{owner}/{repo}/pulls/{index}` → `.state` (`"open"|"closed"`), `.merged` (bool). Mapped: `merged` if `.merged==true`, else `.state`.

`origin` remote → `{base-url, owner, repo}`:
- `https://forge.example/acme/app.git` → url `https://forge.example`, owner `acme`, repo `app`.
- `git@forge.example:acme/app.git` → url `https://forge.example`, owner `acme`, repo `app`.

## File Structure

```
# --- DevFleet repo (bunkers branch / main after merge) ---
bin/fleet-decision   # MODIFIED (F-B1): `answer init` -> fleet-loadout init (scaffold) + guided wake
bin/fleet-forge      # MODIFIED: gitea/forgejo arm prefers tea-axi over tea
tests/fleet-decision.bats  # MODIFIED: `answer init` scaffolds
tests/fleet-forge.bats     # MODIFIED: tea-axi preferred when present
tests/helpers/common.bash  # MODIFIED: fake tea-axi on PATH

# --- tea-axi repo (NEW, sibling: ../tea-axi) ---
bin/tea-axi          # NEW entrypoint: pr create | pr status
bin/tea-axi-lib      # NEW lib: config/remote resolution + the curl seam
tests/helpers/common.bash  # NEW: fake curl + repo fixture
tests/pr-create.bats # NEW
tests/pr-status.bats # NEW
tests/resolve.bats   # NEW (remote/url/token resolution)
Makefile             # NEW: `make check` = shellcheck + bats
```

---

### Task 1: Wire the loadout-gate `init` answer (DevFleet review F-B1)

**Files (DevFleet, `bunkers` branch):**
- Modify: `bin/fleet-decision` (`fleet_decision_answer` routing + source `fleet-project`)
- Test: `tests/fleet-decision.bats`

**Why:** Plan 6's bunker loadout gate records a decision offering an `init` option, but `fleet_decision_answer` routes only `resume`/`ship` — answering `init` merely wakes the Commander. Make `init` mechanically scaffold the repo's loadout (`fleet-loadout init`), then wake the Commander with the concrete next steps (review, build, re-spawn). Scaffold — not build — because agent-sandbox's build IS the human approval gate (spec "Bunkers"); auto-building would bypass it.

**Interfaces:** `fleet_decision_answer` gains an `init` branch: resolve the decision's mission → project/repo → repo path (`fleet_repo_field`), run `fleet-loadout init --path <repo>`, journal, and wake with guidance. `resume`/`ship` unchanged.

- [ ] **Step 1: Write the failing test**

Add to `tests/fleet-decision.bats`:

```bash
@test "answer init scaffolds the repo loadout" {
  "$REPO_ROOT/bin/fleet-project" create --name acme >/dev/null
  "$REPO_ROOT/bin/fleet-project" add-repo --project acme --repo id:r --path "$FLEET_TMP/repo" --default-branch main --forge gitea --ship-mode direct-PR >/dev/null
  mkdir -p "$FLEET_TMP/repo"
  "$REPO_ROOT/bin/fleet-decision" create --mission m1 --stage execute --question "repo id:r has no built loadout — init now?" --option "init:init loadout:scaffold" >/dev/null
  run "$REPO_ROOT/bin/fleet-decision" answer d1 init
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$FLEET_STATE_OVERRIDE/decisions/d1.json")" = "answered" ]
  bunker_log_has $'agent-sandbox\x1finit\x1f--path'    # fleet-loadout init ran
}
```

(This test needs the fake agent-sandbox; ensure `tests/fleet-decision.bats` `setup` calls `fleet_install_fake_bunker` — add it beside the existing fake orca install.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-decision.bats -f "answer init"`
Expected: FAIL — `init` falls through to the wake branch; no `agent-sandbox init` call.

- [ ] **Step 3: Source `fleet-project` in `fleet-decision`'s entrypoint**

In `bin/fleet-decision`, in the `if [ "${BASH_SOURCE[0]}" = "$0" ]` block, add after the `fleet-backend` source:

```bash
  # shellcheck source=bin/fleet-project
  . "$SCRIPT_DIR/fleet-project"
```

- [ ] **Step 4: Add the `init` branch to `fleet_decision_answer`**

In `bin/fleet-decision`, extend the routing tail of `fleet_decision_answer` (after the `ship` branch, before the `elif day` wake):

```bash
  elif [ "$answer" = init ]; then
    local mj project repo repo_path
    mj="$(fleet_mission_json "$mission")"
    project="$(fleet_json_get "$mj" '.project')"; repo="$(fleet_json_get "$mj" '.repo')"
    repo_path="$(fleet_repo_field "$project" "$repo" path)"
    if [ -n "$repo_path" ]; then
      "$SCRIPT_DIR/fleet-loadout" init --path "$repo_path" >/dev/null 2>&1 || true
      fleet_journal loadout-scaffold "$mission $repo ($repo_path)"
      "$SCRIPT_DIR/fleet-wake" "loadout scaffolded for $repo — review .agent-sandbox/, run: fleet-loadout build --path $repo_path, then re-spawn $mission" 2>/dev/null || true
    else
      "$SCRIPT_DIR/fleet-wake" "decision $did: $mission repo $repo has no registered path — register it, then init the loadout" 2>/dev/null || true
    fi
```

- [ ] **Step 5: Run to verify pass; whole suite; lint; commit**

```bash
bats tests/fleet-decision.bats && bats tests/
shellcheck bin/fleet-decision
git add bin/fleet-decision tests/fleet-decision.bats
git commit -m "feat: loadout-gate 'init' answer scaffolds via fleet-loadout (review F-B1)"
```

---

### Task 2: tea-axi repo scaffold — resolution + curl seam

**Files (NEW repo, `../tea-axi`):**
- Create: `bin/tea-axi-lib`, `tests/helpers/common.bash`, `tests/resolve.bats`, `Makefile`

**Interfaces:**
- Produces (sourced `tea-axi-lib`):
  - `tea_axi_remote <dir>` → prints `<base-url>\t<owner>\t<repo>` parsed from `dir`'s `origin` remote; rc 1 if no origin.
  - `tea_axi_resolve <cwd> <flag-repo> <flag-url>` → prints resolved `<base-url>\t<owner>\t<repo>` (flags win over the remote); rc 1 if unresolvable.
  - `tea_axi_token` → prints the first set of `TEA_AXI_TOKEN`/`FORGEJO_TOKEN`/`GITEA_TOKEN`; rc 1 if none.
  - `tea_axi_api <method> <url> [json-body]` → the **one** curl seam; prints the response body; rc from curl.
- Helper: `taxi_install_fake_curl` (fake `curl` logging argv to `$TAXI_CURL_LOG`, emitting `$TAXI_FAKE_RESPONSE`), `taxi_make_repo <origin-url>` (a git dir with an `origin`), `curl_log_has`.

- [ ] **Step 1: Write the failing tests**

Create `tests/helpers/common.bash`:

```bash
# shellcheck shell=bash
taxi_setup() { TAXI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/taxi.XXXXXX")"; export TAXI_TMP; }
taxi_teardown() { [ -n "${TAXI_TMP:-}" ] && rm -rf "$TAXI_TMP"; }

taxi_install_fake_curl() {
  local fb="$TAXI_TMP/fakebin"; mkdir -p "$fb"
  export TAXI_CURL_LOG="$TAXI_TMP/curl.log"; : > "$TAXI_CURL_LOG"
  cat > "$fb/curl" <<'CURL'
#!/usr/bin/env bash
set -u
{ printf 'curl'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$TAXI_CURL_LOG"
printf '%s' "${TAXI_FAKE_RESPONSE:-{\}}"
CURL
  chmod +x "$fb/curl"; export PATH="$fb:$PATH"
}
curl_log_has() { grep -qF "$1" "$TAXI_CURL_LOG"; }

taxi_make_repo() {  # <origin-url> -> echoes the repo dir
  local url=$1 d="$TAXI_TMP/repo"; git init -q "$d"
  git -C "$d" remote add origin "$url"; printf '%s' "$d"
}
```

Create `tests/resolve.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export REPO_ROOT
  load helpers/common; taxi_setup
}
teardown() { taxi_teardown; }

@test "remote parses an https origin" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  run bash -c '. "$REPO_ROOT/bin/tea-axi-lib"; tea_axi_remote "'"$d"'"'
  [ "$output" = $'https://forge.example\tacme\tapp' ]
}

@test "remote parses an ssh origin" {
  d="$(taxi_make_repo git@forge.example:acme/app.git)"
  run bash -c '. "$REPO_ROOT/bin/tea-axi-lib"; tea_axi_remote "'"$d"'"'
  [ "$output" = $'https://forge.example\tacme\tapp' ]
}

@test "resolve lets --repo and --url override the remote" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  run bash -c '. "$REPO_ROOT/bin/tea-axi-lib"; tea_axi_resolve "'"$d"'" other/repo https://gitea.internal'
  [ "$output" = $'https://gitea.internal\tother\trepo' ]
}

@test "token prefers TEA_AXI_TOKEN then forge/gitea" {
  run bash -c 'unset TEA_AXI_TOKEN FORGEJO_TOKEN GITEA_TOKEN; GITEA_TOKEN=g . "$REPO_ROOT/bin/tea-axi-lib"; tea_axi_token'
  [ "$output" = "g" ]
  run bash -c 'TEA_AXI_TOKEN=t GITEA_TOKEN=g . "$REPO_ROOT/bin/tea-axi-lib"; tea_axi_token'
  [ "$output" = "t" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run (in the tea-axi repo): `bats tests/resolve.bats`
Expected: FAIL — `bin/tea-axi-lib` missing.

- [ ] **Step 3: Write `bin/tea-axi-lib`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# tea-axi-lib - config/remote resolution + the one curl seam for the
# Forgejo/Gitea REST API. Sourced only; no side effects on source.

# Parse a git origin URL into "<base-url>\t<owner>\t<repo>".
tea_axi_remote() {  # <dir>
  local url; url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  local host owner repo rest
  case "$url" in
    git@*) rest="${url#git@}"; host="${rest%%:*}"; rest="${rest#*:}" ;;   # host:owner/repo(.git)
    http://*|https://*) rest="${url#*://}"; host="${rest%%/*}"; rest="${rest#*/}" ;;
    *) return 1 ;;
  esac
  rest="${rest%.git}"; owner="${rest%%/*}"; repo="${rest#*/}"
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  printf '%s\t%s\t%s' "https://$host" "$owner" "$repo"
}

# Resolve base-url/owner/repo; explicit flags beat the remote. <flag-repo> is
# "owner/name" or empty; <flag-url> is a base url or empty.
tea_axi_resolve() {  # <cwd> <flag-repo> <flag-url>
  local cwd=$1 frepo=$2 furl=$3 url owner repo
  if r="$(tea_axi_remote "$cwd" 2>/dev/null)"; then
    IFS=$'\t' read -r url owner repo <<<"$r"
  fi
  [ -n "$furl" ] && url="$furl"
  [ -n "$frepo" ] && { owner="${frepo%%/*}"; repo="${frepo#*/}"; }
  [ -n "$url" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  printf '%s\t%s\t%s' "$url" "$owner" "$repo"
}

tea_axi_token() {
  local t="${TEA_AXI_TOKEN:-${FORGEJO_TOKEN:-${GITEA_TOKEN:-}}}"
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

# The one HTTP seam. Adds auth; returns curl's body + exit status.
tea_axi_api() {  # <method> <full-url> [json-body]
  local method=$1 url=$2 body=${3:-} tok
  tok="$(tea_axi_token)" || { echo "tea-axi: no token (set TEA_AXI_TOKEN/FORGEJO_TOKEN/GITEA_TOKEN)" >&2; return 2; }
  if [ -n "$body" ]; then
    curl -fsS -X "$method" -H "Authorization: token $tok" -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -fsS -X "$method" -H "Authorization: token $tok" "$url"
  fi
}
```

- [ ] **Step 4: Write the `Makefile`**

```makefile
check:
	shellcheck bin/*
	bats tests/
.PHONY: check
```

- [ ] **Step 5: Run to verify pass; lint; commit**

```bash
bats tests/resolve.bats
shellcheck bin/tea-axi-lib
git add bin/tea-axi-lib tests/helpers/common.bash tests/resolve.bats Makefile
git commit -m "feat: tea-axi resolution (remote/url/token) + curl seam"
```

---

### Task 3: `tea-axi pr create`

**Files (tea-axi repo):**
- Create: `bin/tea-axi`
- Test: `tests/pr-create.bats`

**Interfaces:** `tea-axi pr create --head <b> --base <base> --title <t> [--body <b>] [--repo owner/name] [--url <base-url>]` — resolves target, POSTs `/repos/{owner}/{repo}/pulls`, prints `.html_url`. Missing token → exit 2; missing head/base/title → exit 1; unresolvable target → exit 1.

- [ ] **Step 1: Write the failing test**

Create `tests/pr-create.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export REPO_ROOT
  load helpers/common; taxi_setup; taxi_install_fake_curl
  export TEA_AXI_TOKEN=secret
}
teardown() { taxi_teardown; }

@test "pr create posts to the pulls endpoint and prints the url" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  export TAXI_FAKE_RESPONSE='{"number":7,"html_url":"https://forge.example/acme/app/pulls/7"}'
  run bash -c 'cd "'"$d"'"; "$REPO_ROOT/bin/tea-axi" pr create --head feat --base main --title "add x"'
  [ "$status" -eq 0 ]
  [ "$output" = "https://forge.example/acme/app/pulls/7" ]
  curl_log_has $'\x1fPOST'
  curl_log_has 'https://forge.example/api/v1/repos/acme/app/pulls'
  curl_log_has 'Authorization: token secret'
}

@test "pr create fails cleanly with no token" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  run bash -c 'unset TEA_AXI_TOKEN FORGEJO_TOKEN GITEA_TOKEN; cd "'"$d"'"; "$REPO_ROOT/bin/tea-axi" pr create --head f --base main --title t'
  [ "$status" -ne 0 ]
  [[ "$output" == *"token"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/pr-create.bats`
Expected: FAIL — `bin/tea-axi` missing.

- [ ] **Step 3: Write `bin/tea-axi` (create arm)**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/tea-axi-lib
. "$SCRIPT_DIR/tea-axi-lib"

die() { echo "tea-axi: $*" >&2; exit 1; }

noun="${1:-}"; verb="${2:-}"; shift 2 2>/dev/null || true
[ "$noun" = pr ] || die "usage: tea-axi pr {create|status} ..."

repo="" url="" head="" base="" title="" body="" pr=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) repo=$2; shift 2 ;;
  --url) url=$2; shift 2 ;;
  --head) head=$2; shift 2 ;;
  --base) base=$2; shift 2 ;;
  --title) title=$2; shift 2 ;;
  --body) body=$2; shift 2 ;;
  --pr) pr=$2; shift 2 ;;
  *) die "unknown flag: $1" ;;
esac; done

IFS=$'\t' read -r U OWNER REPO <<<"$(tea_axi_resolve "$PWD" "$repo" "$url")" \
  || die "cannot resolve forge url/owner/repo (pass --url/--repo or run inside a repo with an origin)"

case "$verb" in
  create)
    [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] || die "pr create needs --head --base --title"
    payload="$(jq -n --arg h "$head" --arg b "$base" --arg t "$title" --arg y "$body" \
      '{head:$h,base:$b,title:$t,body:$y}')"
    resp="$(tea_axi_api POST "$U/api/v1/repos/$OWNER/$REPO/pulls" "$payload")" \
      || die "PR create failed"
    printf '%s\n' "$(printf '%s' "$resp" | jq -r '.html_url')" ;;
  status) die "status arm added in Task 4" ;;
  *) die "usage: tea-axi pr {create|status} ..." ;;
esac
```

- [ ] **Step 4: Run to verify pass; lint; commit**

```bash
bats tests/pr-create.bats
shellcheck bin/tea-axi
git add bin/tea-axi tests/pr-create.bats
git commit -m "feat: tea-axi pr create (POST pulls, prints html_url)"
```

---

### Task 4: `tea-axi pr status`

**Files (tea-axi repo):**
- Modify: `bin/tea-axi` (status arm)
- Test: `tests/pr-status.bats`

**Interfaces:** `tea-axi pr status --pr <n> [--repo owner/name] [--url <base-url>]` — GETs `/repos/{owner}/{repo}/pulls/{n}`, prints `merged` if `.merged==true`, else `.state` (`open`/`closed`). Missing `--pr` → exit 1.

- [ ] **Step 1: Write the failing test**

Create `tests/pr-status.bats`:

```bash
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export REPO_ROOT
  load helpers/common; taxi_setup; taxi_install_fake_curl
  export TEA_AXI_TOKEN=secret
}
teardown() { taxi_teardown; }

@test "pr status reports merged" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  export TAXI_FAKE_RESPONSE='{"state":"closed","merged":true}'
  run bash -c 'cd "'"$d"'"; "$REPO_ROOT/bin/tea-axi" pr status --pr 7'
  [ "$status" -eq 0 ]; [ "$output" = "merged" ]
  curl_log_has 'https://forge.example/api/v1/repos/acme/app/pulls/7'
}

@test "pr status reports open" {
  d="$(taxi_make_repo https://forge.example/acme/app.git)"
  export TAXI_FAKE_RESPONSE='{"state":"open","merged":false}'
  run bash -c 'cd "'"$d"'"; "$REPO_ROOT/bin/tea-axi" pr status --pr 3'
  [ "$output" = "open" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/pr-status.bats`
Expected: FAIL — the `status` arm dies with "added in Task 4".

- [ ] **Step 3: Implement the status arm**

In `bin/tea-axi`, replace the `status)` arm:

```bash
  status)
    [ -n "$pr" ] || die "pr status needs --pr <n>"
    resp="$(tea_axi_api GET "$U/api/v1/repos/$OWNER/$REPO/pulls/$pr")" || die "PR status failed"
    printf '%s' "$resp" | jq -r 'if .merged then "merged" else .state end' ;;
```

- [ ] **Step 4: Run to verify pass; full suite; make check; commit**

```bash
bats tests/
make check
git add bin/tea-axi tests/pr-status.bats
git commit -m "feat: tea-axi pr status (GET pull, merged/open/closed)"
```

---

### Task 5: DevFleet `fleet-forge` prefers tea-axi

**Files (DevFleet, `bunkers` branch):**
- Modify: `bin/fleet-forge` (`gitea|forgejo` arm)
- Modify: `tests/helpers/common.bash` (fake `tea-axi`)
- Test: `tests/fleet-forge.bats`

**Interfaces:** `fleet_forge_pr`'s `gitea|forgejo` arm uses `tea-axi pr create` when `tea-axi` is on `PATH`, else falls back to `tea pr create`, else rc 3. GitHub arm unchanged. `fleet-ship` `direct-PR` (Plan 4) is unchanged — it just gets a better wrapper.

- [ ] **Step 1: Write the failing test**

Add to `tests/helpers/common.bash` (a fake `tea-axi`, alongside `fleet_install_fake_forge`):

```bash
fleet_install_fake_tea_axi() {
  local fb="${FAKEBIN:-$FLEET_TMP/fakebin}"; mkdir -p "$fb"
  export FLEET_FORGE_LOG="${FLEET_FORGE_LOG:-$FLEET_TMP/forge.log}"; : > "$FLEET_FORGE_LOG"
  cat > "$fb/tea-axi" <<'TAXI'
#!/usr/bin/env bash
set -u
{ printf 'tea-axi'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FLEET_FORGE_LOG"
printf 'https://forge.example/acme/app/pulls/9\n'
TAXI
  chmod +x "$fb/tea-axi"; export PATH="$fb:$PATH"
}
```

Add to `tests/fleet-forge.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/fleet-forge.bats -f "prefers tea-axi"`
Expected: FAIL — the arm calls `tea`, not `tea-axi`.

- [ ] **Step 3: Update the `gitea|forgejo` arm**

In `bin/fleet-forge`, replace the `gitea|forgejo)` arm:

```bash
    gitea|forgejo)
      git -C "$path" push -u origin "$branch" >/dev/null 2>&1 || true
      if command -v tea-axi >/dev/null 2>&1; then
        ( cd "$path" && tea-axi pr create --head "$branch" --base "$base" --title "$title" )
      elif command -v tea >/dev/null 2>&1; then
        ( cd "$path" && tea pr create --head "$branch" --base "$base" --title "$title" )
      else
        return 3
      fi ;;
```

- [ ] **Step 4: Run to verify pass; full suite; make check; commit**

```bash
bats tests/fleet-forge.bats && bats tests/
make check
git add bin/fleet-forge tests/helpers/common.bash tests/fleet-forge.bats
git commit -m "feat: fleet-forge prefers tea-axi over tea for direct-PR (gitea/forgejo)"
```

---

## Self-Review

**Spec coverage:**
- tea-axi CLI surface DevFleet depends on: `tea-axi pr create`, `tea-axi pr status` → Tasks 3, 4 ✓
- axi-style thin wrapper over the Forgejo/Gitea REST API (token auth, one curl seam) → Tasks 2–4 ✓
- Plain `tea` fallback preserved; `tea-axi` preferred when present → Task 5 ✓
- Secrets host-side, token from env only → Global Constraints + Task 2 ✓
- Plan 6 review F-B1 (loadout-gate `init` answer) → Task 1 ✓

**Deferred (explicit):** tea-axi verbs beyond create/status; auth beyond env tokens; a fuller tea-axi brainstorm/spec (v1 = the two verbs DevFleet needs); merging the `bunkers` branch to `main` (a DevFleet housekeeping step, not part of this plan — do it first, discarding master's stale `fleet-watch*` edits).

**Type consistency:** `tea_axi_resolve <cwd> <flag-repo> <flag-url>` (Task 2) is called with that arg order by `bin/tea-axi` (Task 3). `tea_axi_api <method> <url> [body]` (Task 2) is called by both the create (POST + body) and status (GET) arms (Tasks 3, 4). The frozen CLI surface (`pr create --head --base --title`, prints URL; `pr status --pr`, prints `open|merged|closed`) is exactly what `fleet-forge` invokes in Task 5 — no `--repo`/`--url`, so the remote-derivation path (Task 2) is what runs. The `init` answer verb (Task 1) joins `resume`/`ship` in `fleet_decision_answer` with the same `<did> <answer>` signature.

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to" placeholders — every code step is complete. The fake `curl`/`tea-axi` stand in for absent tools exactly as the fake `orca`/`gh`/`tea`/`agent-sandbox` do across Plans 1–6.

**Failure modes:** no token → `tea_axi_api` exits 2 with a clear message → `tea-axi` dies non-zero → `fleet_forge_pr` returns non-zero → `fleet-ship` degrades to report-only (Plan 4 contract, unchanged). Unresolvable remote → `tea-axi` dies with guidance. `curl -fsS` makes an HTTP error a non-zero exit (not a silent empty body), so a rejected PR surfaces instead of printing a blank URL. Task 1's `fleet-loadout init` failure is tolerated (`|| true`) — the wake still tells the operator the next manual step, so the gate never dead-ends.
```
