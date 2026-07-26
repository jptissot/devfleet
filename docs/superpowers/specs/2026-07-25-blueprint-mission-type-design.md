# DevFleet — The `blueprint` Mission Type, and Interactive Stages — Design Spec

Date: 2026-07-25
Status: Approved (brainstorm session)
Extends `2026-07-22-devfleet-design.md`; changes nothing in
`2026-07-24-devfleet-commander-drive-design.md`.

This is the first of two specs. This one delivers one new pipeline end to end, plus the one
general primitive that pipeline needs. A second spec will cover pipeline *authoring* —
`fleet-config` expressiveness, generic artifact-skip, declarative per-stage skills — and
`blueprint` will be its first customer. Everything this design forces an implementer to write by
hand is collected under **Requirements discovered for spec 2**; nothing there is designed here.

## Goals

- Add one mission type, `blueprint`: a human-in-the-loop interview that ends in a written,
  reviewed, shipped spec.
- Add `interactive` as a **general** stage property, so the machine has a way to be told that a
  stage is *supposed* to be waiting on a person. Any future human-in-the-loop stage in any
  pipeline uses it.
- Give mission types a `description` and a `when_to_use` line, so a Commander choosing a type
  from a user's request has something to choose on besides a filename.
- Provision the interview skills into the `frontier` role, the way `superpowers` already is.
- Set the convention for a growing pipeline library: one prompt subdirectory per pipeline.

## Non-goals

- **No change to `bin/fleet-advance`.** `blueprint`'s tail is campaign's existing machinery —
  `review: true`, `on_pass`, `on_fail`, `fix_round_limit`, `ready`, ship approval. No new
  transition logic is added.
- **No change to campaign.** `campaign`'s `spec` stage stays exactly as it is.
- **No `fleet-config` grammar work.** The stage flags this design needs cannot be expressed
  through `fleet-config type create --stage`, so `config/missions/blueprint.json` is hand-written
  JSON. That is a known cost, recorded for spec 2, not fixed here.
- **No executor work in `blueprint`.** Every stage is `frontier`. See the rejected `survey`
  alternative below.
- **No new ship behaviour.** The repo's configured ship mode applies unchanged.

## The blueprint pipeline

One new file, `config/missions/blueprint.json`.

```
blueprint ──► review ──┬── PASS ──► ready ──► ship
                 ▲     │
                 └─ refine ─┘   (bounded by fix_round_limit)
```

| Stage | Role | Prompt | Flags | Transition |
|---|---|---|---|---|
| `blueprint` | `frontier` | `blueprint/interview.txt` | `interactive: true` | `next: review` |
| `review` | `frontier` | `blueprint/review.txt` | `review: true` | `on_pass: ready`, `on_fail: refine` |
| `refine` | `frontier` | `blueprint/refine.txt` | — | `next: review` |

`entry` is `blueprint`. `fix_round_limit` is `3`, declared explicitly as `campaign.json` does,
rather than leaning on the `// 3` default in `fleet_pipeline_fix_limit` (`bin/fleet-pipeline:17`).

Neither `ready` nor `ship` is a stage entry. `bin/fleet-advance:131` special-cases the literal
string `ready` before any stage lookup, and the review branch at `bin/fleet-advance:106` sets
`on_pass` as the mission state directly. `campaign.json` declares no `ready` stage either; this
matches it. (Contrast `recon.json`, which *does* declare `report` with `"terminal": true`,
because `report` is a real graph stage that ends the pipeline.)

**`blueprint`** is the interview. One agent session runs the whole chain: interview the user,
build the domain model, write the spec, commit it.

**`review`** reads the finished spec cold and writes `findings.json` at the worktree root with
the existing `{"result":"PASS"|"FAIL","findings":[...]}` contract that `bin/fleet-advance:104`
already parses. Nothing new is required of it.

**`refine`** closes the findings without widening the spec, then returns to `review`. The loop is
bounded by `fix_round_limit`; on exhaustion `fleet-advance` parks and escalates exactly as it
does for a campaign (`bin/fleet-advance:123`).

### `blueprint.json`

```json
{
  "type": "blueprint",
  "description": "interview a human, then write and review a spec",
  "when_to_use": "the work is not written down yet — research, an investigation, or a feature nobody has specified",
  "entry": "blueprint",
  "fix_round_limit": 3,
  "max_mission_seconds": 21600,
  "stages": [
    { "name": "blueprint", "role": "frontier", "prompt": "blueprint/interview.txt", "interactive": true, "next": "review" },
    { "name": "review",    "role": "frontier", "prompt": "blueprint/review.txt",    "review": true, "on_pass": "ready", "on_fail": "refine" },
    { "name": "refine",    "role": "frontier", "prompt": "blueprint/refine.txt",    "next": "review" }
  ]
}
```

### Decision: a new type, not a replacement for campaign's `spec` stage

**Alternative rejected:** rewrite `campaign`'s `spec` stage into a full interview.

That changes the behaviour of every campaign ever run, including the ones started with `--spec`
where the stage is skipped anyway, and it makes a mission that is supposed to build a feature
open with a long interview. A separate type is additive: nothing that works today behaves
differently tomorrow.

It also **composes**, which the replacement does not. `blueprint` produces a spec on the default
branch; `fleet-mission --type campaign --project <p> --repo <r> --desc <d> --spec <path>` then
consumes it, and the artifact-skip rule at `bin/fleet-mission:35` sends that campaign straight to
`plan`. Two pipelines, one hand-off, no new code.

### Decision: one interview stage, not three

**Alternative rejected:** split the interview into `grill` → `model` → `spec`, one stage each,
the way `campaign` splits `spec` → `plan` → `execute`.

DevFleet spawns a **fresh agent per stage**. `bin/fleet-advance`'s `spawn()` stops the previous
terminal before creating the next one, and the new agent's entire inheritance is the brief plus
whatever is on disk in the worktree. There is no conversation carried across.

The value of an interview is precisely the part that does not survive that: the follow-up that
only made sense because of the previous answer, the option raised and rejected, the reasoning
behind a constraint. A three-stage split would hand stage two a summary of stage one and make the
user re-answer questions they had already answered, worse each time. The interview is one session
because the accumulated conversation *is* the artifact until the moment the spec is written.

This is the load-bearing argument for the pipeline's shape. If a future change makes the
interview feel too long for one stage, the thing to revisit is the stage's budget, not its
boundaries.

### Decision: `refine` runs on `frontier`, not `executor`

This is the one place `blueprint` departs from the pattern a reader already knows. In `campaign`,
`strike` and `fortify`, the post-review `fix` stage is `"role": "executor"`. In `blueprint`,
`refine` is `"role": "frontier"`.

**Alternative rejected:** `refine` on `executor`, for symmetry with `fix`.

Two reasons it loses. First, revising a spec is judgment work — deciding whether a review finding
means "add a paragraph", "the design was wrong here", or "this finding misread the intent" is the
same kind of reasoning that produced the spec. Second, the executor role is concretely `omp`
(`config/roles.json`), driven by `prompts/fix.txt`, which is written for code: it asks for
regression tests and a commit "before the ship step merges the branch". Handing a document-editing
task to a code-shaped role and brief is a mismatch in both directions.

`blueprint` therefore uses no executor stage at all, and never enters a bunker: `fleet_bunker_enabled`
is consulted per role in `bin/fleet-spawn:103`, and `frontier` bunkering is whatever the repo and
`roles.json` already say — this design does not change it.

### Decision: the pipeline ships

**Alternative rejected:** end at a terminal stage, like `recon`'s `report`, and never ship.

Shipping a spec reads oddly at first. But the spec is a file on a branch, and shipping is what
puts that file on the repo's default branch — a stable path that `fleet-mission --type campaign
--spec <path>` can point at. A spec that stays on a mission branch is a spec the next mission
cannot reliably find.

The repo's configured ship mode applies unchanged (`README.md`, "Ship modes"). On a `report-only`
repo, shipping records the branch and nothing else, which is the correct no-op. On `local-merge`
or `direct-PR` it does the obvious thing. And because the path runs through
`bin/fleet-advance:112`, `blueprint` gets the same ship-approval decision record the user already
knows from campaigns, rather than a second, differently-shaped approval.

### Decision: frontier-only, no `survey` pre-stage

**Alternative rejected (for now):** an executor `survey` stage ahead of `blueprint` that reads the
target repo and writes a `CONTEXT.md` for the interviewer to start from.

The user's call is "keep it frontier only for now". The counter-argument on record is worth
keeping: an agent that did the reading itself knows the codebase better than one handed someone
else's summary, and the summary is exactly the kind of lossy hand-off the one-stage-interview
argument above is about. This is not foreclosed — `survey` would be one more stage entry and one
more prompt, no code change — but it is not in this spec.

## The interactive stage property

`interactive` is a stage-level boolean, read through `fleet_pipeline_field`
(`bin/fleet-pipeline:21`) exactly as `review` already is at `bin/fleet-advance:97`. The reader
already normalises JSON booleans to the strings `"true"`/`""`, so no new plumbing is needed.

**It must not be called `terminal`.** That name is taken: `terminal: true` means "last stage in
the graph, spawns no agent" — see `config/missions/recon.json`'s `report` stage, the skip at
`bin/fleet-config:48`, and the branch at `bin/fleet-advance:127`.

This is a **general primitive**. It says one thing: *a human is expected to be sitting at this
stage's terminal, and silence here is the design, not a failure.* `blueprint` is its first user,
not its owner.

### Behaviour in `fleet_detect_anomaly`

`fleet_detect_anomaly` (`bin/fleet-detect:9`) is the single detector both drivers share — called
from `bin/fleet-watch:144` and `bin/fleet-drive:118`. When the mission's current stage has
`interactive: true`:

| Anomaly | On an interactive stage | Why |
|---|---|---|
| `terminal-gone` | **fires** | The pane is gone. Nobody is talking to anybody. |
| `exit:<n>` | **fires** | The harness exited. Same. |
| `blocked:trust` / `permission` / `approval` | **fires** | A gate the human at the keyboard may not even be able to see, and the agent is not running. |
| `idle` | **stands down** | The agent asked a question and is waiting. That is the stage working. |
| `stalled` | **stands down** | Nothing changes in the worktree while a person thinks. |
| `loop` | **stands down** | Screens recur because a conversation revisits topics. |
| `cycle` | **stands down** | The worktree returns to the same hash because a person is talking, not editing. |
| `over-budget` | **fires**, on a larger cap | An interview is long, not infinite. |

Progress **bookkeeping** is unchanged: `state_hash`, `last_progress_at`, and the `hashes` and
`screens` history files are still written on an interactive stage. Only the four *reports* stand
down. Suppressing the bookkeeping would leave a stage with no history at all the moment it
stopped being interactive, and the histories are cheap.

**Correction (found during the final whole-branch review, 2026-07-26): the last two sentences
above are wrong.** The `hashes` and `screens` history files are *not* written on an interactive
stage. `bin/fleet-detect:66` and `:72` short-circuit past `fleet_watch_cycle` and
`fleet_watch_screen_loop` with `[ "$interactive" != true ] &&` before either is ever called, and
both functions do the history-file append as their first statement (`bin/fleet-watch-lib:35` and
`:56`) — so on an interactive stage that append never runs. Only `state_hash` and
`last_progress_at` are still recorded; the cycle and loop histories accrue nothing for as long as
the stage is interactive. The worry above — that suppressing bookkeeping would leave a stage with
no history the moment it stopped being interactive — was real but turns out to be minor, and
skipping it is in fact the *safer* choice: both histories are scoped per-mission, not per-stage
(`bin/fleet-detect:63`, resolved under `fleet_mission_dir "$id"`), so a long interview's recurring
screens would otherwise accumulate in the very ring buffer the *next* stage's loop detector reads,
and could hand that later, non-interactive stage a false `loop` verdict. The histories are ring
buffers, so the next stage rebuilds one within a few ticks regardless. `README.md` was corrected
to say this plainly; this entry is left in place, corrected, rather than deleted.

The three that still fire are the ones a human presence cannot explain. A person at a keyboard
does not make a dead terminal alive.

### The interactive budget

A new environment variable, `FLEET_INTERACTIVE_BUDGET_SECONDS`, default **14400** (4h). When the
current stage is interactive, this replaces the `budget_seconds` argument
`fleet_detect_anomaly` was passed — normally `FLEET_BUDGET_SECONDS` (default 2700) from
`bin/fleet-watch:33`.

**It is clamped by `max_mission_seconds_ceiling` the same way every other cap is.** The clamp is
applied where the value is *read*, matching `fleet_pipeline_cap` (`bin/fleet-pipeline:68`) and the
rationale in its comment: a cap that a config edit can raise is not a cap. The effective value is
`min(FLEET_INTERACTIVE_BUDGET_SECONDS, fleet_pipeline_ceiling max_mission_seconds)`, so setting the
variable to a week in the environment cannot route around `config/fleet.json`. With the shipped
ceiling of 28800 the default 14400 is unclamped; the clamp exists for the case where a user has
lowered the ceiling.

`bin/fleet-detect` currently sources nothing — it is sourced by `fleet-watch` and `fleet-drive`,
which both also source `fleet-pipeline`, so `fleet_pipeline_field` and `fleet_pipeline_ceiling`
are in scope at both call sites. The test helper is the exception; see **Testing**.

### Rationale: silence has never had a meaning

Today the machine has no concept of a stage that is supposed to be waiting. Every stage is assumed
to be autonomous work, so silence can only read as failure — that assumption is baked into the
names: `stalled`, `idle`, `over-budget`.

Human presence is currently *inferred*, at the last possible moment, from a glyph on a screen.
`interactive` lets it be **declared**, at the place where the pipeline is written, by the person
who knows.

### Relationship to the `❯` draft guard

The existing draft guard — `fleet_watch_human_draft` (`bin/fleet-watch-lib:76`), called at
`bin/fleet-detect:93` — **stays**. Both mechanisms exist because they cover different halves of
the problem, and each has a hole the other fills.

The draft guard only fires once **characters are already on the input line**. It reads the last
`❯` prompt line and returns true if anything non-whitespace follows the marker. That protects an
operator mid-reply — the case that cost m002 a nudge typed into a half-written sentence — but it
does nothing at all during the part that takes longest: a human *reading* a question, deciding,
before touching the keyboard. The line is empty; the guard is silent.

And that window has no grace period. When the agent's own hook feed reports `done`,
`bin/fleet-detect:94` returns `idle` immediately, with no waiting period whatsoever — the
`FLEET_NUDGE_SECONDS` delay on the line below applies only to the screen-heuristic fallback for
agents that do not report hook state. An agent that asks a question and ends its turn is `idle` on
the very next tick.

So:

- **`interactive`** is the first line of defence, and the declared one. It covers the whole stage,
  including the empty-input-line reading window, and it is stated in the pipeline rather than
  guessed from a screen.
- **The draft guard** is the second line, and the undeclared one. It still protects
  *non-interactive* stages where an agent asks a question in its pane anyway — which the completion
  protocol forbids but cannot prevent — and it still protects an interactive stage against
  `over-budget`'s exemption being wrong at exactly the wrong moment.

The budget exemption at `bin/fleet-detect:101` is unchanged in kind: a draft still does not hold
the budget open. The cap it is measured against is simply larger on an interactive stage.

## Type descriptions

Mission types gain two required fields:

- `description` — one line, what the pipeline is.
- `when_to_use` — one line, when to reach for it.

`fleet_config_validate_type` (`bin/fleet-config:17`) requires both, alongside the existing
`.type`, `.entry` and per-stage `role`/`prompt` checks. `fleet-config type show` surfaces them.

All five existing types are **backfilled in the same change**, so `fleet-config validate` stays
green and `tests/fleet-config-validate.bats` does not start failing on the shipped configs.
Indicative wording — the exact sentences are the implementer's:

| Type | `description` | `when_to_use` |
|---|---|---|
| `campaign` | build a feature, spec through ship | a change that needs specifying, planning and implementing |
| `strike` | fix a known bug from an issue reference | the defect is already reported and understood |
| `recon` | investigate and report; ships nothing | you need an answer, not a change |
| `fortify` | refactor, tests, or performance on existing code | the behaviour is right and the code is not |
| `sortie` | commander-driven; stages in any order | the work does not fit a fixed graph |
| `blueprint` | interview a human, then write and review a spec | the work is not written down yet |

**Rationale.** With three types you remember what they are. With ten you do not — and neither does
the Commander, which picks a type from the user's request. Today the only thing it has to pick on
is the filename plus whatever `README.md` happens to say, and `README.md` is not in a machine's
context by default. A one-line `when_to_use` beside the graph is the cheapest fix, and it lives in
the file that already had to be read.

### `fleet-config type create` must learn both flags

In scope for this spec, and the only piece of `fleet-config` grammar it does not defer to spec 2.

`fleet-config type {create|set}` gains `--description` and `--when-to-use`, written into the type
file alongside the existing `--name` / `--entry` / `--stage` handling at `bin/fleet-config:203-220`.

This is not tidiness. Validation is about to require two fields, and `create` is the command that
writes a new type file — so without the flags every type created through the supported path would
fail its own validation the moment it was written. That turns `fleet-config`, which exists to be
the single validated door for config writes, into a door that produces invalid config. Requiring a
field and being unable to write it is not a gap to schedule; it is a contradiction to avoid
shipping.

Note the limitation this does **not** fix: `--stage` still takes only `name:role:prompt:next`, so
`blueprint.json` is still hand-written for its `interactive`, `review`, `on_pass` and `on_fail`
keys. That is spec 2's problem, recorded below.

## Skills provisioning

The `blueprint` interview uses skills from [`mattpocock/skills`](https://github.com/mattpocock/skills)
(MIT). They are installed into the **`frontier` role only**, mirroring how `superpowers` already
is, by adding two commands to the frontier `provision` list in `config/roles.json`:

```
claude plugin marketplace add mattpocock/skills
claude plugin install mattpocock-skills@mattpocock
```

Marketplace name `mattpocock`, plugin name `mattpocock-skills` — both taken from that repo's
`.claude-plugin/marketplace.json` and verified during the brainstorm session.

The `provision` list runs inside the bunker at `fleet-loadout provision` (`bin/fleet-loadout:42`),
which iterates the role's commands NUL-delimited and fails the whole provision if one exits
non-zero. Plugins land in the persisted `/home/agent` that airlock keeps per repo, so they survive
a container recreate — the same property that keeps `superpowers` and the `orca-spool.sh` hook
alive today.

The **`executor` role is not touched.** `blueprint` is frontier-only, and the executor's
`provision` stays the single `omp plugin install` line it is now.

### Skills used

Verified slugs, as they appear in the repo:

| Slug | What it is for here |
|---|---|
| `skills/engineering/grill-with-docs` | the interview that also builds the project's domain model — the main driver of the `blueprint` stage |
| `skills/engineering/to-spec` | turn the accumulated conversation into a spec |
| `skills/engineering/domain-modeling` | build and sharpen a domain model |
| `skills/engineering/research` | investigate against primary sources |
| `skills/productivity/grill-me` | thorough decision-tree interview |
| `skills/productivity/grilling` | the reusable interview loop |

### Risk: provisioning is role-wide

There is no per-stage install. Adding these to `frontier.provision` puts **all** of mattpocock's
skills in front of **every frontier stage of every mission type** — `spec`, `plan`, `review`,
`audit`, `recon`, and every palette entry a `sortie` can spawn.

Four of them overlap capabilities DevFleet already owns and drives through its own prompts:
`implement`, `tdd`, `code-review`, `to-tickets`. Several are model-invoked, meaning the agent
reaches for them on its own judgment rather than being told to.

The concrete failure modes:

- A **`review` stage agent runs `code-review`** and emits that skill's output format instead of
  writing `findings.json`. `bin/fleet-advance:104` reads `.result` from `findings.json` and falls
  back to `FAIL` when the file is missing or unparseable — so the mission does not crash, it
  silently takes a fix round it did not earn, and after `fix_round_limit` of those it parks.
- A **`plan` stage agent runs `to-tickets`** against an issue tracker nobody asked it to touch.
  That one reaches outside the worktree.
- Any frontier stage runs `implement` or `tdd` with a shape that does not match `prompts/plan.txt`
  or `prompts/audit.txt`, producing work the next stage's brief does not expect.

**Mitigation:** DevFleet's briefs are directive and name the artifact they want. `prompts/review.txt`
says "Write findings.json at the worktree root with `{...}`", says it twice, and says when. A
model-invoked skill competes against an explicit instruction, and the explicit instruction is in
the brief the agent was launched with.

That is a real mitigation, not a guarantee. **This is the most likely first surprise on a
NON-blueprint mission after this lands** — the first campaign `review` after provisioning is the
one to read carefully. The fix if it bites is a declarative per-stage skills list, which is spec 2
material.

## Prompts

Prompt subdirectories already work with no code change. Resolution in `bin/fleet-spawn:79-81` is a
plain path join with a fallback:

```bash
tmpl="$FLEET_HOME/prompts/$PROMPT_FILE"
[ -f "$tmpl" ] || tmpl="$FLEET_ROOT/prompts/$PROMPT_FILE"
```

`fleet_config_prompt_path` (`bin/fleet-config:8`), which validation uses, joins the same two roots
the same way. A `prompt` value of `blueprint/interview.txt` resolves and validates today.

So this design **adopts a per-pipeline directory now**, and sets it as the convention for the
library to come. The six existing flat prompt files stay where they are; nothing is moved.

| File | Contents |
|---|---|
| `prompts/blueprint/interview.txt` | Run `grill-with-docs`, reaching for `domain-modeling` and `research` as the interview needs them, then `to-spec`. Write the spec to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` and commit it on the mission branch. States plainly that **the user is at this terminal**, and to ask **one question at a time**. |
| `prompts/blueprint/review.txt` | Read the spec **cold** — as a stranger who will implement from it — against the criteria that matter for a document: unresolved placeholders, internal contradictions, ambiguity a reader would have to guess at, and scope that has drifted from what the interview asked for. Emit the same `findings.json` PASS/FAIL contract. |
| `prompts/blueprint/refine.txt` | Close every blocking and major finding, and each minor that can be closed **without widening the spec**. Re-commit. |

`prompts/blueprint/review.txt` is deliberately **not** the existing `prompts/review.txt`. That one
is written for code: it says to read `git diff` vs base, run the build, the linter and the tests,
and exercise described behaviour. A spec has no build. Reusing it would produce a reviewer
apologising for the tests it could not run instead of one reading the document.

### The contradiction the interview prompt has to resolve

`bin/fleet-spawn:120-122` appends a footer to **every** brief:

> If you need a human decision, do not ask in this terminal — no one reads it. Record
> `blocked:<question>` and stop.

On an interactive stage someone **does** read it. That footer is unconditional and this design does
not change it, so `prompts/blueprint/interview.txt` must address it head-on: say that this stage
is an exception, that the user is present at this terminal, and that questions belong in the
conversation. It should also say what `blocked:` still means here — a decision the *user in the
room* cannot make, such as an approval that belongs to someone else.

Leaving the two to contradict each other silently would produce the worst outcome available: an
interviewer that writes `blocked:` for its first question and stops, turning a conversation into a
decision record and a wake.

### One-line fix in `fleet-config prompt write`

`bin/fleet-config:289` does `mkdir -p "$FLEET_HOME/prompts"` and nothing more, then writes to
`"$FLEET_HOME/prompts/$PNAME"`. A `--name blueprint/interview.txt` therefore fails on a missing
directory. The fix is to create the *file's* directory rather than the prompts root. `promote`
(`bin/fleet-config:301`) writes through the same path and gets the fix for free.

Reading a subdirectory prompt already works; only writing one does not.

## Testing

All tests run offline against the existing fake `orca` in `tests/helpers/common.bash`. No new test
infrastructure. `fleet_seed_config` copies `config/missions/*.json` into the temp home, so
`blueprint.json` is available to every suite as soon as it exists.

**`tests/fleet-detect.bats`** — the `detect()` helper at line 14 sources `fleet-common`,
`fleet-backend`, `fleet-watch-lib` and `fleet-detect`. If the interactive lookup uses
`fleet_pipeline_field` / `fleet_pipeline_ceiling`, that helper must also source `fleet-pipeline`;
the production call sites (`fleet-watch`, `fleet-drive`) already do.

- an interactive stage stands down `idle` — including the `agent_state = "done"` path that reports
  immediately today
- an interactive stage stands down `stalled`
- an interactive stage stands down `loop`
- an interactive stage stands down `cycle`
- an interactive stage still reports `terminal-gone`
- an interactive stage still reports `exit:<n>`
- an interactive stage still reports `blocked:trust`
- `over-budget` fires on the interactive cap, not the normal one: a stage past
  `FLEET_BUDGET_SECONDS` but inside `FLEET_INTERACTIVE_BUDGET_SECONDS` reports nothing; past the
  interactive cap it reports `over-budget`
- a **non**-interactive stage is unaffected by any of the above (the existing tests carry this,
  and should be checked rather than assumed)

**Caps** — `FLEET_INTERACTIVE_BUDGET_SECONDS` is clamped by `max_mission_seconds_ceiling`: with a
lowered ceiling in `config/fleet.json`, an interactive stage goes over budget at the ceiling, not
at the requested value. `tests/fleet-ceiling-drift.bats` and `tests/fleet-pipeline.bats` are the
neighbours.

**Pipeline** — `tests/fleet-pipeline.bats`:

- `blueprint.json` is valid JSON and validates through `fleet_config_validate_type`
- `fleet_pipeline_entry blueprint` is `blueprint`
- `blueprint.next` is `review`; `review.on_pass` is `ready`; `review.on_fail` is `refine`;
  `refine.next` is `review` — every one of them either a declared stage or the literal `ready`
- `fleet_pipeline_field blueprint refine role` is `frontier` (this is the divergence; it deserves
  its own test so a future tidy-up cannot quietly "fix" it to `executor`)
- `fleet_pipeline_field blueprint blueprint interactive` is `true`

**Config** — `tests/fleet-config-validate.bats` and `tests/fleet-config-type.bats`:

- validation accepts a stage carrying `interactive`
- validation requires `description` and `when_to_use` on a type, and all six shipped types pass

On whether the validator currently rejects unknown stage keys: **it does not.** `fleet_config_validate_type`
(`bin/fleet-config:17`) reads exactly four fields per stage — `.name`, `.role`, `.prompt`,
`.terminal` — via the `jq` projection at `bin/fleet-config:60`, and checks nothing else. There is
no schema, no key allow-list, and no rejection path for an unrecognised key. `interactive` will
therefore pass validation with no validator change at all; the test above pins that as intended
behaviour rather than an accident. (The corollary is that a typo — `interactve: true` — is also
accepted silently, and the stage simply is not interactive. That is a spec 2 concern.)

**Regression** — the draft-guard tests in `tests/fleet-watch-lib.bats` and `tests/fleet-watch.bats`
keep passing unchanged. The guard is not modified by this design, and a change that made it
unnecessary would be a change this spec did not ask for.

`make check` — `shellcheck bin/*` plus the full suite — must be green.

## Requirements discovered for spec 2

Every place this design forces an implementer to hand-edit JSON, or to touch a script that was
supposed to be type-agnostic.

1. **`fleet-config type create --stage` takes four fields.** The parser at `bin/fleet-config:212`
   is `IFS=: read -r sn sr sp sx` — name, role, prompt, next. It cannot express `review: true`,
   `on_pass`, `on_fail`, `terminal: true`, or the new `interactive`. So **every pipeline with a
   review loop must be hand-written JSON**, bypassing `fleet-config` — which `AGENTS.md` names as
   the single validated door for config writes, and which is the only thing that journals them.
   `blueprint.json` is written by hand for this reason. This is the headline requirement.

2. **The artifact-skip rule is welded to one type.** `bin/fleet-mission:35` reads
   `if [ "$TYPE" = campaign ] && [ -n "$SPEC" ]; then STAGE="plan"; fi`. "Start further along when
   the artifact already exists" is a generic idea and belongs in the type file — something a stage
   can declare, e.g. "skip me when this artifact is present". `blueprint` does not need it today,
   but the composition story (`blueprint` → `campaign --spec`) depends entirely on the one
   hardcoded instance of it.

3. **Skills are bound to stages as prose.** A prompt file says "run `grill-with-docs`", and the
   plugin is installed role-wide through `provision` in `roles.json`. There is no declarative
   per-stage skills list, so there is no way to say "this skill, this stage, and nowhere else".
   The overlap risk above is the direct consequence.

4. **The night admission gate is a hardcoded `case` on type.** `bin/fleet-night:22-33` enumerates
   `campaign|strike|recon|fortify` and rejects anything else with `unknown type <t> — not
   admitted`. `blueprint` is therefore refused from the night queue automatically, which is the
   *right* answer — an interactive stage cannot run unattended — but it is right by accident. The
   generic rule is "a type with an interactive stage is never admitted", and it should be derived
   from the graph, next to the existing derived rule that commander-driven types are refused
   (`bin/fleet-night:18`). Note the gate's own message already calls campaign's `spec` "(interactive
   stage)" in prose — the concept exists in a string literal today.

5. **`fleet-config prompt write` cannot write into a subdirectory.** `bin/fleet-config:289`
   `mkdir -p`s only the prompts root. Fixed here as a one-liner because this design needs it; noted
   because it is symptomatic — the prompt tooling assumed a flat directory, and the library
   convention this spec sets is not flat.

6. **`roles.json` is git-ignored.** The provisioning change lands in a file that is not versioned,
   and `config/roles.json.example` — the tracked documentation — carries no `provision` list at
   all. So "the frontier role provisions these skills" has no committed record anywhere except
   prose. Whether the example should carry the real provision lists is a question for the authoring
   spec.

7. **`fleet-spawn`'s completion-contract footer is unconditional.** `bin/fleet-spawn:104-123`
   appends "no one reads this terminal" to every brief including an interactive stage's. This
   design resolves the contradiction in the *prompt*, which is the smallest fix but the wrong
   layer — the stage already declares `interactive`, and the footer could read it.

## Open questions

Details this design does not settle. Each has a smallest-choice default recorded; none blocks
implementation.

- **Where the interactive budget substitution happens.** Default: inside `fleet_detect_anomaly`,
  which already has the mission JSON and therefore the type and stage, so neither call site changes.
  The alternative — resolve it in `fleet-watch` and `fleet-drive` and pass it in — keeps
  `fleet-detect` free of a `fleet-pipeline` dependency but duplicates the logic at two call sites.

- **Whether `description` / `when_to_use` are required of *all* types or only new ones.** Default:
  required of all, with the five existing types backfilled in the same change so validation never
  goes red. "Required for new types only" would need a grandfather list, which is worse than a
  backfill.

- ~~**Whether `fleet-config type create` learns `--description` / `--when-to-use` now.**~~
  **Resolved: yes, in scope.** A field that validation requires but `create` cannot write would
  make every new type fail its own validation at birth, which turns the single validated door into
  a door nobody can use. This is the one piece of `fleet-config` grammar that cannot wait for
  spec 2, and it is now part of the "Type descriptions" section rather than an open question.

- **`FLEET_BUDGET_SECONDS` is not clamped by anything today.** It is read straight from the
  environment at `bin/fleet-watch:33` and passed through. This design clamps the *interactive* cap
  as instructed; the asymmetry between the two is noted, not resolved. Aligning them is a separate
  decision with its own blast radius.

- ~~**The interview stage's `max_mission_seconds`.**~~ **Resolved.** Leaving it at the 14400
  default made the whole-mission cap equal to the interactive *stage* cap, so an interview that ran
  to its own limit would leave `review` and `refine` exactly zero time — the mission would be
  killed by its budget for succeeding slowly. `blueprint.json` now declares
  `"max_mission_seconds": 21600`, giving two hours of headroom past a maximal interview, still
  inside the 28800 ceiling. Any pipeline with an interactive stage needs a mission cap strictly
  greater than the interactive stage cap; that is a general rule and belongs with the
  `interactive` property, not with blueprint.

  **Correction (found during Task 8 documentation review, 2026-07-26): the reasoning above is
  wrong.** There is no whole-mission clock for `blueprint` to be starved out of. `max_mission_seconds`
  is read and enforced only in drive mode (`bin/fleet-drive`, the `mission_started_at`/`max_sec`
  check around lines 103-108, and the `max_seconds` field in `fleet_drive_brief_json` around lines
  54-55) — reachable only when a type's `driver` is `commander`. `fleet_watch_check`
  (`bin/fleet-watch:123-127`) routes every other mission through the machine-driven path instead,
  which measures each stage from `stage_started_at` — reset on every stage transition
  (`bin/fleet-advance:57`, `bin/fleet-spawn:201`) — and never reads `max_mission_seconds` at all.
  `blueprint.json` declares no `driver`, so it is machine-driven: `review` and `refine` each start
  with a full, fresh stage budget no matter how long the interview ran, and no shared clock is
  ever consumed. The actual protection against an abandoned interview is the per-stage `eff_budget`
  substitution in `fleet_detect_anomaly` (`FLEET_INTERACTIVE_BUDGET_SECONDS`, clamped by
  `max_mission_seconds_ceiling`), which applies regardless of driver. `blueprint`'s
  `"max_mission_seconds": 21600` is config headroom against `blueprint` someday becoming
  commander-driven, not an active runtime protection today. The "mission cap strictly greater than
  the interactive stage cap" advice above is also narrower than stated: it is not a general rule
  for every pipeline, because a machine-driven pipeline's `max_mission_seconds` is not enforced at
  all; it would only bind for a commander-driven pipeline, through drive mode's unconditional
  wall-clock check, which has no notion of `interactive` and would park the mission on the mission
  clock regardless of stage. `README.md` was corrected to say this plainly; this entry is left
  in place, corrected, rather than deleted.

- **Exact prompt text.** The three prompt files are specified by content and intent, not verbatim.
  In particular, the wording that overrides the spawn footer without inviting an agent on a
  *non*-interactive stage to think the same rule applies to it is worth care.

- **`prompts/blueprint/review.txt` and the `severity` vocabulary.** The existing contract uses
  `blocking|major|minor` and `prompts/fix.txt` keys "widening the change" off it. Default: reuse it
  unchanged for specs, so `fleet-advance` and any future reader see one vocabulary.

- **Where the spec lands in a target repo.** The interview prompt names
  `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, which is this repo's convention. A target
  repo may not have that directory or want that layout. Default: create it; revisit if it annoys.
