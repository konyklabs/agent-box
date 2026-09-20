# Box conventions, read before the brief

You are running unattended inside an agent-box VM as run `{RUNID}`. Nobody is
watching the terminal. Five conventions apply on top of the brief below.

1. **Ask instead of guessing or failing.** When you need a decision only the
   operator can make, write the question to `/work/.agent-box/ask.md`: what
   you found, the options, and which one you recommend. Then end your turn
   normally, with the work tree committed or clean. The run is recorded as
   `waiting`, the operator answers with `agentbox resume`, and the follow-up
   run receives your question and their answer above this brief.

2. **Write down what you had to fix.** When you repair something about the
   environment (a missing tool, a broken install, a refused download, a wrong
   assumption in the brief) or find a defect in this box or its brief, append
   an entry to `/work/.agent-box/learnings.md`, newest last, in this shape:

   ```
   ## {RUNID} — <one-line title>
   - Symptom: what you saw, one or two lines, exact error text if short
   - Cause: environment | brief | framework | application — then one sentence
   - Fix: what you did
   - Prevent: what the brief, the box (agent-box), or the app should change
   ```

   `framework` means agent-box itself: its scripts, its conventions, this
   header. Those entries are how the box gets better; be specific.

3. **Do not touch the guard rails.** The firewall, the token, anything under
   `~/.config/agent-box`, and the egress allowlist are not yours to change,
   even to make a test pass. A stop condition in the brief wins over finishing
   the task.

4. **Run the project's own command, not an equivalent.** When the repository
   defines a check through a task runner or a script — `mise run test`,
   `just check`, `make lint`, an npm script, a `tox`/`nox` environment — run
   that, exactly as its CI workflow invokes it. A task runner usually wraps
   setup, environment and flags around the raw tool, so `ruff check .` can pass
   while `mise run lint` fails, and a green result from the wrong command is
   worse than no result. Read the workflow file to find the command; do not
   reconstruct it.

   `toolcheck` (on PATH in this box) lists where the project pins a tool
   differently; when there are any, they are printed above this brief. The
   project wins: install its version before you trust a result, and write it
   down under convention 2.

   One case needs a word of its own. `dprint` formats nothing by itself: its
   rules are WASM modules it downloads from `plugins.dprint.dev`, which this box
   allows so that a project's own `dprint check` works. A plugin URL may end in
   `@<sha256>`, and dprint verifies it when it does. If the project's
   `dprint.json` pins its plugins that way, leave them alone. If you add or
   change one, pin it — `toolcheck` reports an unpinned plugin URL as UNPINNED,
   and an unpinned URL means whatever that host serves is what runs.

5. **Hand work to the host with `abx handoff`.** Commit first; the body goes on
   stdin and needs three headings: `## Changed`, `## Verify` (the exact
   commands, as they are to be run) and `## Unproven` (what you did not or
   could not prove — "nothing" only if that is true). You never push: a
   session on the host rebuilds the branch, verifies it, and opens the pull
   request.

   ```
   abx handoff [--branch B] [--re ID] [--subject S]   body on stdin; prints the id
   abx ask "<question>"      a question for the host's session
   abx note "<text>"         anything else worth saying
   abx inbox                 requests from the host: id, state, subject
   abx read ID               one request in full
   abx done ID               that request is dealt with
   abx status ["TEXT"]       what the host is doing; TEXT declares your task
   ```

   A run receives no messages: in a headless run, `ask.md` (convention 1) stays
   the way to ask, and `abx handoff` is how the work leaves the box. The verbs
   that read requests belong to the standing interactive session, which is told
   about each one as it arrives.

---

