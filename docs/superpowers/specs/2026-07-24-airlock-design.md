# Airlock — a devfleet-aware fork of agent-sandbox

**Date:** 2026-07-24
**Status:** implemented 2026-07-24 (see `docs/superpowers/plans/2026-07-24-airlock.md`)
**Repo:** `~/repos/airlock` (new, fresh git history)
**Ancestor:** `~/repos/agent-sandbox` (clean file copy — no shared history, no upstream remote)

## Why

devfleet's bunker seam (`bin/fleet-bunker`, `bin/fleet-loadout`, `bin/fleet-spawn`)
was written against a CLI contract agent-sandbox does not have. Verified
2026-07-24 against the real launcher:

| devfleet calls | agent-sandbox reality |
|---|---|
| `agent-sandbox --yes -- CMD` | no `--yes`; the flag is swallowed and `CMD` never runs |
| `agent-sandbox build --path P` | no `build` subcommand (`--build` is a flag that builds *then launches the agent*) |
| `agent-sandbox status --path P` | no `status` subcommand |
| `agent-sandbox init --path P` | `init` has no `--path`; it acts on `$PWD` |

The gap is structural. agent-sandbox keys everything off `$PWD`
(`sha256(pwd)[:12]` → container name, image tag, state dir) and exposes no path
parameter, so a supervisor process whose `$PWD` is unrelated cannot drive it. It
also creates one container per directory, which for devfleet would mean a
container and an image build per *mission*.

## Shape

**One container per repo, long-lived, entered per mission.** Orca creates
worktrees *inside* the repo (`<repo>/.worktrees/<name>` — verified via
`orca worktree list`), so a single mount of the repo root covers the main
checkout and every mission worktree at once.

The repo is mounted **at its identical host path** inside the container:
`~/repos/devfleet` → `~/repos/devfleet`. Three things fall out:

- **Linked worktrees just work.** A worktree's `.git` is a file holding an
  absolute `gitdir: <repo>/.git/worktrees/<n>` pointer. With the repo at its real
  path, that resolves inside the container with no special-casing —
  `git status`, `commit`, `branch`, and `git worktree list` all behave.
- **No path translation anywhere.** devfleet writes absolute `{worktree}` paths
  into mission briefs and reads markers from `<worktree>/.devfleet/`. Host-side
  and bunker-side paths are the same string.
- **Missions are `exec`s, not creates.** `airlock -C <worktree> -- pi "…"`
  resolves worktree → repo → the repo's container → `engine exec -it -w
  <worktree>`. Container creation happens once per repo, on first use.

Tradeoff accepted explicitly: every mission in a repo shares one container, so
mission A can read and write B's worktree and see its processes. The wall is
repo-vs-host, not mission-vs-mission. Cross-repo isolation is unchanged.

## Naming

The tool is generic — it sandboxes any project, with no devfleet dependency — so
it keeps its own name rather than devfleet's `fleet-*` prefix. Layering reads
`fleet-bunker` (devfleet's seam) → `airlock` (the tool), the same shape as
`fleet-backend` → `orca` and `fleet-forge` → `gh`/`tea`.

| agent-sandbox | airlock |
|---|---|
| `agent-sandbox` (script, repo, docs) | `airlock` |
| `.agent-sandbox/` | `.airlock/` |
| `AGENT_SANDBOX_*` | `AIRLOCK_*` |
| `agentbox-<name>-<hash>` (container) | `airlock-<name>-<key>` |
| `agent-sandbox-base:latest` | `airlock-base:latest` |
| `agent-sandbox-<name>-<hash>:latest` | `airlock-<name>-<key>:latest` |

`.agent-sandbox/` directories are not read; a project scaffolded for the ancestor
re-scaffolds with `airlock init`. Both binaries may sit on `PATH` — they share no
state.

Kept unchanged from the ancestor: the security posture (`--cap-drop=ALL`,
`no-new-privileges`, read-only rootfs, pasta / per-project-bridge networking),
the two approval gates and their content-addressed fingerprints,
`env var > config.toml > built-in default` precedence, `LOCAL_ONLY` keys, the
recipe system, the `:z` vs `:Z` discipline, and "warn, never silently recreate"
on drift. Also kept: the `AGENTS.md` conventions — comments are the spec,
`|| rc=$?` at every `python3` call, init.py's exit-code contract.

## v1 changes

### 1. Repo-keyed identity

**Repo key** = `sha256(realpath of the repo root)[:12]`, where the repo root is
the parent of `git rev-parse --git-common-dir`, falling back to `$PWD` outside a
git repo. It drives the container name, the image tag, and the state root.
Override with `AIRLOCK_KEY` or `[sandbox] key` in `config.toml` (not
`LOCAL_ONLY` — it is a project-wide choice and cannot widen the sandbox).

There is no per-directory identity. Any path inside the repo — the main checkout
or any worktree — resolves to the same container.

Moving or renaming a repo re-keys it, producing a fresh container and state. That
is the same behavior as the ancestor and is left alone.

### 2. Path targeting: `-C DIR`

A global flag, consumed before identity resolution, that `cd`s into `DIR`.
Everything downstream stays `$PWD`-derived; it just acts on a `$PWD` the caller
chose. Applies to every form: `airlock -C /wt/x -- pi "…"`, `airlock -C /repo
init`, `airlock build -C /repo`, `airlock status -C /repo`.

Parsed alongside the existing `--help` pre-scan so it works even when the target
project is broken, and stops at `--` so `airlock -- cmd -C x` passes `-C x` to
`cmd`. Errors when `DIR` is not a directory. No `--path` alias — one spelling.

`-C` sets the **working directory of the exec**; the *container* is still the
repo's. `init` always targets the repo root even when `-C` names a worktree,
since `.airlock/` is committed repo content.

### 3. Mounts

| source | destination | mode | note |
|---|---|---|---|
| repo root | same host path | rw`:Z` | covers main checkout + all worktrees |
| `<state>/home` | `/home/agent` | rw`:Z` | persisted harness auth, history, config |
| `<state>/opt` | `/opt/airlock` | rw`:Z` | agent-installed tools, survives rebuild |

`:Z` is correct now that exactly one container mounts each of these. The
ancestor's optional mounts are unchanged: gh config (`:z`, shared), ssh-agent
socket, engine socket, `[[config]]` entries.

`/workspace` is dropped. The repo lives at its host path and the exec's working
directory is set per call.

**Read-only rootfs is kept**, and `/opt/airlock` is the answer to "let the agent
install things": `make install --prefix=/opt/airlock` and dropped binaries work
and — unlike writes to a writable rootfs — survive image rebuild and container
recreate. The base image creates it and puts `/opt/airlock/bin` on `PATH`.
System packages (`dnf`) still require a Containerfile edit, which is the case
that genuinely belongs in the image.

Not `/usr/local`, which the first implementation tried: a persisted mount there
masks what the image installs into it — starship, bun's `BUN_INSTALL` prefix and
the podman-remote symlink all land in `/usr/local/bin`, and an empty mount hides
them. Verified against a real container before switching.

Rationale for keeping it: the rootfs mode is not the host boundary (namespaces,
uid mapping, cap-drop, no-new-privileges and network isolation are), but with one
long-lived container shared by every mission in the repo, an immutable
`/usr/bin` is what stops mission A from leaving a trojaned `git` for missions B
through Z.

### 4. Resources

No `--memory` or `--cpus` default — the container is shared by every mission in
the repo, and a fixed ceiling sized for one agent is wrong for N. `[resources]`
in `config.toml` still sets them per repo; the docs carry suggested values (8g,
4 cpus) for a repo running several concurrent missions.

`--pids-limit` keeps a default of 4096. It is the one limit that protects the
*host* rather than the agent: a runaway `make -j` or fork bomb with no ceiling
takes the machine down. `[resources] pids` overrides.

### 5. Fail-closed, machine-readable gates

The launcher already refuses rather than prompts; what is missing is a
caller-parseable answer. Exit codes become a contract, documented in `AGENTS.md`
beside init.py's:

| code | meaning |
|---|---|
| 0 | ready / succeeded |
| 10 | `.airlock/Containerfile` unapproved or drifted (needs `--build`) |
| 11 | config gate: a key widens the sandbox, unapproved (needs `--new`) |
| 20 | not scaffolded — no `.airlock/` |
| 21 | approved, but the image is missing |
| 22 | image is newer than the running container — recreate when idle |
| 1 | any other error |

Human-readable stderr stays exactly as it is; the exit code is additive, so
devfleet stops screen-scraping without a human losing the message.

`airlock init --yes`: non-interactive scaffold. `--harness` is required — nothing
in a project says which agent will work in it. Tools default to what detection
found, so `--tools` only overrides. Several harnesses need `--default`. A missing
answer errors with init.py's existing exit 2 (invalid usage), naming the flag to
pass, rather than reaching a prompt. Interactive `init` is unchanged.

### 6. `status` and `build` subcommands

- `airlock status [-C DIR] [--json]` — resolves config and both gates, prints one
  word (`ready`, `unapproved`, `not-scaffolded`, `no-image`, `rebuild-pending`)
  and exits with the matching code. `--json` adds detail: repo key, image tag,
  container name, gate reasons, whether the container exists, runs, and is
  **busy**. Touches the engine only to inspect; never builds, never creates.
- `airlock build [-C DIR]` — builds the project image behind the approval gate,
  then exits. Never creates a container, never launches a harness. This is what
  `--build` cannot provide, since `--build` builds and then runs the agent.

Neither may seed state as a side effect of being asked a question: the seeding
that currently happens at script top (`state/home/.inputrc`, `.bashrc`,
`starship.toml`) moves behind the launch and build paths, so `status` on an
unscaffolded project reports `not-scaffolded` without creating anything.

### 7. Rebuild while missions are live

A rebuilt image does not affect the running container — mounts and image are
pinned at create. Rather than kill live missions, airlock reports it and waits
for idle:

- `status` returns 22 / `rebuild-pending` when the image the container was
  created from differs from the current image ID for its tag.
- **Busy** = any process in the container other than PID 1's `sleep infinity`
  (`engine top`). `--new` refuses on a busy container and names the running
  processes; `--new --force` proceeds.
- Meanwhile agents install what they need into `/usr/local` or `/home/agent`,
  both persisted, so a pending rebuild is never blocking.

devfleet turns 22 into a decision record ("image rebuilt, recreate when the repo
is quiet"), not a spawn failure.

## Testing

The ancestor's bats suites and `test/helpers/fake-engine` carry over with the
rename; the fake engine learns `exec -w` and `top`. New cases:

- `-C DIR` targets identity, config load, and state at `DIR` not `$PWD`; error on
  a non-directory.
- Repo keying: the main checkout and `<repo>/.worktrees/x` resolve the same
  container name, image tag, and state root; `AIRLOCK_KEY` overrides;
  `[sandbox] key` overrides; env beats config.
- Run args: repo mounted at its own host path rw`:Z`; `<state>/opt` at
  `/opt/airlock` and nothing mounted at `/usr/local`; no `/workspace`; no
  `--memory`/`--cpus`; `--pids-limit 4096` present and overridable.
- Second invocation with an existing container execs with `-w <dir>` instead of
  creating.
- Each exit code through the fake engine: unapproved Containerfile → 10, drifted
  → 10, gated config → 11, no `.airlock/` → 20, approved-but-image-gone → 21,
  image newer than container → 22, ready → 0.
- `status --json` shape; `status` creates no files on an unscaffolded project.
- `build` builds and creates no container.
- `--new` refuses when busy, proceeds with `--force`, proceeds when idle.
- `init --yes --harness h` succeeds non-interactively; without `--harness`, exit 1
  naming the flag.

One real-engine test, opt-in behind `AIRLOCK_IT=1`: create a linked worktree, run
`airlock -C <worktree> -- git status`, `git log -1`, and a commit; assert they
work. The fake engine proves the mount *arguments*; only a real container proves
git resolves through them.

## devfleet follow-up (separate spec and plan)

Listed so the contract is legible from both sides; not part of this work.

- `fleet_bunker_wrap` → `airlock -C <worktree> -- <cmd>`. No `--yes` — nothing
  prompts on the launch path.
- `fleet_bunker_built` → `airlock status -C <repo>`, branching on
  0/10/11/20/21/22 so a decision record names the actual reason.
- `fleet-loadout init|build|status` → `airlock init [--yes --harness H] -C P`,
  `airlock build -C P`, `airlock status -C P`.
- **Init is a setup step, never silent.** On exit 20 the Commander records a
  decision offering: init non-interactively with the harness already named in
  `roles.json`, or open a terminal for interactive `airlock init` to pick tools.
- The first-launch gate-clear step (`terminal send --enter` for in-container
  onboarding prompts) stays on every spawn — it is harmless once cleared, and
  with a shared container it is needed only once per repo anyway.
- `tests/helpers/common.bash`'s `fleet_install_fake_bunker` must be rebuilt
  against airlock's real CLI. It currently fakes the invented contract, which is
  why devfleet's bunker tests pass against a CLI that does not exist.
- `docs/superpowers/plans/2026-07-23-devfleet-bunkers.md` records agent-sandbox
  naming and an unticked checklist; update or supersede it.

## Non-goals for v1

- **Egress allow-list** (devfleet spec item 6) — the real isolation posture for a
  remote executor endpoint, but network-filter work with its own design. v1 keeps
  the ancestor's pasta / per-project-bridge behavior.
- **`--env KEY=VAL` passthrough** (item 5) — `[env]` plus `env_file` covers the
  current need.
- **`--ssh` mode** (item 7) — phase 2, remote fleet.
- **Per-mission isolation inside a repo** — explicitly traded away above.
- **Migrating `.agent-sandbox/` projects** — re-scaffold instead.
