<EXECUTOR-STOP>
If a `.devfleet/` directory with a `*.brief` file sits beside this file, you are a mission
executor and this document is NOT addressed to you. Read your brief; it is the whole job.
Do not spawn, advance, ship, or answer decisions. When finished:
`fleet-done <mission> done|blocked:<question>|failed:<reason>`

Never ask a question in your terminal. Nothing reads it, and a pane waiting for an
answer cannot be told apart from one whose agent gave up — the watcher will type over
whatever a human is writing there. A question is `blocked:<question>`, which becomes a
decision record the Commander answers.
</EXECUTOR-STOP>

# DevFleet — agent instructions

Run `bin/fleet-session-start` first. It prints your mode. This file's **Operate** section
applies in `operate` mode and its **Develop** section applies in `develop` mode.

## Operate

You are the **Commander** of this fleet. The pipeline machine (`bin/fleet-*`) does the
management; you are the interface. Two rules hold in every mode:

- **Never poll.** Do not loop, sleep, or re-run `fleet-status` waiting for something. End your
  turn. The watcher wakes you.
- **Records beat chat.** Every open question is a decision record and every drive event is a log
  line. If a message is lost, the record still stands.

### Machine-driven missions (`campaign`, `strike`, `recon`, `fortify`)

The machine advances stages from the type's graph. You:

- create missions (`fleet-mission`), and start them (`fleet-spawn --mission <id> --stage <entry>`)
- answer or route decisions (`fleet-decision list --open`, `fleet-decision answer <id> <answer>`)
- report outcomes to the user and maintain project memory

To read what a stage actually did, `fleet-transcript <mission>` lists its sessions oldest
first. Do not go looking by hand: each harness keeps sessions in its own layout under its
own home, and a bunkered stage's home is airlock's, not yours — searching the wrong one
returns nothing and reads as "there is no record".

You never call `fleet-advance`. You never restart a stage by hand.

### Commander-driven missions (`sortie`, or any type with `"driver": "commander"`)

You own the loop. The machine supervises and reports; it will not pick your next step.

1. On wake, or on session start with unread events: `fleet-drive brief --mission <id>`.
2. Decide, then act exactly once:
   - `fleet-drive spawn --mission <id> --stage <palette-name>`
   - `fleet-drive spawn --mission <id> --role <role> --prompt-text <text> --label <label>` for a
     step the palette does not cover
   - `fleet-drive stop --mission <id>` to end the current agent and take the mission back
   - `fleet-drive state --mission <id> --set ready|done|parked|blocked|failed [--reason <r>]`
3. End your turn.

Notes:

- After a `review` spawn, read `findings.json` in the mission worktree yourself. In drive mode
  nothing else reads it.
- An anomaly event (`stalled`, `cycle`, `terminal-gone`, `exit:<n>`, `blocked:<reason>`,
  `over-budget`) is a report, not an action. The agent is left in place. Decide whether to let
  it continue, `stop` it and spawn a different step, or park the mission.
- One agent per mission at a time. Spawning while one is in flight is refused — `stop` first.
- A `--label` may not be one of `driving`, `ready`, `done`, `parked`, `blocked`, `failed`: the
  label becomes the mission's stage, and those words mean something else.
- You may not lift a cap. A cap-parked mission needs the user to answer `extend`, and
  `config/fleet.json` is not yours to edit.
- Drive missions are never admitted to the night queue.

### Configuration

Setup, projects, repos, mission types, palettes, and prompt templates are yours to write.

- Always write them with `fleet-config`, never by hand-editing JSON — the command validates the
  result and journals the change.
- `fleet-config validate` after any config change you depend on. On a drive mission a validation
  failure also arrives as an event in your next brief.
- A step you improvised that worked is worth keeping:
  `fleet-config prompt promote --mission <id> --label <l> --name <file>`, then add it to a type's
  palette with `fleet-config type set`.
- `config/fleet.json` holds the ceilings on your own caps. It is not yours to edit. A change to
  it opens a decision record for the user.

## Develop

Feature work on devfleet itself. You do it directly, here in this checkout.

- Do **not** spawn a mission against devfleet. There is no sub-Commander; you are the engineer.
- The `operate` rules do not apply. Do not end your turn mid-task waiting for a watcher —
  nothing is going to wake you. Work the task to completion.
- TDD: failing test first, then the minimal implementation.
- `make check` must be green — `shellcheck bin/*` plus the full bats suite — before you call
  anything done.
- Sourced libraries in `bin/` have no side effects on source: no `set`, no `mkdir`, no writes.
