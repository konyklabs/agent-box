# Brief: <one-line title>

Copy this file, fill it in, and hand it to the VM:

    agentbox run <repo> briefs/my-task.md --model sonnet

The whole file is the prompt. Anything vague here becomes a guess in there.

## Task

What to do, in two or three sentences. State the outcome, not the steps —
the steps are the agent's job. If a specific approach is required, say so and
say why, because otherwise it will be treated as one option among several.

## Repo and files in scope

The mount is `/work`. Name the directories and files that may be changed.

- `src/...`
- `tests/...`

Everything not listed is out of bounds.

## Definition of done

Checkable statements, not aspirations. Someone reading the diff must be able
to decide yes or no on each line without asking a question.

- [ ] ...
- [ ] ...
- [ ] The commands under "Tests to run" all pass, with their output pasted.

## Tests to run

**The command CI runs, exactly as its workflow invokes it** — `mise run test`,
`just check`, `make lint`, the npm script — not a hand-built equivalent. A task
runner usually wraps setup, environment and flags around the raw tool, so
`ruff check .` can pass while `mise run lint` fails, and a green result from the
wrong command is worse than no result. The box says the same thing to the agent as
convention 4; naming the command here is what makes it checkable.

Copy-pasteable, in the order they should run. If the task needs its own virtualenv
or `node_modules`, have the agent build it under a guest-only path such as
`~/.venvs/<repo>` rather than inside `/work` — `/work` is a shared mount, so an
environment built there overwrites the host's copy at the same path with
guest-native binaries. See "The friction, listed rather than debugged" in
`docs/daily-use.md`.

```
mise run test          # or whatever the workflow calls
```

If the repository pins a tool to a version the box does not have, the box prints
that above this brief with a `file:line` for each, and the project's pin wins:
install it before trusting a result, and write that down as a learning.

If the task needs the application running — only on a VM created with
`--docker` — say so as commands rather than as an aspiration, and say how the
agent knows the stack is up. "Start the app" is a guess; the four lines below
are not. Bring it down at the end, whatever happened, so a failed run does not
leave a stack holding the port and the disk. The box now also sweeps what a run
left running — its own processes, ports, worktrees and tmux sessions — but the
brief's own teardown still wins: it runs first, it knows what "down" means for
this stack, and it can bring containers down, which the sweep deliberately does
not.

```
docker compose up -d
timeout 120 sh -c 'until curl -sf http://127.0.0.1:3000/health; do sleep 2; done'
npx playwright test --trace on --output /work/test-results
docker compose down          # in a trap, or as the last step either way
```

Three things worth naming in the brief itself:

- Tests are **headless**. There is no display in the guest, so `--headed` and
  `--ui` do nothing useful. Traces, screenshots and videos are the evidence,
  and they must be written under `/work` to reach the host at all.
- **Chromium is already in the box**, shared at `$PLAYWRIGHT_BROWSERS_PATH`, so
  the first Playwright run downloads nothing. A repository pinning a different
  Playwright version installs that version in its own environment and may then
  need a browser download; say so here if it does.
- Anything the app calls out to needs an allowlist entry; the app itself does
  not. If the brief expects a third-party sandbox to answer, name it here so
  whoever runs this knows to add it before starting.

## Out of scope

The things that look adjacent and are not wanted. Being explicit here is
cheaper than reviewing a diff that wandered.

- Reformatting files the task does not touch.
- Dependency upgrades.
- Renaming anything.

## Stop conditions

When to stop and report rather than improvise.

- A test fails for a reason the brief does not cover.
- The change would need a file outside the scope above.
- The same failure recurs after two genuinely different fixes.
- Anything here turns out to be wrong or impossible.

## Notes

The box prepends its conventions to this brief: how to ask the operator a
question instead of guessing (`/work/.agent-box/ask.md`, then `agentbox
resume`), how to write down what had to be fixed
(`/work/.agent-box/learnings.md`), to run the project's own command rather than
an equivalent, and how to hand finished work to the host with `abx handoff`.
Start the run with `--heal N` to let the box retry a failure on its own; give
`--heal-delay` a value longer than any cooldown the tests are subject to.

A **headless run** receives no messages: `ask.md` is how it asks, and its result
is the branch plus the scrubbed summary. `abx handoff` belongs to an interactive
session in the box, where somebody is there to answer. If this brief is meant for
such a session rather than for `agentbox run`, say so here and say what the
handoff should contain — its three headings are `## Changed`, `## Verify` (the
exact commands) and `## Unproven`.

Nothing in this brief may name a customer, an internal system, or an internal
hostname. The repository is generic and this file travels with it.
