# Setting up DevFleet

From an empty machine to a shipped mission. Read [`README.md`](../README.md) first if you want
the concepts; this file is the path.

Roughly 20 minutes, most of it installing Orca and waiting for a container image to build.

---

## 1. Install the tools

**Required.** Nothing works without these.

| Tool | Why | Check |
|---|---|---|
| `bash` ≥ 4 | the machine is bash | `bash --version` |
| `jq` | every piece of state is JSON | `jq --version` |
| `git` | worktrees, merges, shipping | `git --version` |
| [`orca`](https://onorca.dev) | supplies worktrees and terminals | `orca status` |

`orca status` must report the runtime reachable and ready. If your install names the binary
`orca-ide`, export `ORCA_BIN=orca-ide` — nothing else in DevFleet hardcodes the name.

**At least one agent harness.** DevFleet spawns agents; it does not contain one. You need a
*frontier* harness for judgment stages and an *executor* harness for implementation. They can
be the same tool.

Auto-detected: `claude`, `codex`, `grok` fill `frontier`; `pi`, `opencode` fill `executor`.
Anything else works, you just configure it by hand in step 3.

**Development.** Only if you intend to change DevFleet itself.

```bash
bats --version        # bats-core >= 1.12
shellcheck --version
```

**Optional, detected at runtime, degrade cleanly when absent.**

| Tool | Unlocks | Without it |
|---|---|---|
| [`airlock`](https://github.com/jptissot/airlock) | sandboxed executors | agents run on the host |
| `gum` | `fleet-decide` TUI | use `fleet-decision answer` |
| `gh` | GitHub PRs | `direct-PR` degrades to report-only |
| `tea` / `tea-axi` | Gitea/Forgejo PRs | same |
| `lavish-axi` | richer night debrief | plain-text debrief |

---

## 2. Get the repo and prove it works

```bash
git clone <this-repo> devfleet && cd devfleet
make check
```

`make check` is `shellcheck bin/*` then `bats tests/`. Expect **334 passing tests** and no
shellcheck output. The suite is fully offline — it drives fake `orca`, `gh`, `tea` and
`airlock` binaries on `PATH` that log their argv and replay canned responses — so a green run
proves the machine, not your network.

If bats reports failures before you have changed anything, do not continue; a broken machine
will produce confusing mission behaviour later.

---

## 3. First Commander session

The Commander is a frontier LLM session (Claude Code, say) opened **in this directory**. Its
first act, every session, is:

```bash
bin/fleet-session-start
```

This is not optional ceremony. It:

- writes `config/roles.json` by detecting harnesses on your `PATH`, if the file is absent
- validates every config file and reports problems rather than half-loading them
- records the config ceiling hash, so a later edit to `config/fleet.json` opens a decision
- registers this terminal as the Commander, so wakes have somewhere to go
- relaunches the watcher unless you pass `--no-watch`
- reconciles missions whose recorded state drifted from reality
- prints which **mode** you are in, which governs everything else

Two modes, and it tells you which:

- **operate** — fleet work. Act once, then end the turn. Never poll; the watcher wakes you.
- **develop** — feature work on DevFleet itself. Do the work directly, do not spawn a mission
  against this repo.

### Check what it guessed

```bash
cat config/roles.json
bin/fleet-config validate
```

A role needs a `cmd` that starts an agent with its prompt as `$1`, and `bunker: true` if it
should run sandboxed. Override anything:

```bash
bin/fleet-config roles set --role executor --harness omp --cmd omp --bunker true
bin/fleet-config roles set --role frontier --harness claude \
  --cmd 'claude --dangerously-skip-permissions' --bunker true
```

`config/roles.json` and `config/fleet.json` are git-ignored — they are machine-local. The
`.example` files beside them are the documentation. Every config write goes through
`fleet-config`, and every one is journaled.

> A harness that is not auto-detected — `omp`, for instance — is perfectly usable. Detection
> only decides the default; `roles set` decides the truth.

---

## 4. Register a project and a repo

A project is a partition. A repo inside it carries the ship configuration.

```bash
bin/fleet-project create --name acme

bin/fleet-project add-repo --project acme --repo id:myrepo \
  --path /abs/path/to/repo \
  --default-branch main \
  --forge github \
  --ship-mode local-merge
```

| Flag | Notes |
|---|---|
| `--path` | absolute path to a **real git repo**; missions branch worktrees off it |
| `--default-branch` | what `local-merge` merges into, and what PRs target |
| `--forge` | `github`, `gitea`, or `forgejo` — picks the PR tool |
| `--ship-mode` | `local-merge`, `direct-PR`, or `report-only` |
| `--unattended` | optional; ship on review PASS without asking |
| `--bunker` | optional; force sandboxing for every role in this repo |

Ship modes:

- **`local-merge`** — `git merge --ff-only` into the default branch. Refuses unless the repo is
  checked out on that branch. `--ff-only` means a divergent branch fails loudly instead of
  quietly creating a merge commit. Nothing is pushed.
- **`direct-PR`** — push the branch and open a PR. Needs `gh` (GitHub) or `tea`/`tea-axi`
  (Gitea/Forgejo). With neither installed it degrades to report-only **without pushing**.
- **`report-only`** — record the branch and stop. You integrate.

Verify — note the project name is positional here, not a `--project` flag:

```bash
bin/fleet-project show acme            # selector, ship mode, forge, unattended
bin/fleet-project show acme --json     # the whole record
```

---

## 5. Optional: sandbox the executor

Skip this if `airlock` is not installed; agents will run on the host.

The executor role has the weakest judgment and does the most writing, so it is the one worth
walling in. airlock is **repo-scoped** — one long-lived container per repo, entered per
worktree — so several missions in the same repo share a container, its image, and its persisted
`/home/agent`. DevFleet never creates or destroys containers; doing so would kill whatever else
is running inside.

```bash
bin/fleet-loadout init      --path /abs/path/to/repo   # scaffolds .airlock/
bin/fleet-loadout build     --path /abs/path/to/repo   # builds the image
bin/fleet-loadout provision --path /abs/path/to/repo   # runs the roles' provision commands
bin/fleet-loadout status    --path /abs/path/to/repo   # expect: ready
```

`provision` runs each role's `provision` list from `roles.json` inside the container — plugin
installs, onboarding flags, the hook-spool script. Re-run it after a container recreate, since
anything installed into the image rather than the persisted home is gone.

`init` writes a `.airlock/` directory — `Containerfile`, `config.toml` — that is **committed to
the target repo**. Review the Containerfile before building; it defines what your agents can
reach.

`fleet-spawn` asks `airlock status` before every bunkered launch and turns a blocking answer
into a decision naming its own remedy, so you never get a silent failure:

| exit | state | what happens |
|---|---|---|
| 0 | ready | launches |
| 22 | rebuild-pending | **launches** — the container merely predates the newest image |
| 10 / 21 | unapproved / no image | decision offering `build` |
| 11 | config gate | decision offering `review-config` |
| 20 | not scaffolded | decision offering `init` |
| 127 | airlock missing | decision offering `install-airlock` |

Enable per role (`"bunker": true` in `roles.json`) or per repo (`add-repo --bunker`).

---

## 6. Run a mission

```bash
# create state and an Orca worktree
bin/fleet-mission --type campaign --project acme --repo id:myrepo \
  --desc "add rate limiting to the public API"
# -> m001

# start it — creation does NOT launch an agent
bin/fleet-spawn --mission m001 --stage spec

# supervise
bin/fleet-watch --interval 30 &

# look
bin/fleet-status
```

Step two is manual by design in day mode. Only the night pump kicks off automatically.

A campaign runs `spec → plan → execute → review ⇄ fix → ready → ship`. Pass `--spec <path>` to
skip the interactive spec stage; `--issue <ref>` supplies a strike's issue.

Write the description as if briefing a competent stranger. It is interpolated verbatim into
every stage's brief, and — see [Known gaps](../README.md#known-gaps) — it **cannot be edited
afterwards**. A scope decision taken mid-mission will not reach later stages on its own.

### Producing a spec by interview first

If the work isn't written down yet, run a `blueprint` mission before the one that will do the
work. It interviews you, then writes and reviews a spec:

```bash
# interview a human, then write and review a spec
bin/fleet-mission --type blueprint --project acme --repo id:myrepo \
  --desc "rate limiting for the public API"
# -> m002
bin/fleet-spawn --mission m002 --stage blueprint

# the interview runs in that pane — answer it. The stage is declared
# interactive, so the watcher won't nudge or restart it for going quiet
# while you read and think, and won't type over you either.

# once review passes, feed the spec it wrote to the mission that implements it
bin/fleet-mission --type campaign --project acme --repo id:myrepo \
  --desc "rate limiting for the public API" \
  --spec docs/superpowers/specs/2026-07-26-rate-limiting-design.md
```

`--spec` does what it always does here: the campaign skips its own `spec` stage and starts at
`plan`. `blueprint` is never admitted to the night queue — its whole purpose is producing the
artifact an unattended mission needs, not running unattended itself.

### While it runs

```bash
bin/fleet-status                    # stage per mission + open-decision footer
tail -f state/journal.log           # one timestamped line per event
bin/fleet-transcript m001           # what the agents actually did
```

`journal.log` is the visibility guarantee. Every spawn, transition, restart, nudge, wake,
decision and ship lands there as one greppable line.

### Answering decisions

Work stops at a decision when the machine needs judgment.

```bash
bin/fleet-decision list --open
bin/fleet-decision show d1 --json
bin/fleet-decision answer d1 ship
bin/fleet-decide                    # gum TUI, if installed
```

Four answers are mechanical — applied directly, no LLM involved:

| Answer | Effect |
|---|---|
| `resume` | un-park and re-spawn from `.last_stage`, stopping the old agent first |
| `ship` | run `fleet-ship` |
| `init` | scaffold the repo's bunker loadout |
| `extend` | grant one fresh drive-cap allowance |

Anything else wakes the Commander to apply judgment.

### Shipping

On review PASS the mission rests at `ready` and a ship-approval decision opens. Answer `ship`
and the repo's mode applies. A repo registered `--unattended` skips the approval.

---

## 7. Troubleshooting

Every entry below is a failure that actually happened.

**`fleet-status` shows a mission in flight but nothing is moving.**
Check the watcher: `cat state/.watch-beacon` should be within a few seconds of `date +%s`. One
watcher runs at a time behind `state/.watch-lock`; if it died, the lock is cleaned on exit and
`fleet-session-start` relaunches it. Start one directly with `bin/fleet-watch --interval 5 &`.

**A stage finished but the mission never advanced.**
The stage word must be one the pipeline recognises. If `.stage` is `ready`, `done`, `parked`,
`blocked` or `failed`, `fleet_mission_in_flight` is false and the watcher skips the mission
entirely — including its completion marker. Check with
`jq -r .stage state/missions/<id>/mission.json`. `fleet-spawn` sets the stage it spawns, so
this should not recur, but a hand-edited mission file can still produce it.

**An agent asked a question and nothing happened.**
Nothing reads an agent's terminal. The agent must write `blocked:<question>`, which becomes a
decision. If it asked in its pane instead, answer it there yourself — and note the watcher may
have already typed a nudge over your reply if you were mid-sentence. The brief now instructs
against this explicitly.

**A bunkered launch fails with `container … must be in Created or Stopped state`.**
The container was removed or was mid-removal when the launch raced it. Confirm with
`podman ps -a`, then just relaunch — airlock recreates on demand. Verify first with:
`airlock -C <worktree> -- bash -lc 'echo ok'`.

**A container recreate lost tools the agent had installed.**
Anything installed *into* the container image is gone; airlock persists `/opt/airlock` and
`/home/agent` across a recreate, nothing else. A global npm install into `/usr/local` does not
survive. Re-provision, or install into a writable prefix under the persisted home.

**"There is no transcript for this stage."**
Almost certainly wrong. Use `bin/fleet-transcript <mission>` rather than looking by hand —
`claude` and `omp` use different layouts, and a bunkered stage's home is airlock's, not yours.
Searching the wrong one returns nothing and reads exactly like absence.

**Config changes are rejected.**
`config/fleet.json` holds ceilings the Commander cannot raise. A mission type's `max_spawns`
and `max_mission_seconds` are clamped to `min(type, ceiling)` where they are read, so editing a
type file cannot route around them, and `fleet-config` refuses the write outright. Changing
`config/fleet.json` itself opens a decision record. Raising a ceiling is a human act.

**Everything fails with a JSON error.**
Anything that reads config fails closed on malformed JSON — deliberately, so a bad hand edit is
caught rather than half-loaded. `bin/fleet-config validate` names the file and the problem.

---

## 8. Unattended operation

```bash
bin/fleet-night start --cap 2
bin/fleet-night queue --mission m001
bin/fleet-night debrief
bin/fleet-night end
```

The queue is **admission-gated** — no unattended brainstorming. A campaign needs `--spec`, a
strike needs `--issue`, recon and fortify need a description. Anything else is refused entry.

Blocked or anomalous missions park and record; the queue pulls the next one. Nothing waits on
you, nothing wakes you. The morning debrief buckets everything: shipped, awaiting approval,
parked, blocked, failed, completed.

---

## 9. Working on DevFleet itself

DevFleet carries its own loadout, so you do not have to install its toolchain on the host.
`.airlock/Containerfile` pins `bats`, `shellcheck`, `make` and the harness; `config.toml` and
the Containerfile are committed, `config.local.toml` (which seeds your credentials) is not.

```bash
bin/fleet-loadout status --path .          # ready
airlock -C . -- bash -lc 'make check'      # the suite, sandboxed
airlock -C .                               # an agent, sandboxed
```

After changing `.airlock/Containerfile`, rebuild and recreate — a running container keeps the
old image and `status` will say `rebuild-pending`:

```bash
bin/fleet-loadout build --path .
airlock -C . --new                          # recreate; /home/agent survives
```

Feature work goes on a branch in a worktree. Worktrees under the repo root share the repo's
sandbox — airlock keys container, image and persisted home off the root — so a worktree needs
no setup of its own:

```bash
git worktree add .worktrees/my-feature -b my-feature
airlock -C .worktrees/my-feature -- bash -lc 'make check'
```

`fleet-session-start` recognises a devfleet worktree as a fleet root, so develop mode works
there normally. It will create a `state/` inside the worktree — deliberate isolation, so an
experiment does not touch the live fleet's missions and decisions.

Two rules from [`AGENTS.md`](../AGENTS.md) apply to this repo specifically: never spawn a
mission against devfleet, and do the work directly instead.

## Where to go next

- [`README.md`](../README.md) — reference: mission types, drive mode, watcher internals, state layout
- [`AGENTS.md`](../AGENTS.md) — the Commander's and executors' standing instructions
- [`docs/superpowers/`](superpowers/) — design spec and implementation plans
