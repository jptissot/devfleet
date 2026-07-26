# DevFleet — Session-Start Mode Briefing — Design Spec

Date: 2026-07-24
Status: Approved (brainstorm session)
Supersedes nothing; extends `2026-07-24-devfleet-commander-drive-design.md`.

## The problem

An agent session that opens in this repo does not reliably know what it is.

`AGENTS.md` carries every Commander rule and opens with `You are the **Commander** of this
fleet.` Claude Code does not load `AGENTS.md` — it loads `CLAUDE.md`, and this repo has none.
A session therefore learns its own identity by chance: if it happens to `ls` the repo root it
becomes the Commander, and if it does not it starts editing bash scripts as an ordinary coding
agent with no idea a fleet exists.

The same file causes the mirror-image failure. Mission worktrees are git worktrees of this repo,
so they carry every tracked file, `AGENTS.md` included. An executor spawned into a devfleet
worktree reads *You are the Commander of this fleet* and inherits rules written for a role it
does not hold — including **never poll, end your turn**, which makes an executor stop mid-task
waiting for a wake that is not coming for it.

`bin/fleet-session-start` is the natural place to fix both and today says nothing about role.
Its entire output is `reconciled 0 missions, 0 drifted`.

## Three modes

| | `operate` | `develop` | `execute` |
|---|---|---|---|
| The agent is | the Commander | an ordinary coding agent | a mission executor |
| Where it runs | the fleet root | the fleet root | a mission worktree |
| The work | missions, decisions, reports | features on devfleet itself | the brief, and only the brief |
| `fleet-*` commands | the whole job | not used | `fleet-done` at the end |
| End of turn | act once, **end turn**, watcher wakes you | work the task to completion | work the brief to completion |

`develop` exists because feature work on devfleet is done **directly, by the agent in this
checkout**. It is never delegated to a mission spawned against devfleet. The end-your-turn rule
is correct for `operate` and actively wrong for `develop`; a briefing that does not say which
rulebook is live is worse than no briefing.

## Detection

`bin/fleet-session-start` resolves the mode by precedence. First match wins.

1. **A `.devfleet/*.brief` file exists in the working tree** → `execute`.
   `fleet-spawn:86` writes the rendered brief to `$WT/.devfleet/<mission>.<stage>.brief`, so its
   presence is the marker of a mission worktree.
2. **This is the fleet root** — `git rev-parse --git-dir` equals `--git-common-dir`, i.e. not a
   linked worktree → `operate` or `develop`. First-run bootstrap of `roles.json` is unchanged
   and still happens here; a missing `roles.json` is a fresh fleet, not a wrong location.
3. **A linked worktree with no brief** → print the reason and exit non-zero. Do not bootstrap.

Order is load-bearing. Precedence 1 must be evaluated **before** anything else: an executor that
inherits `FLEET_HOME` from the spawning environment resolves to the real fleet root, and any
state-based check would read it as the Commander. The worktree marker cannot be inherited.

Detection is by **location**, not by the presence of state, for the same reason. State can be
inherited through the environment; `--git-dir` versus `--git-common-dir` describes the checkout
the agent is actually standing in.

Rule 3 replaces today's implicit behavior. `fleet_roots` derives `FLEET_HOME` from the script's
own directory, so running `fleet-session-start` from a worktree copy currently creates a second
`state/` tree inside that worktree. It fails closed instead.

### `operate` vs `develop`

Inferred from the request, not from a flag. There is no mode file, no env var, no sticky state.

The briefing instructs the agent to **state the mode it inferred as its first line, before
acting**. A wrong inference then costs the user one word to correct instead of a wasted turn.
Silent guessing is the failure this design exists to remove; announcing is what makes inference
safe enough to rely on.

## One source of truth

`bin/fleet-session-start` is the only place the briefing text is written. No rule is duplicated
into markdown, because two copies drift and the copy the agent reads is the stale one.

`operate` / `develop` briefing, replacing the current one-line output:

```
DEVFLEET — you are the Commander of this fleet.
fleet: idle | 0 missions in flight | 0 open decisions
reconciled 0 missions, 0 drifted

MODE: state which mode you are in as your first line, before acting.
  operate  — fleet work: missions, decisions, reports on fleet repos.
             Act once, then END YOUR TURN. Never poll. The watcher wakes you.
  develop  — feature work on devfleet itself, here in this checkout.
             You do the work directly. Do not spawn a mission against devfleet.
             The end-your-turn rule does not apply; work the task to completion.
Infer from the request. Announce the inference. One word from the user corrects it.
```

Line 2 renders live counts from the same state `fleet-status` reads, so `operate` arrives
pre-briefed; when missions are in flight they are named and open decisions are listed.

`execute` briefing:

```
DEVFLEET — you are a mission executor, not the Commander.
mission <id>, stage <stage>
Your brief is .devfleet/<id>.<stage>.brief. It is the whole job.
Do not spawn, advance, ship, or answer decisions. AGENTS.md is not addressed to you.
When finished: fleet-done <id> done|blocked:<question>|failed:<reason>
```

## Delivery

Two paths, one source.

- **`.claude/settings.json`** — a `SessionStart` hook runs `bin/fleet-session-start` and the
  harness injects its stdout into context. This is the path that actually fixes *the agent did
  not know*, because it does not depend on the model choosing to read a file. The file is
  **tracked**, so it reaches worktrees too — which is correct once `execute` is detected, since
  an executor then gets the executor briefing rather than none.
- **`CLAUDE.md`** (new) and **`AGENTS.md`** (existing) — for harnesses with no hook. `roles.json`
  fills `frontier` from `claude`, `codex`, or `grok`, so the markdown path is not optional.

Both files carry the same two lines and no rules of their own: run `bin/fleet-session-start`,
then obey its briefing.

## `AGENTS.md` restructure

- A **stop-clause as the first block**, before any Commander framing: *if a `.devfleet/` brief
  exists beside this file, it is not addressed to you — read your brief instead.* An executor
  whose harness never runs `fleet-session-start` still meets this on line 1. Same shape as the
  `<SUBAGENT-STOP>` block in the superpowers skills.
- A short mode preamble pointing at `fleet-session-start`.
- Today's 62 lines moved verbatim under an **Operate** heading. No rule changes.
- A short **Develop** section: ordinary engineering work, TDD, `make check` before claiming done,
  no `fleet-*` calls, and no mission spawned against devfleet.

## Prerequisite — single-instance guard in `fleet-watch`

In scope for this change, not deferred.

`bin/fleet-watch:29` writes a beacon and nothing else. There is no pid file and no `flock`, so
nothing prevents a second watcher. Today that never bites because one human runs
`fleet-session-start` once per session. Under this design the hook runs it *and* `AGENTS.md`
tells the agent to run it — two watchers on every session, both advancing stages against the
same state.

`fleet-watch` gains a pid file in `$FLEET_STATE`, a liveness check on the recorded pid, and a
silent `exit 0` when a live watcher already holds it. A stale pid file (process gone) is claimed,
not honored.

## Testing

`tests/fleet-session-start.bats` (4 tests today) extends with the helpers it already has —
`fleet_setup_home`, `fleet_seed_config`, `fleet_install_fake_orca`:

- the `operate`/`develop` briefing names both modes and the announce rule
- mission and decision counts render from seeded state
- a seeded `.devfleet/<id>.<stage>.brief` yields the `execute` briefing, names the mission and
  stage, and does **not** print the Commander line
- `execute` wins over a present fleet state, including when `FLEET_HOME` points at the real root
- a linked worktree with no brief → non-zero exit, no `state/` created
- the existing bootstrap test still passes: fleet root with `roles.json` absent bootstraps and
  briefs, rather than being read as a wrong location
- a second `fleet-session-start` spawns no second watcher; a stale pid file is claimed

## Out of scope

- **No mode flag, env var, or sticky state** for `operate`/`develop`. Inference plus
  announcement. If announcement proves unreliable in practice, a flag layers on top later;
  nothing here forecloses it.
- **No change to the Commander rules themselves.** They move under a heading; they do not change.
- **No change to spawn, advance, ship, or the drive lane.**

## Retained decision

The `devfleet` project and repo registered this session stay. Under `execute` detection a mission
targeting devfleet is now safe — the executor is told what it is — so the registration is a
usable path for unattended or night-mode work on this repo, rather than the trap it would have
been without mode detection.
