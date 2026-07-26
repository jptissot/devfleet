# DevFleet — Design Spec

Date: 2026-07-22
Status: Approved (brainstorm session)

## What DevFleet is

An **agent distro** (the cloned repo is the tool) that runs an automated, local-first development pipeline across the repos of your projects, orchestrated by a deterministic machine and fronted by one frontier-LLM "Commander" you talk to.

Three layers, strictly separated:

1. **Pipeline machine** — deterministic bash state machine + watcher. Runs each mission's typed pipeline (e.g. spec→plan→execute→review→fix→ready) unattended. Zero LLM tokens for management; LLMs do stage *work*, never stage *management*.
2. **Commander** — a frontier LLM session (Claude Code) that is the *interface, not the engine*: reports outcomes ("mission 12 review passed — ship?"), fields surfaced problems, answers operator questions or escalates, maintains project memory. Woken by the machine only when judgment or the user is needed. Never polls, never advances stages.
3. **Surfaces** — decision inbox (durable records + TUI), append-only journal, visible Orca terminals.

Launch: start the Orca app, open a terminal in the fleet home (the devfleet clone), run `claude` — it reads `AGENTS.md` and becomes the Commander; `fleet-session-start` reconciles state and starts the watcher.

## Design principles

- **Local-first**: executors are local models (llama.cpp/vllm via Pi/opencode/Claude Code). Frontier spend is limited to spec, plan, review, and Commander judgment. This assumption drives the zero-token machine, loop/stall monitoring, and executor bunkers.
- **Visibility**: every orchestration event is journaled human-readably; every agent runs in a terminal you can watch and type into; every open question is a durable record that cannot scroll away.
- **Restart-proof**: all state on disk; any session can be killed and reconciled.
- **Thin boundaries**: backend calls (spawn/status/read/send/kill, worktree create/rm) live in one backend lib; bunker, decision UI, and forge tooling are each swappable at one-file boundaries.
- **Small**: ~17 single-purpose scripts.

## Non-goals

Multi-backend abstraction, persistent sub-orchestrators, social-media integration, standalone away-mode supervisor daemons, heavyweight pretool policies, multi-gate validation pipelines (no-mistakes-style), quota/tasks/chrome-devtools axi tools, cross-project coordination.

## Fleet home, projects, repos, missions

**One global fleet home** (the devfleet clone), partitioned by project:

- **Project** = a named partition: its own memory, defaults, night-queue caps. Projects are isolated by disk layout, not by process — one Commander, one watcher, one inbox, one journal, one debrief (single pane of glass).
- **Repo** = a git repository registered *under* a project (projects are cross-repo: app + API + infra).
- **Mission** = one unit of pipeline work against **one repo**. Cross-repo features = coordinated sibling missions created by the Commander; cross-repo awareness lives in project memory, not mission mechanics.

Per-project fleet homes are deliberately *possible* (every path is home-relative — `fleet-init` elsewhere works) but not the default, and there is no home-sync machinery.

## Commander memory

`projects/<name>/memory.md` — goals, conventions, active threads, durable context; maintained by the Commander, loaded when working on that project, readable/editable by the user. Plus `projects/<name>/log.md` for decision history the Commander wants to keep. Memory is plain markdown on disk — the Commander's brain is inspectable.

## Mission types

Not every mission runs the same pipeline. A mission declares its type at creation (`fleet-mission --type strike ...`); each type is a declarative pipeline definition in `config/missions/<type>.json`: ordered stages, role per stage (frontier/executor), prompt template per stage, review policy, fix-round limit. `fleet-advance` is data-driven from the type's stage graph — a custom pipeline later is one new file, no script changes.

Built-in types:

| Type | Purpose | Stages |
|---|---|---|
| **campaign** | build a feature | spec → plan → execute → review ⇄ fix → ready → ship |
| **strike** | fix a bug from an issue | plan → execute → review ⇄ fix → ready → ship |
| **recon** | discovery/investigation, no code shipped | recon → report |
| **fortify** | code improvement: refactor, tests, perf, hardening | audit → execute → review ⇄ fix → ready → ship |

Mission states: `<type's stage names> | ready | done | parked | blocked | failed`.

Stage notes:

- **spec** (campaign): frontier agent runs `superpowers:brainstorming` with the user (interactive, own Orca terminal). Output: spec file in the repo worktree (`docs/superpowers/specs/`). Skipped when a spec is provided at creation.
- **plan** (campaign): frontier agent runs `superpowers:writing-plans` from the spec.
- **plan** (strike): frontier agent reads the referenced issue (gh/tea), writes a fix-plan with repro steps.
- **audit** (fortify): frontier agent inspects the repo against the stated improvement goal, writes an improvement plan.
- **recon** (recon): agent investigates the stated question, writes `report.md`; worktree read-only; report surfaced in chat/debrief. No ship.
- **execute**: local agent runs `superpowers:executing-plans` against the mission's plan in the worktree.
- **review**: frontier agent reads `git diff` vs base + the plan, writes `findings.json` with `PASS`/`FAIL` + findings. Light: single diff-vs-plan check.
- **fix**: on `FAIL`, executor respawned in same worktree with findings; after max rounds, park + decision record.
- **ship**: see Ship modes.

### Advancement: `fleet-advance` (deterministic)

Transitions come from the mission type's stage graph; the generic rules (campaign shown as example):

| Event | Action |
|---|---|
| stage done | spawn next stage per mission type (e.g. spec→planner, plan→executor) |
| execute done | spawn reviewer (`fleet-review` collects diff + plan) |
| report done (recon) | mark mission done; surface report |
| review PASS | decision record for approval (default); ship directly only if repo sets `unattended: true` |
| review FAIL, rounds left | respawn executor with findings |
| review FAIL, rounds exhausted | park + decision record; wake Commander (day) |
| agent blocked/question | wake Commander (day) / park + decision record (night) |
| agent dead without marker | wake Commander (day) / park (night) |
| loop/stall detected | restart stage once with fresh context; on repeat, park + decision record |

### Completion protocol (`fleet-done`)

Every stage prompt ends with: "when finished, run `fleet-done <mission-id> <status>`" (`done`, `blocked:<question>`, `failed:<reason>`). Marker written to `<worktree>/.devfleet/` (gitignored) — inside the worktree so it works identically from bare and bunkered operators. The watcher resolves worktrees from `mission.json`. This is the only contract an operator must honor, keeping harnesses swappable.

### Supervision: `fleet-watch`

Bash daemon. Sleeps on marker files + backend liveness. Marker → `fleet-advance`. Anomaly → wake Commander via `fleet-wake`. Heartbeat beacon for liveness checks. Zero tokens idle.

### Loop/stall monitoring (local agents)

Local models loop more than frontier ones. Effect-level detection inside `fleet-watch` (no new daemons, harness-agnostic):

- **Stall**: per poll, hash worktree state (`git status --porcelain` + diff hash); unchanged `stall_minutes` (default 15) while busy → stalled.
- **Cycle**: diff-hash history; repeating pattern (A→B→A→B) → looping (catches edit-revert cycles).
- **Budget**: per-stage wall-clock cap (`execute` default 45 min; per-project/role config).
- **Agent state** (verified primitive): each poll also reads `terminal wait --for tui-idle` — `blockedReason` matching a trust/approval prompt → agent stuck on input (wake/park now, don't wait out the budget); `exitCode≠null` with no marker → dead; `satisfied` with no marker → idle/awaiting input.
- **Action**: first trigger → auto-restart stage once, fresh session + plan + "previous attempt stalled at X" note (fresh context is the cure; nudges rarely work). Second → park + decision record; day mode wakes Commander, which can peek via `orca terminal read`. `restarts` counter in `mission.json`.

Phase 2 option: counting proxy at the local endpoint detecting near-identical repeated completion requests.

### Turn-end guard (slim)

~20-line Claude Code `Stop` hook on the Commander: missions in flight + watcher beacon dead/stale → block turn end with "restart watcher". Commander-harness only.

### Commander boundaries

Read-only over repos. Never edits project code; operators do, in mission worktrees. Commander: creates missions, answers/escalates, routes decisions, reports, ships on approval, maintains memory.

## Session backend: Orca

[Orca](https://www.onorca.dev/) (free, MIT) provides both the session layer (terminals, visibility) and per-mission worktrees:

- Worktree per mission: `orca worktree create --repo id:<r> --name fleet-<mission> --no-parent --setup skip` → `worktree.id` + `path` (recorded in `mission.json`); teardown via `orca worktree rm --worktree id:<id>` after unlanded-work checks (fail closed on id/path mismatch).
- Repo registration: `orca repo add --path` on first mission against a repo.
- Terminals: `orca terminal create --json` (handle recorded), `orca terminal send --text/--enter/--interrupt` (no `--key` flag — verified 2026-07-23), `orca terminal read` (tail lives at `.result.terminal.tail`, cursor-paged).
- Runtime gate: `orca status --json` must report reachable/ready before spawn mutates anything (Orca has no stable CLI version marker).
- Native liveness primitive (verified 2026-07-22): `orca terminal wait --for tui-idle` returns `{satisfied, status, blockedReason, exitCode}` — busy/idle plus *why* blocked. Markers stay the completion signal (they cross bunker walls; RPC does not); tui-idle augments liveness and stall detection.
- Startup gate: a freshly launched agent may block on a trust/approval prompt (`blockedReason: *-trust-*`); `fleet-spawn` clears it (wait tui-idle → `terminal send --enter` → wait idle) before the stage prompt. Conditional (first-time-per-repo / agent-specific), so detect-don't-assume.

**Verification gate (first plan item)**: this CLI surface has been smoke-verified by an existing third-party integration on macOS only. Day-0 step: smoke-test the six verbs on Linux. If it fails, fall back to a tmux + plain-`git worktree` adapter — all backend calls are confined to one backend lib (`spawn / status / read / send / kill / worktree create / worktree rm`), so the swap touches one file. Bonus surfaces from Orca: mobile app (decisions away from desk), inline diff-review UI.

**Linux status (prototyped 2026-07-22)**: `status`, `worktree create/rm`, `terminal create/read/send/wait` verified working end-to-end; marker round-trip and `tui-idle` liveness confirmed with a real agent. Untested: interrupt (`C-c`)/kill, teardown unlanded-work checks. tmux-fallback risk retired for the verified verbs.

## Relationship to Orca orchestration

Orca ships a full orchestration layer (`orca orchestration task-create/dispatch/gate-create/run`, threaded messaging, DAG deps, decision gates). DevFleet **deliberately does not delegate its coordinator to it**:

- **Coordinator stays deterministic.** `orchestration run` takes a natural-language `--spec` and decomposes it agentically — it is LLM-driven, so it burns frontier tokens to *manage*. That is exactly what the zero-token machine avoids; `fleet-advance`/`fleet-watch` stay deterministic.
- **Bunker wall.** `orca orchestration` verbs are RPC to the running runtime. Bunkered executors run `network=none` and cannot reach them, so `worker_done` and `gate` cannot cross the wall. Completion markers (files in the worktree) and the decision inbox (files on disk) remain the source of truth.
- **What DevFleet does consume from Orca:** worktrees, terminals, `terminal wait --for tui-idle` liveness (incl. `blockedReason`), visibility, mobile.
- **Optional graft (mobile decisions):** one-way mirror of open decision records → `orca orchestration gate-create`, purely for the mobile gate UI; `decisions/<id>.json` stays authoritative; behind the optional-axi detection pattern, never required.

## Components

| Piece | Job |
|---|---|
| `AGENTS.md` | slim Commander instructions (incl. decision-footer rule) |
| `bin/fleet-backend` | backend lib: all Orca calls (any fallback adapter lives here too) |
| `bin/fleet-mission` | create mission: state file, worktree via backend, entry stage per provided artifacts |
| `bin/fleet-spawn` | terminal via backend + harness + clear trust/approval gate (wait tui-idle → accept if `blockedReason`) + stage prompt (`--dry-run` supported) |
| `bin/fleet-advance` | state machine transitions |
| `bin/fleet-watch` | watcher daemon + heartbeat + loop/stall detection |
| `bin/fleet-wake` | inject message into Commander terminal |
| `bin/fleet-review` | collect diff + plan → spawn reviewer |
| `bin/fleet-ship` | per-repo ship mode |
| `bin/fleet-project` | create project partition; register repos, modes, role overrides |
| `bin/fleet-status` | fleet snapshot (projects, missions, open decisions) |
| `bin/fleet-done` | stage completion marker writer |
| `bin/fleet-session-start` | reconcile state vs live terminals on Commander boot; restart watcher |
| `bin/fleet-night` | night ops start/end |
| `bin/fleet-decision` | create/list/answer decision records |
| `bin/fleet-decide` | gum decision TUI (dedicated terminal) |
| `bin/fleet-turnend-guard` | Stop-hook script |
| `bin/fleet-loadout` | per-repo bunker loadout: scaffold/build/verify (wraps airlock) |
| `prompts/` | stage prompt templates per mission type |
| `config/` | role→harness map + defaults; `config/missions/<type>.json` pipeline definitions; per-project/per-repo overrides |
| `state/`, `projects/` | runtime state and project partitions |

## Configuration

`config/roles.json` (git-ignored, seeded from example):

```json
{
  "frontier": { "harness": "claude", "cmd": "claude" },
  "executor": { "harness": "pi", "cmd": "pi", "endpoint": "http://localhost:8080/v1", "model": "...", "bunker": true }
}
```

`frontier` runs spec/plan/review; `executor` runs execute/fix. Executor candidates: Pi, opencode, Claude Code on a local endpoint — harness choice is config (`fleet-spawn` maps harness → launch template), not code. Overridable per project and per repo.

## State layout

```
projects/<name>/
  project.json               # repos: path, forge (github|gitea|forgejo), ship mode,
                             # unattended flag, role overrides; night caps
  memory.md                  # Commander memory (durable context)
  log.md                     # Commander decision history
state/
  queue                      # night-mode mission queue (mission ids)
  .night                     # night ops flag
  .watch-beacon              # watcher heartbeat
  journal.log                # append-only: every spawn/transition/restart/wake/decision,
                             # timestamped, human-readable — the visibility guarantee
  decisions/<id>.json        # decision inbox records
  missions/<id>/
    mission.json             # type, project, repo, description, branch, worktree path + orca ids,
                             # stage, fix round, restarts, artifact refs, timestamps
    findings.json            # reviewer output
    log                      # transition log
```

Completion markers live in `<worktree>/.devfleet/` (see Completion protocol). Spec/plan artifacts live in repo worktrees per superpowers convention; `mission.json` holds paths.

## Decision inbox

Every question or escalation to the user is a durable record, never only a chat message (fixes questions lost in scroll).

- Schema: `id`, `mission`, `project`, `question`, `context`, `options` (`{key, label, description}`, may be empty for free-text), `status` (`open`/`answered`), `answer`, timestamps.
- `fleet-decision` create/list/answer; Commander and `fleet-advance` both create records.
- **TUI** (`fleet-decide`): bash + `gum` loop in a dedicated terminal; watches the decisions dir, renders records from the schema (deterministic — no LLM-generated UI), writes the answer back.
- **Answer routing**: watcher sees `answered` → mechanical answers applied by `fleet-advance`/`fleet-ship` directly; judgment answers wake the Commander with the id.
- **Footer rule** (AGENTS.md): every Commander message ends with the open-decision footer, e.g. `⏳ 2 pending: [d3] merge financia? [d5] executor blocked`. Chat answer-by-id ("d3: merge") also works.
- `fleet-status` lists open decisions; the morning debrief includes overnight ones. No re-ping nagging — footer + TUI cover visibility.
- `gum` optional: inbox still works via footer + CLI + chat.

## Ship modes (per repo)

- `local-merge` — fast-forward merge into default branch on approval.
- `direct-PR` — push + open PR, forge-aware: GitHub via `gh-axi`/`gh`; Gitea/Forgejo via `tea-axi`/`tea`.
- `report-only` — user integrates manually.

Approval default: review PASS → decision record; ship on answer. Per-repo `unattended: true` opts into ship-on-PASS. Night holds at report-only unless `unattended`.

## Night ops

`fleet-night start` + `state/queue`. Queued missions must have no interactive stages pending: campaigns need a spec provided; strikes need an issue reference; recon/fortify need a stated question/goal. No unattended brainstorming.

- Pipeline advances as normal; **park, don't ping**: blocked/exhausted/anomalous missions → `parked` + decision record, queue pulls next. Nothing waits on the user.
- Completions held per Ship modes above.
- `fleet-night end` (or next session start) → Commander compiles the morning debrief: shipped / awaiting approval / parked / failed — via `lavish-axi` when available, plain chat otherwise.

## Bunkers (sandboxing via airlock)

A **bunker** is the hardened container an operator works inside — implemented by [airlock](https://github.com/jptissot/airlock), a repo-scoped fork of agent-sandbox built for this (design: [`2026-07-24-airlock-design.md`](2026-07-24-airlock-design.md)). **v1 scope: executor role only** — weakest judgment, hardest walls. Frontier stages and Commander run bare.

- Per-role/per-repo `bunker: true`; `fleet-spawn` wraps: `airlock -C <mission worktree> -- <executor cmd>`. One choke point.
- **One container per repo, entered per worktree** (implemented 2026-07-24): airlock keys identity off the repo root and mounts the repo at its own host path, so every mission worktree shares one container, one image and one persisted `/home/agent`, and a linked worktree's absolute `gitdir:` pointer resolves inside. A mission is an `exec -w <worktree>`, not a create — and DevFleet never recreates a container, since other missions may be live in it.
- Ship credentials host-side only; bunkered operators never see forge creds.
- Markers written into the mounted worktree → bunker-transparent.
- **Orca visibility/control through the wrapper (prototyped 2026-07-23)**: `terminal read`, `terminal send`, and `terminal wait --for tui-idle` all work on a bunkered agent — Orca screen-scrapes the PTY, so the container is transparent (state detection is not lost, contrary to earlier worry). In-container onboarding gates (e.g. claude's trust-folder prompt) clear via `terminal send --enter` — that is `fleet-spawn`'s gate-clear step.
- **Network posture is endpoint-dependent (prototyped 2026-07-23)**: `network=none` blocks *all* egress — fine for a host-local endpoint reached by punch-through, but it also blocks a *remote* endpoint. A remote executor endpoint (e.g. a vLLM host on the LAN) is reached fine over the default `pasta` network — but pasta opens all egress, so the real isolation posture is `pasta` + an **egress allow-list scoped to the endpoint host** (blocker #6, now v1). Local-endpoint case: `host.containers.internal` (auto-resolved to `169.254.1.2`) reaches the host when the endpoint binds `0.0.0.0`; `127.0.0.1`-only needs a host-loopback map.
- **Cred forwarding for cloud harnesses**: a bunker gets a per-repo `/home/agent` (mounted from `${XDG_STATE_HOME:-~/.local/state}/airlock/<key>/home`). The v1 executor is a *local/remote-endpoint* harness with a dummy key (no real auth), so no creds cross the wall. If a cloud-authed harness is ever bunkered, seed its creds into that home dir.
- **Host specifics (prototyped, Fedora + distrobox)**: bind mounts need `:Z`/`:z` or `--security-opt label=disable` (SELinux); airlock invoked inside the distrobox reaches the host podman engine via the `command -v podman` shim (`exec distrobox-host-exec podman`) — no wiring needed.
- Optional: without airlock (or flag unset), executor runs bare. `fleet_bunker_state` reports `not-installed` (127) rather than failing opaquely.

### Loadouts

A **loadout** is a repo's declaration of the tools and dependencies baked into its bunker image. No new format: the loadout *is* the repo's committed `.airlock/` directory (Containerfile + `config.toml`) — airlock already owns toolchain detection and recipes. DevFleet adds `fleet-loadout`:

- `fleet-loadout init <repo>` — scaffold via `airlock init --yes --harness <roles.json executor harness>` (unattended: an interactive prompt would hang the spawn that triggered it).
- `fleet-loadout build <repo>` — build/rebuild the image through airlock's approval gate, without launching an agent.
- `fleet-loadout status [repo]` — is each repo's loadout scaffolded, built, current?

`fleet-spawn` refuses to launch a bunkered operator unless `airlock status` says the repo is launchable, and turns any other answer into a decision naming its own remedy (`init`, `build`, `review-config`, `install-airlock`). `rebuild-pending` (22) is launchable by design — the container merely predates the newest image, and blocking would stall every mission in the repo. Worktrees inherit the loadout because `.airlock/` is committed in the repo.

Upstream work, ranked (status as of 2026-07-24):
1. ~~**Worktree-aware git mounts**~~ — **DONE 2026-07-24 (airlock)**, by a simpler route than planned: airlock mounts the whole *repo* at its own host path, so a worktree's absolute `gitdir:` pointer resolves with no special-casing and no second mount. Orca puts worktrees at `<repo>/.worktrees/<n>`, inside that one mount. Proven by a real-container test (`git status`, `git log`, `git commit` from inside a linked worktree).
2. **Endpoint reachability** (blocker; refined 2026-07-23 by prototype): *remote* endpoints are reached fine over default `pasta` — `network=none` blocks them, so the "none + punch-through" default-deny trick applies only to a *host-local* endpoint. For a local endpoint, `host.containers.internal` reaches the host when it binds `0.0.0.0` (verified); `127.0.0.1`-only needs a host-loopback map (`[network] allow_host_ports` / URL rewrite). Since the real posture is pasta-with-egress, the isolation boundary is #6.
3. ~~**Sandbox key override**~~ — **DONE 2026-07-24 (airlock)** as `AIRLOCK_KEY`/`[sandbox] key`, though worktrees no longer need it: identity keys off the repo root, so they share container, image and `/home/agent` by default. The override now serves separate *clones* that want one sandbox.
4. ~~**Non-interactive create**~~ — **DONE 2026-07-24 (airlock)**: nothing on the launch path prompts (it refuses with an exit code), `status` exposes that as 0/10/11/20/21/22, and `init --yes --harness <h>` scaffolds unattended. Launch under Orca terminals still unverified end-to-end.
5. **CLI env passthrough** (`--env KEY=VAL`) for per-mission vars. Deferred: `[env]` + `env_file` cover the current need.
6. **Egress allow-list wiring** (v1 — promoted from "later"; still OPEN and now the top remaining bunker gap: a bunkered executor runs on pasta with open egress today): with a *remote* endpoint, pasta must stay up (can't use `network=none`), so scoping egress to the endpoint host is the actual isolation boundary, not optional. Also: container name/label for mission↔container correlation.
7. Later (remote path): **`--ssh` mode** — sshd/dropbear as agent user, per-sandbox keypair, published port (loopback default; LAN behind approval gate).

### Phase 2 sketch: remote fleet over ssh bunkers

Headless box runs DevFleet + bunkers with `--ssh`; Orca desktop/mobile connects via its SSH-worktree mode as the visibility surface. Isolation and UX decoupled: airlock owns the walls, Orca owns the windows; plain `ssh` works without Orca. Worktrees stay host-mounted — ssh is access only, so host-side review/ship read the diff directly. Not v1.

## axi integrations (optional)

- **lavish-axi** — rich reports only (findings detail, morning debrief). Decisions go through the inbox.
- **gh-axi** — GitHub ops for `direct-PR`. Plain `gh` fallback.
- **tea-axi** — Gitea/Forgejo ops for `direct-PR`. Plain `tea` fallback. Does not exist yet: companion sub-project (own spec), axi-style wrapper over the Forgejo/Gitea API. DevFleet depends only on its CLI surface (`tea-axi pr create`, `tea-axi pr status`).

All optional: detected at session start, never required.

## Error handling

- Blocked agent: marker → Commander woken → answers or escalates via decision record. Night: parked + record.
- Dead terminal without marker: watcher detects → Commander woken. Night: parked.
- Fix rounds exhausted: parked + record (+ Commander wake in day mode).
- Watcher death: turn-end guard blocks blind stops; `fleet-session-start` restarts watcher.
- Restart: state on disk; `fleet-session-start` reconciles missions vs live terminals, journals drift.

## Dependencies

Required: Orca (app + CLI; Linux smoke test = first plan item), git, jq, frontier harness (Claude Code), executor harness (Pi or opencode) + local endpoint (llama.cpp/vllm).
Optional: airlock + podman/docker, gum, lavish-axi, gh-axi, tea-axi (companion sub-project), gh, tea.

## Testing

- `shellcheck` on all scripts.
- bats tests for `fleet-advance` transitions with fake state dirs (env-overridable roots).
- Backend lib tested against a fake `orca` on `PATH` (airlock's fake-engine pattern); `fleet-spawn --dry-run` for pipeline tests.
- Watcher tested with synthetic markers and diff-hash sequences (stall/cycle cases).
- Day-0 Linux smoke test for the six Orca CLI verbs.
