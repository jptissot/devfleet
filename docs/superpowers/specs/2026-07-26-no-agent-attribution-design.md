# No Agent Attribution in Commits — Design Spec

Date: 2026-07-26
Status: Approved (brainstorm session)
Scope: `devfleet`, `airlock`, `tea-axi` — three repos, one rule, three enablement points.

## The problem

Commits in these repos carry attribution nobody asked for. Coding agents append a
`Co-authored-by:` trailer naming Claude, and a `🤖 Generated with [Claude Code]` line, because
their harness-level instructions tell them to. None of that is in any repo's own instructions —
`grep -ri co-authored-by` across all three returns nothing — so today the rule is set entirely
outside the repos, by whatever agent happens to be running.

The user's rule is the opposite: these repos never record an agent as a co-developer. The tool
that wrote a commit is not a developer on the project, and the trailer is a claim about
authorship, not a changelog.

A rule that lives only in an agent's instructions is not enforced. Three mechanisms are needed
and only two of them are documents.

## The rule

**No commit in these repos carries an agent co-author trailer or a generated-by line.** A human
co-author is untouched — `Co-authored-by:` naming a person is a real statement about who wrote
the change and stays.

## Three pieces per repo

### 1. `.githooks/commit-msg`

Committed, mode `0755`, identical in all three repos. It rewrites the message file in place:

- delete any `Co-authored-by:` line (case-insensitive) whose name or address names an agent —
  `Claude`, `Anthropic`, `noreply@anthropic.com`
- delete any line containing `Generated with [Claude Code]`, and the `🤖` variant
- collapse the trailing blank lines the deletions leave behind

Everything else is passed through byte for byte. The hook never fails a commit: a message with
nothing to strip exits 0 having changed nothing, and a message that is *only* a trailer is not
this hook's problem — `git commit` already rejects an empty message on its own.

Written for `sh`, not bash: it runs wherever the repo is cloned, including inside an airlock
container whose image is not guaranteed to carry bash at `/bin/bash`.

Deletion rather than rejection is the deliberate choice. A hook that rejects the commit turns a
cosmetic problem into a stalled agent that must re-run `git commit` — and an agent whose
instructions tell it to add the trailer will add it again on the retry, so rejection loops. The
trailer is noise; the fix is to remove the noise and let the commit land.

### 2. The documented rule

Each repo states it in the file its agents actually read.

- **devfleet** — `AGENTS.md`. It belongs under **Develop**, next to the TDD and `make check`
  rules, since that is the section addressed to the agent writing commits here. `CLAUDE.md`
  routes to `AGENTS.md` already and needs no change.
- **airlock** — `AGENTS.md`, which already opens with "guidance to coding agents working with
  code in this repository".
- **tea-axi** — has neither `AGENTS.md` nor `CLAUDE.md`. It gets a short `AGENTS.md` carrying
  this rule and a pointer to `README.md` and `SKILL.md` for everything else. Deliberately small:
  this spec is not the place to write tea-axi's agent guide, and a file that exists is what makes
  the rule findable.

Each states the hook exists and that it is a backstop, not the rule — an agent that reads the
line should not need it.

### 3. Enabling `core.hooksPath`

A committed hook does nothing until the clone points at it. `git config core.hooksPath .githooks`
is per-clone, not per-file, so each repo uses the entry point it already has rather than adding a
new setup step:

| Repo | Where | Why |
|---|---|---|
| devfleet | `bin/fleet-session-start` | already runs at the top of every session in this checkout |
| tea-axi | npm `prepare` script | already runs on `npm install`; the repo has no other bootstrap |
| airlock | documented in `AGENTS.md` + `README.md` | no Makefile, no install step, no session hook — nothing to hang it on |

Each is idempotent: read the current value, set it only when it differs, never fail the caller.
In `fleet-session-start` that means a `|| true` — a hook-path write failing must not stop a
session from starting, and it is placed after `fleet_roots`, in the fleet root only. The
`execute` and `orphan` branches return before it, which is correct: a mission worktree shares its
parent's config, so the setting is already in force there.

Worktrees inherit the setting for the same reason — `core.hooksPath` lives in the shared common
config, not per-worktree, so every fleet mission worktree of a repo is covered by the one write
in its parent clone.

A relative `core.hooksPath` resolves against the top level of the working tree, so `.githooks`
is correct from any subdirectory and inside a container where the repo is mounted at a different
absolute path.

## Testing

**devfleet** (bats, TDD, part of `make check`) — `tests/fleet-session-start.bats`:

- a fresh fleet root with no `core.hooksPath` gets `.githooks` after `fleet-session-start`
- a root already set to `.githooks` is left alone and nothing is journalled twice
- a root where the user set some *other* hooks path is left alone — the user's setting wins over
  ours, since overwriting a deliberate choice is worse than a missing backstop
- `fleet-session-start` still succeeds when the git config write fails

**The hook itself** — a small bats file per repo (`tests/githooks.bats` in devfleet,
`test/githooks.bats` in airlock, a vitest case in tea-axi), running the hook against a message
file and asserting the output:

- a Claude `Co-authored-by:` trailer is removed
- a human `Co-authored-by:` trailer survives
- the `🤖 Generated with [Claude Code]` line is removed
- a message with neither is byte-identical afterwards
- trailing blank lines left by a deletion are collapsed
- the hook exits 0 in every case

**airlock** and **tea-axi** each run their own suite; there is no cross-repo test, and the hook
is small enough that three copies of six assertions is cheaper than a shared fixture across
three repos with three test runners.

## Deliberately not done

- **No shared hook package.** Three repos, one 20-line `sh` script. A shared source would need a
  distribution mechanism, and the mechanism would be larger than the thing distributed.
- **No history rewrite.** Existing commits keep whatever trailers they carry. The rule is about
  what these repos record from now on, and rewriting published history to strip a trailer costs
  more than the trailer does.
- **No `pre-commit` identity check.** Enforcing *who* commits is the airlock git-identity spec's
  job (`airlock/docs/superpowers/specs/2026-07-26-git-identity-design.md`); this rule is only
  about what the message says.
