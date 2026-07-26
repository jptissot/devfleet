# DevFleet

A deterministic, zero-token bash state machine that runs local-agent development pipelines, fronted by one frontier LLM.

The machine does all the *management* — stage transitions, supervision, restarts, queueing, shipping. LLMs only do stage *work*. No tokens are spent deciding what happens next.

```
mission ──► spec ──► plan ──► execute ──► review ──┬── PASS ──► ready ──► ship
                                            ▲      │
                                            └─ fix ─┘  (max 3 rounds, then park)
```

## The idea

Two roles, strictly separated:

- **The pipeline machine** (`bin/fleet-*`) — plain bash + `jq`. Reads a declarative stage graph, spawns agents, watches them, advances state, ships results. Deterministic and free.
- **The Commander** — a frontier LLM session (e.g. Claude Code). The *interface, not the engine*. It creates missions, answers escalations, reports outcomes. It never polls and never advances a stage.

When the machine needs judgment it writes a **decision record** and (in day mode) wakes the Commander. Records are the source of truth; a lost chat message never loses a decision.

## Status

Working and in use — two campaigns (`m001`, `m002`) have run end to end against a real
repository and shipped. `make check` is green: **334 bats tests**, `shellcheck` clean; the
suite itself runs entirely offline.

New here? [`docs/SETUP.md`](docs/SETUP.md) is the guided path from an empty machine to a
shipped mission. The rest of this file is the reference.

Requires a working [Orca](https://onorca.dev) install — it provides worktrees and terminals. All Orca calls are confined to `bin/fleet-backend`, so a tmux + `git worktree` adapter would be a one-file swap. If your install names the CLI `orca-ide` rather than `orca`, set `ORCA_BIN=orca-ide` (see [Environment](#environment)).

## Requirements

| | |
|---|---|
| Required | `bash`, `jq`, `git`, `orca` |
| Dev | `bats-core` ≥ 1.12, `shellcheck` |
| Optional | `airlock` (bunkers), `gum` (decision TUI), `gh` / `tea` / `tea-axi` (PRs), `lavish-axi` (rich debrief) |

Every optional tool is detected at runtime and degrades gracefully when absent.

## Setup

```bash
git clone <this-repo> devfleet && cd devfleet
make check                                        # shellcheck + bats
```

That is the whole install. Configuration happens on the first Commander session:
`fleet-session-start` detects the harnesses on your `PATH` and writes `config/roles.json`
(`claude`/`codex`/`grok` fill `frontier`, `pi`/`opencode` fill `executor`), validates every
config file, registers the Commander terminal, and relaunches the watcher. Run it first, every
session — it also prints which mode you are in.

A harness outside the detected set is fine; detection only picks the default. Override with:

```bash
bin/fleet-config roles set --role executor --harness omp --cmd omp --bunker true
bin/fleet-config validate
```

`config/roles.json` and `config/fleet.json` are git-ignored; their `.example` files are the
documentation.

Before a mission can ship you also need a project and a repo registered — see
[Quickstart](#quickstart) below, or [`docs/SETUP.md`](docs/SETUP.md) for the guided version
with prerequisites, sandboxing and troubleshooting.

## Quickstart

```bash
# 1. register a project and a repo (needed for shipping)
bin/fleet-project create --name acme
bin/fleet-project add-repo --project acme --repo id:myrepo \
  --path /abs/path/to/repo --default-branch main \
  --forge github --ship-mode local-merge

# 2. create a mission (creates state + an Orca worktree)
bin/fleet-mission --type campaign --project acme --repo id:myrepo \
  --desc "add rate limiting"
# -> m001

# 3. start it — fleet-mission does NOT spawn the first agent
bin/fleet-spawn --mission m001 --stage spec

# 4. supervise (one pass, or run as a daemon)
bin/fleet-watch --tick
bin/fleet-watch --interval 30 &

# 5. see where things stand
bin/fleet-status
```

> **Note:** step 3 is manual by design in day mode — `fleet-mission` creates state but never launches an agent. Night mode's pump does the kickoff automatically (see [Night ops](#night-ops)).

## Mission types

A mission declares its type at creation. Each type is a declarative stage graph in `config/missions/<type>.json` — a custom pipeline is one new file, no script changes.

| Type | Purpose | Stages |
|---|---|---|
| `campaign` | build a feature | spec → plan → execute → review ⇄ fix → ready → ship |
| `strike` | fix a bug from an issue | plan → execute → review ⇄ fix → ready → ship |
| `recon` | investigate, ship nothing | recon → report |
| `fortify` | refactor / tests / perf | audit → execute → review ⇄ fix → ready → ship |
| `blueprint` | interview a human, then write and review a spec | blueprint → review ⇄ refine → ready → ship |
| `sortie` | commander-driven, any order | palette: spec, plan, execute, review, fix, audit, recon |

A type also carries a `description` and a `when_to_use`, both required — the Commander picks a
type from the user's request and otherwise has only a filename to go on. `fleet-config type show
<name>` prints the type's full definition, description and all.

Mission states: the type's stage names, plus `ready | done | parked | blocked | failed`.

Passing `--spec <path>` to a campaign skips the interactive `spec` stage. `--issue <ref>` supplies a strike's issue reference.

## Configuration is the Commander's job

`fleet-config` is the single validated door for every config write, and every write is
journaled:

| Command | Purpose |
|---|---|
| `fleet-config bootstrap [--force]` | detect harnesses, write `roles.json` |
| `fleet-config roles set --role --harness --cmd [--bunker]` | override a role |
| `fleet-config project …` | passthrough to `fleet-project` |
| `fleet-config type {create\|set\|show} --name …` | write a mission type: stage graph or palette |
| `fleet-config prompt {write\|promote} …` | add a prompt template, or promote an ad-hoc brief into one |
| `fleet-config validate [--json]` | schema-check roles, mission types, projects, prompt refs |

Anything that reads config fails closed on malformed JSON, so a bad hand edit is caught rather
than half-loaded.

### Ceilings

`config/fleet.json` holds the caps the Commander cannot raise:

```json
{ "max_spawns_ceiling": 24, "max_mission_seconds_ceiling": 28800 }
```

A mission type's `max_spawns` / `max_mission_seconds` are clamped to `min(type, ceiling)` where
they are read, so editing a type file cannot route around them. `fleet-config` refuses such a
write outright, and a change to `config/fleet.json` itself opens a decision record.

## Drive mode

A mission type declares `"driver": "commander"` in its config (the `sortie` type is commander-driven by default). Commander-driven missions skip `fleet-advance` entirely: the Commander (a frontier LLM session) owns the orchestration loop. The bash watcher keeps supervising at zero token cost by emitting events instead of advancing stages.

The Commander acts through `fleet-drive`:

```bash
bin/fleet-drive brief --mission <id> [--json]   # state, palette, unread events, caps
bin/fleet-drive spawn --mission <id> --stage <palette-name>
bin/fleet-drive spawn --mission <id> --role <role> --prompt-text <text> --label <label>
bin/fleet-drive stop  --mission <id>            # end the current agent, take the mission back
bin/fleet-drive state --mission <id> --set ready|done|parked|blocked|failed [--reason <r>]
bin/fleet-drive ack --mission <id>              # consume unread events
```

An anomaly leaves the agent in place by design — the watcher reports, it does not act. `stop` is how the Commander acts on one: it stops the terminal and returns the mission to `driving`, without spending a spawn. Labels may not be `driving`, `ready`, `done`, `parked`, `blocked`, or `failed`, since a label becomes the mission's stage.

Each spawn is recorded in an append-only per-mission event log (`<mission-dir>/events`). Two hard caps — spawn count and mission wall clock — park fail-closed regardless of Commander intent; the user lifts them with `fleet-decision answer <id> extend`.

Commander instructions live in [`AGENTS.md`](AGENTS.md).

## Completion protocol

The machine never guesses whether an agent finished. Each stage prompt ends with a contract, and the agent must write a marker:

```bash
fleet-done <mission-id> done              # stage complete
fleet-done <mission-id> blocked:<question># needs a human
fleet-done <mission-id> failed:<reason>   # unrecoverable
```

Markers land in `<worktree>/.devfleet/`. They're append-only; `fleet-advance` tracks a cursor so replaying a tick is idempotent. Because markers are files in the mounted worktree, they work identically inside a bunker.

A bunkered agent has no `fleet-done` — the bunker mounts the target repo and the mission
worktree, never devfleet, and the marker path resolves out of `state/`, which is deliberately
kept outside the sandbox. So a bunkered brief asks for the same line by hand:

```bash
printf '%s\t%s\n' "$(date +%s)" done >> <worktree>/.devfleet/<mission>.status
```

Same bytes, same reader — the watcher parses the file, not the call.

`fleet-advance <id>` consumes the newest marker and applies the transition table. Anything unrecognized parks the mission — fail-closed.

**A question is a marker, not a chat message.** `blocked:<question>` becomes a decision record
the Commander answers, and the mission resumes from the question. Nothing in the pipeline reads
an agent's terminal, so an agent that asks there is talking to no one — and worse, a pane
waiting on an answer is indistinguishable from an abandoned one, so the watcher may type over a
human mid-reply. Every brief `fleet-spawn` writes now says this explicitly, as does the
`<EXECUTOR-STOP>` block in [`AGENTS.md`](AGENTS.md).

## The watcher

`fleet-watch` is the heartbeat. One watcher runs at a time, holding `state/.watch-lock`; a
second exits 0 rather than double-supervising. Each tick, for every in-flight mission:

1. Relay anything a bunkered agent spooled for Orca (see [Bunkers](#bunkers)).
2. New marker? → run `fleet-advance`.
3. Terminal gone, exited, or stuck on a trust/permission prompt? → anomaly.
4. Someone typing in the pane? → **not** an anomaly, whatever else is true. See below.
5. State changed? → record progress, then test for a **cycle** (the worktree returning to
   the same hash repeatedly) or a **loop** (the same screens recurring while files churn).
6. Idle at its own prompt, unchanged past `FLEET_STALL_SECONDS`, or past
   `FLEET_BUDGET_SECONDS` for the stage? → anomaly.

A mission with no terminal yet is skipped entirely — it hasn't started, so it can't stall.

**Two anomalies get a gentler answer first.** An agent that ended its turn without finishing
(`idle`) and one going in circles (`loop`) are usually fixed by saying so, and a restart would
throw away the context built so far. Each gets up to `FLEET_NUDGE_LIMIT` nudges — one line
typed into its pane — before falling through to the restart ladder.

The tally is **per stage and only rises**. `fleet-spawn` zeroes it, so a new stage and a
restart each grant a fresh allowance, but progress does not buy more nudges: a nudge provokes
the very activity that would otherwise retire it, so retiring on progress made the limit
unreachable and an agent could be nudged forever without ever escalating.

Everything else **restarts the stage once**, then **parks + escalates**. A restart stops the
old agent before spawning — and if that agent is bunkered, closing the pane only detaches a
pty, so the watcher reaches into the container and kills it by working directory.

### A pane with a human in it is not idle

An agent that asked a question and an agent that quit early look identical from outside: both
sit at a prompt reporting `done`, and neither the Orca hook feed nor `terminal wait`
distinguishes them. So before calling a pane idle or stalled, the watcher checks its input line
for a draft. If someone is part-way through typing, the mission is left completely alone — no
nudge, no restart — because both responses destroy what the operator was writing.

The budget cap is deliberately exempt: a cap a draft could hold open forever is not a cap.

This is the mechanical half of the problem. The protocol half is that an agent should never
ask in its pane at all — see [Completion protocol](#completion-protocol).

```bash
bin/fleet-watch --tick              # single pass
bin/fleet-watch --ticks 10          # bounded
bin/fleet-watch --interval 30       # daemon
```

It writes `state/.watch-beacon` every tick; `fleet-turnend-guard` uses that to block a Commander turn from ending while work is in flight and the watcher is dead.

### An interactive stage is expected to be waiting

A stage graph can mark any stage `"interactive": true` (`config/missions/<type>.json`). This is a
**general stage property** — declarable on any type's stage, not a feature of `blueprint`
specifically; `blueprint`'s interview stage is simply its first user. It says one thing: a human
is expected to be sitting at this stage's terminal, and silence there is the design, not a
failure.

`fleet_detect_anomaly` reads the flag and changes which verdicts it reports:

| Anomaly | On an interactive stage | Why |
|---|---|---|
| `terminal-gone` | fires | the pane is gone, whoever was expected in it |
| `exit:<n>` | fires | the harness exited |
| `blocked:<reason>` (trust / permission / approval) | fires | the agent isn't running to answer for itself |
| `idle` | stands down | a stage waiting on an answer looks exactly like one that quit early |
| `stalled` | stands down | nothing changes in the worktree while a person reads and thinks |
| `loop` | stands down | recurring screens mean a conversation revisiting ground, not a stuck agent |
| `cycle` | stands down | the worktree returns to the same hash because a person is talking, not editing |
| `over-budget` | fires, on a larger cap | an interview is long, not infinite |

The four verdicts that mean "nothing is happening" stand down; the ones a human presence cannot
explain — a dead terminal, an exited harness, a permission gate blocking an agent that isn't
running — still fire. Progress bookkeeping is not uniform, though: the state hash is still
recorded on an interactive stage, but the cycle and loop detectors are skipped outright, so the
`hashes` and `screens` histories they maintain accrue nothing while the stage is interactive.
That is deliberate — both histories are per-mission, not per-stage, so letting a long interview's
recurring screens pile up in that ring buffer could hand the next stage's loop detector a false
`loop` verdict.

The budget grows rather than disappearing. `FLEET_INTERACTIVE_BUDGET_SECONDS` (default `14400`,
four hours) replaces the stage's normal wall-clock cap for as long as the current stage is
interactive, clamped by `max_mission_seconds_ceiling` exactly like every other cap — the
environment can raise it, but not past the one ceiling the Commander may not touch.

That per-stage substitution is what actually protects an abandoned interview: `fleet_detect_anomaly` measures from `stage_started_at`, which every stage transition resets, so `review` and `refine` each start with a full budget regardless of how long the interview ran.

`max_mission_seconds` is a different, mission-wide cap, and on a machine-driven type it is currently inert at runtime. It is read and clamped to the ceiling only in [drive mode](#drive-mode) — the commander-driven lane, through `fleet_pipeline_cap` — and the machine-driven watcher never reads it at all. `blueprint` declares no `driver`, so it runs machine-driven; its `max_mission_seconds: 21600` is config headroom in case it ever becomes commander-driven, not an active runtime protection today.

**This does not replace the draft guard, and the draft guard does not replace this.** [The guard
above](#a-pane-with-a-human-in-it-is-not-idle) only fires once characters are already on the input
line, so it protects an operator mid-reply but does nothing during the part that usually takes
longest — a human reading a question and deciding, before touching the keyboard. `interactive` is
the declared form of that same protection: stated in the pipeline, in force for the whole stage,
rather than inferred from a glyph on screen at the last possible moment. A non-interactive stage
whose agent asks a question in its pane anyway — which the completion protocol forbids but cannot
prevent — still has only the draft guard between it and a nudge. Both mechanisms stay.

## Decision inbox

Every escalation becomes a durable record in `state/decisions/<id>.json`, deduped per mission+stage.

```bash
bin/fleet-decision list --open
bin/fleet-decision show d1 --json
bin/fleet-decision answer d1 resume
bin/fleet-decision footer            # "⏳ 2 pending: [d3] ship? [d5] executor blocked"
bin/fleet-decide                     # gum TUI, if gum is installed
```

Four answers are **mechanical** — applied directly, no LLM:

| Answer | Effect |
|---|---|
| `resume` | un-park and re-spawn from `.last_stage` (stops the old agent first) |
| `ship` | run `fleet-ship` for the mission |
| `init` | scaffold the repo's bunker loadout via `fleet-loadout init` |
| `extend` | grant one fresh drive-cap allowance and hand the mission back to the Commander |

Any other answer wakes the Commander to apply judgment. In night mode nothing wakes — records accumulate for the morning debrief.

## Ship modes

Configured per repo. On review PASS the mission rests at `ready` and a ship-approval decision opens; answering `ship` applies the mode. A repo with `--unattended` ships straight through.

| Mode | Behavior |
|---|---|
| `local-merge` | `git merge --ff-only` into the repo's default branch |
| `direct-PR` | push + open a PR (`tea-axi` → `tea` for Gitea/Forgejo, `gh` for GitHub) |
| `report-only` | record the branch; you integrate manually |

`local-merge` refuses unless the repo is checked out on its default branch, and uses `--ff-only` so a divergent branch fails loudly rather than creating a merge commit. If no forge tool is installed, `direct-PR` degrades to report-only **without** pushing.

Ship credentials are host-side only — a bunkered agent never sees them.

## Night ops

Run the fleet unattended with a bounded concurrency cap.

```bash
bin/fleet-night start --cap 2
bin/fleet-night queue --mission m001    # admission-gated
bin/fleet-night pump                    # also runs automatically each watcher tick
bin/fleet-night debrief
bin/fleet-night end                     # clears night mode, prints the debrief
```

**Admission gate** — no unattended brainstorming. A campaign needs `--spec`, a strike needs `--issue`, recon/fortify need a description. Anything else is rejected and never enters the queue.

**Park, don't ping** — blocked or anomalous missions park and record; the queue pulls the next one. Nothing waits on you. The morning debrief buckets everything: shipped / awaiting approval / parked / blocked / failed / completed.

## Bunkers

The executor role — weakest judgment, hardest walls — runs inside an [airlock](https://github.com/jptissot/airlock) container. v1 is executor-only; frontier stages and the Commander run bare.

airlock is **repo-scoped**: one long-lived container per repo, entered per worktree. So a mission is an `exec` into a container that already exists, not a create — several missions in one repo share the container, its image and its persisted `/home/agent`, and DevFleet never recreates it (that would kill whatever else is running inside).

A repo's **loadout** is its committed `.airlock/` directory:

```bash
bin/fleet-loadout init   --path /abs/path/to/repo   # unattended; harness from roles.json
bin/fleet-loadout build  --path /abs/path/to/repo
bin/fleet-loadout status --path /abs/path/to/repo
```

`fleet-spawn` asks `airlock status` before launching and turns a blocking answer into a decision that names its own remedy:

| airlock exit | state | what fleet-spawn does |
|---|---|---|
| 0 | ready | launches |
| 22 | rebuild-pending | **launches** — the container merely predates the newest image |
| 10 / 21 | unapproved / no-image | decision offering `build` |
| 11 | config gate | decision offering `review-config` |
| 20 | not-scaffolded | decision offering `init` |
| 127 | not installed | decision offering `install-airlock` |

Enable via `"bunker": true` on the role in `roles.json`, or per repo with `fleet-project add-repo --bunker`. All airlock calls live in `bin/fleet-bunker`.

### Hook relay

Orca's agent-hook endpoint listens on `127.0.0.1` only, so an agent inside the bunker cannot
reach it — a separate network namespace has no route to the host's loopback. Rather than
opening the sandbox, the agent appends hook payloads to `<worktree>/.devfleet/orca-hooks.jsonl`
(already mounted) and the watcher relays them from the host each tick, where the receiver is a
local call. A cursor beside the mission, not in the worktree, stops an agent replaying its own
events. See `bin/fleet-hooks`.

This is provisioned per role: the `frontier` role installs an `orca-spool.sh` hook into the
agent's settings. A role whose harness has no such hook simply produces no relayed events.

### Finding what a stage did

```bash
bin/fleet-transcript <mission>          # sessions, oldest first, with harness and timestamp
bin/fleet-transcript <mission> --path   # bare paths, for piping into a reader
```

Do not go looking by hand. Each harness stores sessions in its own layout — `claude` under
`.claude/projects/-a-b-c`, `omp` under `.omp/agent/sessions/--a-b-c--` — and a bunkered stage's
home is airlock's persisted `/home/agent`, not yours. Searching the wrong one returns nothing
and reads convincingly as "there is no record". That mistake cost an hour on `m002` and
produced a confident, wrong report that a removed container had destroyed a stage's evidence;
the 1.4 MB session was intact the whole time.

Because airlock persists `/home/agent` across a container recreate, transcripts survive one.

## Command reference

**Entrypoints**

| Command | Purpose |
|---|---|
| `fleet-project {create\|add-repo\|show}` | project partitions + per-repo ship/bunker config |
| `fleet-mission --type --project --repo --desc [--spec\|--issue\|--id]` | create a mission + worktree |
| `fleet-spawn --mission --stage [--dry-run]` | launch a stage agent (bunker-wraps when enabled) |
| `fleet-done <id> <status>` | completion marker (called *by agents*) |
| `fleet-advance <id>` | apply the transition table |
| `fleet-watch [--tick\|--ticks N] [--interval S]` | supervisor |
| `fleet-status [--json]` | fleet snapshot + open-decision footer |
| `fleet-decision {create\|list\|footer\|show\|answer}` | decision inbox |
| `fleet-decide` | gum TUI for the inbox |
| `fleet-wake <message>` | inject a message into the Commander terminal |
| `fleet-ship <id>` | apply the repo's ship mode |
| `fleet-night {start\|queue\|pump\|debrief\|end}` | unattended operation |
| `fleet-loadout {init\|build\|status} --path` | bunker image lifecycle |
| `fleet-session-start [--no-watch]` | reconcile state on Commander boot; relaunch watcher |
| `fleet-turnend-guard [--beacon-max-age S]` | Stop-hook: block turn end while work is live |
| `fleet-drive {brief\|spawn\|stop\|state\|ack}` | commander-driven mission lane |
| `fleet-config {bootstrap\|roles\|project\|type\|prompt\|validate}` | single validated door for config writes |
| `fleet-transcript <id> [--path]` | locate a mission's agent sessions across harnesses and homes |
| `fleet-hooks relay --mission <id>` | carry a bunkered agent's Orca hook events to the host |

**Libraries** — sourced for their functions, no side effects on source, never run directly:
`fleet-common` (roots, JSON, journal), `fleet-backend` (every Orca call — swap this file to
retarget the backend), `fleet-pipeline` (stage graphs and caps), `fleet-detect` (anomaly
detection, shared by both drivers), `fleet-watch-lib` (pure predicates: hashes, cycles, loops,
drafts), `fleet-bunker` (the one airlock seam), `fleet-forge` (PR creation), `fleet-events`,
`fleet-session-lib`.

`fleet-hooks`, `fleet-night`, `fleet-config`, `fleet-done`, `fleet-decision` and `fleet-drive`
are dual-purpose: sourced for their functions, and runnable as commands.

## State layout

`state/` and `config/roles.json` are git-ignored — state is local and disposable.

```
projects/<name>/project.json     # repos: path, forge, ship mode, unattended, bunker
state/
  missions/<id>/mission.json     # type, stage, worktree, terminal, timers, ship result
  missions/<id>/log              # stage transitions
  missions/<id>/hashes           # worktree-hash history (cycle detection)
  missions/<id>/screens          # screen-digest history (loop detection)
  missions/<id>/events           # append-only spawn log, drive mode
  missions/<id>/hook-cursor      # how far the hook relay has read the agent's spool
  decisions/<id>.json            # decision inbox
  queue                          # night-mode FIFO of mission ids
  journal.log                    # append-only: every spawn/transition/restart/wake/decision
  .mission-seq .decision-seq     # id counters
  .watch-lock/pid                # single-watcher lock
  .fleet-config-hash             # ceiling-change detection
  .night .night-cap .watch-beacon .commander-terminal .wake-pending
```

Per mission worktree, `<worktree>/.devfleet/` holds `<id>.<stage>.brief` (the rendered brief),
`<id>.status` (the append-only marker file), and `orca-hooks.jsonl` (the agent's hook spool).

`journal.log` is the visibility guarantee — one timestamped line per event, greppable.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `FLEET_HOME` | repo root | fleet home |
| `FLEET_STALL_SECONDS` | `900` | no-progress threshold |
| `FLEET_BUDGET_SECONDS` | `2700` | per-stage wall-clock cap |
| `FLEET_INTERACTIVE_BUDGET_SECONDS` | `14400` | wall clock for an interactive stage; clamped by `max_mission_seconds_ceiling` |
| `FLEET_WATCH_INTERVAL` | `5` | daemon tick interval |
| `FLEET_BEACON_MAX_AGE` | `60` | turn-end guard staleness limit |
| `FLEET_NUDGE_SECONDS` | `120` | silence before the screen heuristic calls a pane idle |
| `FLEET_NUDGE_LIMIT` | `2` | nudges per stage before the restart ladder |
| `FLEET_CYCLE_WINDOW` / `FLEET_CYCLE_REPEATS` | `6` / `3` | worktree-hash cycle detection |
| `FLEET_LOOP_WINDOW` / `FLEET_LOOP_REPEATS` | `8` / `3` | recurring-screen loop detection |
| `FLEET_STOP_TRIES` | `10` | polls before a terminal close is called failed |
| `FLEET_COMMANDER_TERMINAL` | — | Commander terminal handle for wakes |
| `FLEET_AGENT_HOME` | — | pin the home `fleet-transcript` searches (used by the test suite) |
| `ORCA_BIN` | `orca` | orca binary name; set to `orca-ide` when the install names it that |
| `ORCA_PANE_KEY` | — | set by Orca; how a session recognises its own pane |
| `ORCA_AGENT_HOOK_{ENDPOINT,STATUS}` | `~/.config/orca/agent-hooks/…` | hook endpoint descriptor and status feed |
| `FLEET_{ROOT,STATE,CONFIG,PROJECTS}_OVERRIDE` | — | relocate roots (used by the test suite) |

## Development

```bash
make check   # shellcheck bin/* && bats tests/
make lint
make test
```

DevFleet has its own airlock loadout, so its toolchain — `bats`, `shellcheck`, `make`, plus the
harness — is pinned in `.airlock/Containerfile` rather than assumed on your host:

```bash
bin/fleet-loadout status --path .          # ready | rebuild-pending | …
airlock -C . -- bash -lc 'make check'      # the suite, in the sandbox
airlock -C .                               # an agent, in the sandbox
```

Feature work belongs on a branch in a worktree. Every worktree under the repo root **shares the
repo's sandbox** — airlock keys the container, image and persisted home off the root — so a new
worktree costs nothing and needs no setup:

```bash
git worktree add .worktrees/my-feature -b my-feature
airlock -C .worktrees/my-feature -- bash -lc 'make check'
```

`.worktrees/` is git-ignored. `fleet-session-start` treats a devfleet worktree as a fleet root,
so develop-mode work behaves there exactly as it does in the main checkout — note that
`fleet_roots` then creates a `state/` inside the worktree, which is deliberate: a branch you are
experimenting on does not share the live fleet's missions and decisions.

Conventions: entrypoints use `set -euo pipefail`; libraries are `# shellcheck shell=bash` with no side effects on source; every function is `fleet_<area>_<verb>`; all JSON goes through `jq`. Tests drive a fake `orca` (and fake `gh`/`tea`/`airlock`) on `PATH` that logs argv and replays canned responses, so the whole suite runs offline.

Design spec and the implementation plans live in [`docs/superpowers/`](docs/superpowers/).

## Known gaps

- **Day-mode kickoff is manual** — `fleet-mission` doesn't spawn the entry stage; run `fleet-spawn` yourself. Only the night pump automates it.
- **Per-project `night_cap` isn't enforced** — the field exists in `project.json`, but concurrency uses the single global `fleet-night start --cap`.
- **airlock is external** — container mechanics (repo mounts, worktree resolution, egress) live in that project, not here. DevFleet only asks `status` and launches with `-C <worktree> --`.
- **`tea-axi` is a separate repo** and must be on `PATH` to be preferred over `tea`.
- **A mission's description is fixed at creation** — `fleet-mission` has no edit path, so a
  scope decision taken mid-mission cannot be written back into the brief the later stages
  receive. `m002` needed its stored description amended by hand after the user narrowed scope,
  or the executor would have been handed instructions the plan had already dropped.
- **The draft guard is glyph-based** — it recognises a prompt line by `❯`, which covers the
  harnesses in use. An unknown TUI simply falls through to the previous behaviour rather than
  being guessed at, so its operator is not protected from a nudge.
- **No per-mission transcript index** — `fleet-transcript` finds sessions by searching known
  layouts, rather than the mission recording where its agent wrote.
- **DevFleet is sandboxed but never missioned** — it has its own loadout (see
  [Development](#development)), yet `AGENTS.md` forbids running a mission against this repo.
  Develop-mode work is done directly, in the sandbox if you want the walls.
- **`bats` is not an airlock recipe** — the loadout installs it from npm in the Containerfile
  because airlock ships no recipe for it and Fedora's package trails the required 1.12.
- **Night mode's admission gate is a hardcoded `case` on type** — `fleet_night_admits`
  (`bin/fleet-night`) lists `campaign`, `strike`, `recon`/`fortify` by name and rejects anything
  else as unknown. That is the right call for `blueprint` — an interview cannot run unattended —
  but by accident of the `case` falling through to its default arm, not because the gate
  understands `interactive` stages or checks for one. A new type is rejected the same way whether
  or not it should be.
- **`fleet-config type create --stage` takes only `name:role:prompt:next`** — a type whose stage
  needs `review`/`on_pass`/`on_fail`, `interactive`, or `terminal` still has to be hand-written
  JSON. `blueprint.json` was.
