# DevFleet — Commander-Driven Missions and Config Authority — Design Spec

Date: 2026-07-24
Status: Approved (brainstorm session)
Supersedes nothing; extends `2026-07-22-devfleet-design.md`.

## What this adds

Two things, joined: a second way to run a mission, in which the **Commander owns the
orchestration loop** — the [firstmate](https://github.com/kunchenguid/firstmate) model —
alongside today's machine-driven pipelines, which are unchanged; and **Commander authority over
configuration**, so that driving a mission does not stop at a config file the user has to edit
by hand.

| | Machine-driven (today) | Commander-driven (new) |
|---|---|---|
| Who picks the next step | `fleet-advance` + the type's stage graph | the Commander |
| Order of stages | fixed by `config/missions/<type>.json` | any order, any number of times |
| Anomaly response | restart once, then park | event + wake; the Commander chooses |
| Review verdict | `findings.json` read by `fleet-advance` | read by the Commander |
| Token cost when idle | zero | zero (the watcher never calls an LLM) |

The watcher stays a zero-token bash daemon in both modes. What changes is what it does when
something happens: in drive mode it **reports instead of deciding**.

## Design principles carried over

- **Records are the source of truth.** Wakes are nudges. Every drive event is a durable
  append-only record with a cursor, so a lost chat message loses nothing.
- **Fail closed.** The Commander gains authority over *sequencing*, not over the hard caps.
- **One choke point per seam.** All drive-lane logic lives in `bin/fleet-drive` and
  `bin/fleet-events`; existing scripts get one branch each.
- **Small.** Three new scripts, one new mission type, one new doc.

One principle is new: **no hand configuration the Commander could do itself.** Setup, projects,
repos, mission types, palettes, and prompt templates are all writable by the Commander through
one validated command surface. The only thing it must not write is its own leash (see Ceilings).

## The `driver` field

`config/missions/<type>.json` gains an optional top-level `"driver"`:

- `"machine"` — today's behavior. **Default when the field is absent**, so `campaign`, `strike`,
  `recon`, and `fortify` files need no edit.
- `"commander"` — drive mode. The file carries no `entry` and no `stages`; it carries a
  `palette` and caps instead.

`bin/fleet-pipeline` remains the only reader of mission-type data. It gains:

```
fleet_pipeline_driver <type>                  # machine | commander
fleet_pipeline_palette_field <type> <name> <field>   # role | prompt
fleet_pipeline_has_palette <type> <name>
fleet_pipeline_cap <type> <field>             # max_spawns | max_mission_seconds
```

## The `sortie` type

Ships with the feature as the reference drive-mode type:

```json
{
  "type": "sortie",
  "driver": "commander",
  "palette": [
    { "name": "spec",    "role": "frontier", "prompt": "spec.txt" },
    { "name": "plan",    "role": "frontier", "prompt": "plan.txt" },
    { "name": "execute", "role": "executor", "prompt": "execute.txt" },
    { "name": "review",  "role": "frontier", "prompt": "review.txt" },
    { "name": "fix",     "role": "executor", "prompt": "fix.txt" },
    { "name": "audit",   "role": "frontier", "prompt": "audit.txt" },
    { "name": "recon",   "role": "frontier", "prompt": "recon.txt" }
  ],
  "max_spawns": 12,
  "max_mission_seconds": 14400
}
```

The palette is a set, not a sequence: no `next`, no `on_pass`, no `on_fail`, no
`fix_round_limit`. A different drive type is a new file with a different palette or different
caps — no script changes, same property the stage graph already has.

## Mission state

`mission.json` gains five fields, written at creation:

| Field | Meaning |
|---|---|
| `driver` | resolved from the type at creation; `machine` or `commander` |
| `spawn_count` | drive-mode spawns since the last extension, checked against `max_spawns` |
| `mission_started_at` | epoch of the last extension (creation, initially), checked against `max_mission_seconds` |
| `event_cursor` | events the Commander has acknowledged |
| `extends` | how many times the user has answered `extend`; audit only |

For a drive mission, `.stage` is a **free-text label**, not a graph node: the palette name or
ad-hoc `--label` of the agent currently running, or the sentinel `driving` when no agent is in
flight. `fleet-mission` sets `stage=driving` at creation for `driver=commander` (there is no
`entry` to read) and, as today, spawns nothing.

### `fleet_mission_in_flight`

`fleet_pipeline_is_stage` is currently used as an "is this mission in flight?" predicate in
`fleet-watch`, `fleet-turnend-guard`, `fleet-session-start`, and `fleet_night_active_count`. A
drive mission has no graph, so that predicate returns false and drive missions would be
invisible to supervision, the turn-end guard, and the night active count.

It is replaced at those four call sites by a new `fleet-common` predicate:

```
fleet_mission_in_flight <id>
  driver=machine    -> fleet_pipeline_is_stage <type> <stage>      (unchanged behavior)
  driver=commander  -> stage not in {ready,done,parked,blocked,failed}
```

`fleet_pipeline_is_stage` itself stays as-is; only its use as an in-flight test moves.

## Components

### `bin/fleet-events` (new, sourced library)

Append-only event log per mission at `state/missions/<id>/events`, one JSON object per line:
`{ts, kind, detail}`. `kind` is one of `marker`, `anomaly`, `cap`, `note`.

```
fleet_events_append <id> <kind> <detail>
fleet_events_unread <id>            # lines past .event_cursor
fleet_events_count <id>
fleet_events_ack <id> <count>       # set .event_cursor
```

The cursor lives in `mission.json`, mirroring `marker_cursor`: replaying a watcher tick emits
nothing twice, and a Commander that dies mid-turn re-reads the same unread events.

### `bin/fleet-drive` (new, dual-use — sourceable and runnable)

The entire drive lane. Runnable subcommands are the Commander's API:

| Command | Behavior |
|---|---|
| `fleet-drive brief --mission <id> [--json]` | mission state, palette, unread events, open decisions, remaining caps — one call per turn |
| `fleet-drive spawn --mission <id> --stage <palette-name>` | cap check → `spawn_count++` → delegate to `fleet-spawn` |
| `fleet-drive spawn --mission <id> --role <r> --prompt-text <t> --label <l>` | ad-hoc escape hatch, same cap check |
| `fleet-drive stop --mission <id>` | stop the current agent, return the mission to `driving`; no spawn spent. How the Commander acts on an anomaly, which leaves the agent in place |
| `fleet-drive state --mission <id> --set <ready\|done\|parked\|blocked\|failed> [--reason <r>]` | the Commander ends the mission |
| `fleet-drive ack --mission <id>` | acknowledge unread events (also done implicitly by `spawn` and `state`) |

Sourced by the watcher:

```
fleet_drive_check <id>   # the drive lane's per-tick logic
```

`fleet_drive_check` runs, in order:

1. **New marker?** → `fleet_events_append <id> marker <verb>`, advance `marker_cursor`, set
   `.stage=driving`, clear `.terminal`, `fleet-wake`. It never applies a transition table.
2. **Wall-clock cap blown?** (`now - mission_started_at >= max_mission_seconds`) → stop the
   terminal, park, `fleet_events_append <id> cap wall-clock`, decision record. Fail-closed, and
   the only place the machine overrides the Commander mid-agent.
3. **Anomaly?** — the existing `fleet-watch-lib` predicates plus backend liveness: terminal
   gone, non-null exit code, trust/permission `blockedReason`, stall, edit-revert cycle,
   per-stage budget → `fleet_events_append <id> anomaly <reason>` + wake. **No restart, no
   park.** The stage stays as it is and the agent is left running; the Commander decides whether
   to stop it, respawn, spawn something else, or park.
4. `.stage=driving` (nothing spawned) → detection is skipped entirely; an idle drive mission
   cannot stall.

Anomaly events are deduped per `(stage, reason, spawn_count)` so a stalled agent produces one
event, not one per tick.

### `bin/fleet-config` (new, dual-use)

The single door for every configuration write, all journaled. It exists so that setup and
pipeline definition are things the Commander does in chat, not things the user does by hand.

| Command | Behavior |
|---|---|
| `fleet-config bootstrap [--force]` | detect harnesses on `PATH`, write `config/roles.json`, report the choices; idempotent, refuses to clobber without `--force` |
| `fleet-config roles set --role <r> --harness <h> --cmd <c> [--bunker true\|false]` | override one role |
| `fleet-config project …` | argv passthrough to `fleet-project` — one door for the Commander, one implementation underneath |
| `fleet-config type create --name <t> --driver <d> [--palette <name>:<role>:<prompt> …] [--max-spawns N] [--max-seconds S]` | write `config/missions/<t>.json` |
| `fleet-config type set --name <t> …` / `type show --name <t>` | amend or inspect a type |
| `fleet-config prompt write --name <f> --text <t>` | new prompt template under `prompts/` |
| `fleet-config prompt promote --mission <id> --label <l> --name <f>` | promote an ad-hoc drive brief that worked into a reusable palette prompt |
| `fleet-config validate [--json]` | schema-check `roles.json`, every `config/missions/*.json`, every `projects/*/project.json`, and that every referenced prompt file exists |

**Bootstrap rule.** Known frontier harnesses (`claude`, `codex`, `grok`) fill `frontier`; known
local-model harnesses (`pi`, `opencode`) fill `executor`. If only one is present it fills both
roles, journaled and reported so the user can correct it with `roles set`. `config/roles.json`
stays git-ignored; `roles.json.example` stays as documentation, not as a setup step.

**Fail closed on bad config.** `fleet_pipeline_*` and `fleet-spawn` validate before use.
Malformed JSON, an unknown driver, or a palette entry naming a missing prompt file dies with the
validation error; on a drive mission it is also appended as an event, so the Commander sees its
own mistake in the next `fleet-drive brief` instead of a silent failure.

### Changes to existing scripts

| File | Change |
|---|---|
| `bin/fleet-watch` | first lines of `fleet_watch_check`: `driver=commander` → `fleet_drive_check "$id"; return 0` |
| `bin/fleet-advance` | dies on a drive mission: "mission <id> is commander-driven" |
| `bin/fleet-spawn` | new `--role`/`--prompt-text`/`--label` flags; with `--stage` on a commander-driven type, resolve role+prompt from `palette` instead of `stages` |
| `bin/fleet-mission` | resolve and record `driver`; `stage=driving` and no `entry` lookup for drive types; write the three new fields |
| `bin/fleet-night` | `fleet_night_admits` rejects `driver=commander` explicitly (today's `*)` default already rejects unknown types; the explicit case exists for the error message) |
| `bin/fleet-common` | `fleet_mission_in_flight` |
| `bin/fleet-session-start` | run `fleet-config bootstrap` when `roles.json` is missing; run `fleet-config validate` always; record the ceiling hash |
| `.gitignore` | `config/fleet.json` alongside `config/roles.json` |
| `bin/fleet-decision` | `fleet_decision_resume` and the new `extend` answer become driver-aware (below) |
| `bin/fleet-status` | show `driver` and unread-event count for drive missions |
| `README.md` | mission-type table gains `sortie`; mechanical-answer table gains `extend`; drive-mode and `fleet-config` sections; Setup drops to `git clone && make check` |

`fleet-spawn`'s brief rendering, the appended `fleet-done` contract footer, bunker wrapping, and
the loadout fail-closed gate are all untouched — they key on role and worktree, not on the graph.

## Commander protocol (`AGENTS.md`)

The repo currently has no `AGENTS.md`; nothing tells a frontier session it is the Commander.
This feature adds one, covering both modes. Drive-mode contract:

1. On wake (or session start with unread events): `fleet-drive brief --mission <id>`.
2. Decide. Spawn the next step, end the mission, or answer/raise a decision.
3. Never poll. Never loop waiting. End the turn — the watcher will wake you.
4. Read `findings.json` yourself after a `review` spawn; the machine does not read it in drive
   mode.
5. You may not lift a cap. A cap-parked mission needs the user to answer `extend`, and
   `config/fleet.json` is not yours to edit.

Config authority, both modes:

6. Setup, projects, repos, mission types, palettes, and prompt templates are yours — write them
   with `fleet-config`, never by hand-editing the JSON, so the write is validated and journaled.
7. `fleet-config validate` before relying on a config you just wrote. A validation failure on a
   drive mission also arrives as an event.

## Data flow

```
fleet-mission --type sortie …          driver=commander stage=driving spawn_count=0 (no spawn)
Commander: fleet-drive brief           palette, 0 unread
Commander: fleet-drive spawn --stage plan
                                       caps ok → spawn_count=1 → fleet-spawn → orca terminal
                                       stage=plan, timers reset
agent:     fleet-done m001 done        marker in <worktree>/.devfleet/
watcher:   fleet_drive_check           marker_cursor++ → events += {marker,done}
                                       stage=driving, terminal=null → fleet-wake
Commander: fleet-drive brief           1 unread → ack → decides → spawn execute → …
Commander: reads findings.json         the PASS/FAIL call is the Commander's
Commander: fleet-drive state --set ready
                                       ship decision record (or auto-ship on an --unattended repo)
user:      fleet-decision answer d7 ship
                                       existing fleet-ship path, unchanged
```

## Caps and guardrails

The Commander decides recovery; two caps it cannot argue with:

| Cap | Enforced at | Effect |
|---|---|---|
| `max_spawns` | `fleet-drive spawn` | refuse the spawn, park the mission, record a decision |
| `max_mission_seconds` | watcher tick | stop the terminal, park, record a decision |

Both values come from the mission type — which the Commander can now write — so the effective
cap is `min(type value, ceiling)` (see Ceilings).

Both park fail-closed and journal. Because a parked mission's Commander would just be refused
again, cap-park decision records offer a new **mechanical answer, `extend`**: it sets
`spawn_count=0`, `mission_started_at=now`, `extends++`, un-parks to `stage=driving`, and wakes
the Commander — one fresh allowance of both caps. Lifting a hard cap is the user's call, not the
Commander's; that is the point of the cap.

`resume` on a drive mission becomes driver-aware: instead of re-spawning `.last_stage`, it stops
any live terminal, sets `stage=driving`, and wakes the Commander. Machine-side re-spawning would
be the machine driving.

## Ceilings

`config/fleet.json` — user-owned, git-ignored, with a committed example:

```json
{ "max_spawns_ceiling": 24, "max_mission_seconds_ceiling": 28800 }
```

`fleet_pipeline_cap` returns `min(type value, ceiling)`. The clamp is applied **where the cap is
read, not where it is written**, so a Commander that hand-edits `sortie.json` to
`max_spawns: 999` still gets 24. `fleet-config type` additionally refuses such a write up front,
but that is ergonomics; the read-time clamp is the enforcement. Built-in defaults apply when the
file is absent, so it is not a setup step either.

Honest limit: the Commander has file-write tools, so nothing physically prevents it editing
`config/fleet.json`. The mitigation is detection, not prevention:

- `AGENTS.md` declares the file off-limits, and `fleet-config` has no subcommand that writes it.
- `fleet-session-start` records `sha256(config/fleet.json)` in `state/.fleet-config-hash`.
- The watcher compares each tick; a changed hash opens a decision record for the user and
  journals `ceiling-drift`.

A user editing their own ceilings answers that decision once; a Commander editing them is
visible immediately rather than silently.

## Ship path

Unchanged mechanics, new trigger. `fleet-drive state --set ready` does what `fleet-advance` does
on a review PASS: auto-ship when the repo is `--unattended`, otherwise open a ship decision with
the existing `ship` / `hold` options and wake in day mode. `fleet-ship`, the ship modes, and
host-side-only credentials are untouched. A bunkered agent still never sees them.

## Night ops

Drive missions are **barred from the night queue**. A mission whose driver is asleep cannot run
unattended, and `fleet-night queue` says so rather than admitting a mission that will sit until
morning. Machine-driven night ops are unaffected.

Drive mode is therefore day-mode-only in v1. Wakes still degrade to `.wake-pending` when no
Commander terminal is registered, and events remain readable whenever the Commander returns.

## Error handling

| Case | Behavior |
|---|---|
| unrecognized marker | event `marker:unrecognized`, `stage=driving`, **no auto-park** — the Commander judges |
| `fleet-advance <drive-id>` | dies: "mission <id> is commander-driven" |
| `fleet-drive spawn` while an agent is in flight (`.stage != driving`, or `.terminal` non-null) | refused — one agent per mission, one worktree per mission; `fleet-drive stop` clears it |
| `--label` in the state vocabulary (`driving`/`ready`/`done`/`parked`/`blocked`/`failed`) | dies — the label becomes `.stage` and would drop the mission out of supervision |
| `--stage` not in the palette | dies |
| both `--stage` and `--prompt-text` | dies |
| `--role`/`--prompt-text`/`--label` given without all three | dies |
| `state --set` outside the five terminal states | dies |
| `fleet-drive` subcommand on a machine mission | dies: "mission <id> is machine-driven" |
| cap breach | park + decision + journal, regardless of Commander intent |
| bunker loadout not built | unchanged: `fleet-spawn` fails closed with an `init` decision |
| no Commander terminal for a wake | unchanged: `.wake-pending`; events keep the cursor |
| malformed config JSON / missing prompt file | dies with the validation error; on a drive mission also appended as an event |
| type cap above the ceiling | `fleet-config` refuses the write; a raw edit is clamped at read time |
| `config/fleet.json` hash changed | decision record + `ceiling-drift` journal line |
| no harness found at bootstrap | dies with the list of harnesses it looked for; `roles.json` is left absent |

## Testing

New bats files, driven by the existing offline fakes (fake `orca` logging argv):

- `drive-events.bats` — append, unread, ack, cursor idempotency across replayed ticks
- `drive-spawn.bats` — palette resolve, ad-hoc brief, `fleet-done` footer still appended, cap
  refusal, in-flight refusal, bunker gate still fires
- `drive-state.bats` — `ready` → ship decision, unattended auto-ship, the five terminal states
- `drive-watch.bats` — marker → event + wake; anomaly → event + wake **and assert no respawn
  appears in the fake-orca argv log** (the load-bearing negative test); anomaly dedupe;
  wall-clock cap parks and stops the terminal; `stage=driving` suppresses detection
- `drive-brief.bats` — `--json` shape
- `drive-decision.bats` — `extend` grants and un-parks; `resume` hands back without spawning
- `config-bootstrap.bats` — detection matrix (both roles, one harness only, none), no-clobber
  without `--force`, session-start runs it when `roles.json` is absent
- `config-type.bats` — type/palette/prompt writes land, cap raise refused, hand-edited cap
  clamped at read time
- `config-validate.bats` — malformed JSON, unknown driver, and missing prompt file each fail
  closed; drive missions also get an event
- `ceiling-drift.bats` — changed `config/fleet.json` hash opens a decision and journals

Regression: the 129 existing tests stay green. `fleet_mission_in_flight` is exercised by the
existing watch / turn-end-guard / session-start / night suites. `make check` (shellcheck + bats)
remains the gate.

## Non-goals

- Unattended drive mode (headless Commander at night).
- Multiple concurrent agents per drive mission.
- Commander editing `config/fleet.json`. Ceilings are the user's.
- A schema language or config migration tooling — `fleet-config validate` is hand-written checks.
- Replacing machine mode. Both modes ship; the existing types keep their guarantees.
- Turn-end-guard blocking on unread events. The guard keeps its current beacon-staleness job.

## Known gaps this leaves open

- Drive-mode kickoff is manual in the same way machine mode is: `fleet-mission` creates state,
  the Commander spawns the first step.
- Ad-hoc `--prompt-text` briefs bypass `prompts/*.txt`, so their quality rests entirely on the
  Commander. The completion-protocol footer is still appended, so supervision is unaffected.
- Per-project drive caps are not configurable; caps live on the mission type, clamped by the
  fleet ceiling.
- Bootstrap harness detection is a fixed name list (`claude`/`codex`/`grok`,
  `pi`/`opencode`). An unknown harness needs one `fleet-config roles set` call.
- Ceiling protection is detection, not prevention — see Ceilings.
