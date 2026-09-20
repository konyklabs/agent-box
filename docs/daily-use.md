# Daily use

`docs/first-run.md` gets the box built once. This is what using it looks like
afterwards: the ways to drive it, what of your own setup comes with you,
what deliberately does not, and the friction you should expect rather than
debug. `agentbox help` prints the whole surface with every option; this file is
the part that needs explaining.

---

## The two modes

**Interactive.** A normal Claude Code session, inside the VM, at `/work`:

```
./bin/agentbox claude ~/dev/my-e2e-tests
```

Arguments after the repository go straight to the CLI, so
`agentbox claude ~/dev/my-e2e-tests --model opus` works, and so does
`agentbox claude ~/dev/my-e2e-tests -p 'what does this suite cover?'`.

This is the mode to reach for when you are exploring, when the shape of the
task is not yet a brief, or when you want to watch. What it does not give you
is the headless mode's bookkeeping: no branch is made for you, the transcript
is on your screen rather than sealed in the VM, and nothing is scrubbed. That
is the trade — see `docs/decisions.md`.

An interactive `agentbox claude` now also becomes **the box's standing
session**: it takes the session name `claude`, gets a session directory, has the
channel hooks wired, and is the session `agentbox request` delivers to. It takes
that name only when the launch is genuinely interactive — a terminal at both ends
and none of `-p`, `--print`, `--version` or `--help` being passed through — and
only when the name is free. A second one is told on stderr that it is untracked
and receives nothing; it is not refused. `agentbox session` names the same session
explicitly, so it is the standing session too. See "Two sessions, one mount"
below.

**Headless.** One task, from a written brief:

```
cp templates/brief.md briefs/my-task.md   # fill it in
./bin/agentbox run ~/dev/my-e2e-tests briefs/my-task.md --model sonnet
```

The run gets its own `agent/<slug>-<timestamp>` branch, keeps its event stream
inside the VM, writes only a short scrubbed summary to the host, and checks
that summary and both diffs for fragments of your token before it reports
success. Use this for anything you intend to review as a diff.

It returns as soon as the run has started. The next section is how you watch
it.

`agentbox shell` is still there for looking around, and does not authenticate
anything: nothing exports the token into a plain shell.

Every launch of either mode re-scans the mount first, because a repository
changes between sessions: `agentbox preflight <repo>` is that scan on its own,
and `agentbox start <repo>` runs it again before the VM comes up.

## Watching and steering

A run is detached by default, in a tmux session inside the VM. Closing the
laptop, dropping the connection or quitting the terminal does not stop it.

### The run loop

```
./bin/agentbox run   ~/dev/my-e2e-tests briefs/my-task.md   # prints a run id
./bin/agentbox runs  ~/dev/my-e2e-tests                     # every run, newest first
./bin/agentbox logs  ~/dev/my-e2e-tests -f                  # follow the newest one
./bin/agentbox stop-run ~/dev/my-e2e-tests                  # interrupt it
```

`run` takes `--model M`, `--max-budget-usd X`, `--max-turns N`, `--wait` and
`--notify`. `--wait` blocks, streams the run and exits with its status, which
is what a script wrapping this wants. The two caps are passed to the CLI only
when the installed CLI has them: 2.1.261 has `--max-budget-usd` and does not
have `--max-turns`, and a run that is not capped says so rather than dying on
an unknown option.

`logs` takes a run id, `-f` to follow until the run ends, and `--json`. The
default is the newest run. What you see is one line per event, merged from
three sensors in time order:

```
12:00:01  status  agent-run: branch agent/my-task-20260905-120001 created from main
12:00:03  text    Reading the suite to see what it covers
12:00:04  tool    Edit  tests/test_orders.py
12:00:05  out     Applied 1 edit to tests/test_orders.py
12:00:07  hook    Notification  waiting for your input
12:00:41  result  success  turns=3  cost=$0.0412  duration=38s  is_error=false
```

If a run's leak check found the token in output that reaches the host, that run
exited 3 and `logs` will not print its events. You get a banner saying so and
telling you to rotate the token; `--force-unsafe` overrides it. The same applies
to the summary `run --wait` prints.

`stop-run` with no run id addresses **the newest run that is still running**,
and says which one it picked. If nothing is running it says so and stops; if
you name a run that has already ended it refuses rather than overwriting the
record of how it ended.

It interrupts the model rather than killing the pane, waits up to twenty
seconds, and then closes the session. `exit:stopped` is written only once the
session and its process have both been observed to be gone; if the run recorded
its own exit while we waited, that code is kept, because it is the truth about
what happened.

**Nothing is reverted, ever.** An interrupted run does not check out anything,
does not delete its branch, and does not touch the tree. That matters most when
the brief said to commit: a clean tree with three commits on it is exactly what
"nothing to restore" used to look like, and the branch would have been deleted
with `-D`. It is not, now. `run --wait` on a run you stopped prints the summary
and exits 130.

### The states a run can be in

| State | Means |
|---|---|
| `running` | the process is alive and the run is going |
| `done` | it ended on its own with exit 0 |
| `failed` | it ended on its own with a non-zero exit |
| `stopped` | `stop-run` interrupted it and it ended, whether or not the CLI had started |
| `lost` | it said running, and neither its tmux session nor its recorded pid was there |
| `unknown` | there is no status file to read |

Two of those words are unreachable for an interactive **session** row rather
than a run row, and `status --json` says so by construction: a session's state
is `running`, `ended` or `unknown` only. `stopped`, `waiting` and `lost` are
markers a run keeps in its own directory, and a session has no such directory.

A stop is recorded by the run itself, not deduced by the thing that stopped it:
`stop-run` leaves a `stop-requested` marker in the run directory before it
sends a signal, and the run leaves a `stopped` marker of its own on the way out
if it did not finish cleanly. The status file keeps the code the run actually
exited with, so a stopped run has an `exit_code` like any other; `stopped` is
what the marker says, not what the code says. One status is never
reinterpreted: `exit:3` is the leak check saying it found the token, and a run
that was also stopped still reads `failed` with exit 3, so the refusal in
`logs` still fires. It has to work that way because Claude Code exits 0 when it is
interrupted and says so only in its result event, so a stopper watching from
outside sees what looks like a successful run.

`lost` is what a run becomes when the VM was stopped underneath it, or its
process died without running its exit handler.

`stop-run` will not claim to have stopped a run whose CLI is still alive. It
escalates from an interrupt to a terminate, and if the process survives both it
says so and leaves the run recorded as running rather than reporting a stop
that did not happen. `runs`, `status` and
`agentbox start` each reconcile that before answering, so a run does not sit at
`running` for ever and `logs -f` does not block on one.

### Sessions you can leave

```
./bin/agentbox session ~/dev/my-e2e-tests briefs/my-task.md   # interactive, in tmux
./bin/agentbox attach  ~/dev/my-e2e-tests                     # back to it
./bin/agentbox attach  ~/dev/my-e2e-tests 20260905-120001     # watch a run, read-only
./bin/agentbox sessions ~/dev/my-e2e-tests                    # what is open in there
```

`session` is `agentbox claude` in a tmux session named `claude`, optionally
with a brief as the first prompt. Detach with the tmux prefix and `d`
(`Ctrl-b d` unless you have changed it) and the session keeps running. Attaching
to a **run** is read-only, because typing into a run's pane types at the agent.
`agentbox shell` is in tmux too, under the name `shell`.

`claude` is the standing session's name, so `session` and an interactive `claude`
converge on one session rather than two. If a non-tmux `agentbox claude` already
holds it, `agentbox session` refuses and names that process's pid instead of
opening a second pane that would be untracked.

Interactive output is not scrubbed. `agentbox session` says so once when it
starts, for the reason `docs/decisions.md` gives: there is no boundary to
filter at when the model's output is being drawn on your screen.

### Status

```
./bin/agentbox status                      # every box, one line each
./bin/agentbox status ~/dev/my-e2e-tests   # just that one
./bin/agentbox status --watch 5            # redraw every five seconds
./bin/agentbox status --json               # the contract a UI reads
```

```
BOX                            STATE     RUN / SESSIONS / FIREWALL
(one line per box; wrapped here to fit)
agent-box-example              running   fw=deny  claude=2.1.261  runs=4  tmux=2
                                         session=claude:idle  tools=ok  ch=1/2
                                         run 20260905-120001 running 38s turns=3
                                         cost=$0.0412  last: Edit tests/test_orders.py
```

`firewall` is read from the live `iptables` OUTPUT policy, not from whether a
systemd unit is enabled: `drop`, `open`, or `unknown` when it could not be
read at all. A stopped box costs nothing to display, and a running one costs
exactly one `limactl shell` per refresh.

Four parts are new, and each is omitted when there is nothing to say:

- `session=claude:<state>` — the standing interactive session, one of `working`,
  `idle`, `waiting` or `gone`. Absent when the box has never run one. Liveness is
  the session's recorded pid plus that process's own command line, not the
  status file and not tmux, so a hard VM stop reads as `gone` rather than as a
  session that is still working.
- `tools=ok | <N>missing | <N>off-pin | ?` — the baseline toolchain, from the
  snapshot written at boot. `?` means a tool answered in a way nothing could
  read; `agentbox toolcheck` is the by-name report.
- `left=<n>proc,<n>port,<n>wt,<n>tmux` — what earlier runs left running.
  Omitted when all four are zero, `left=?` when nobody could look.
- `ch=<unread>/<queued>` — messages from the box the host has not read, and
  requests the box has not picked up. Appended by the **host**, from the host's
  own record, and shown only when one of them is non-zero.

### Triage across the fleet

`status` answers "what is each box doing". `triage` answers the two questions
that come next: **may I stop this box, or delete it — and what would I lose?**

```
./bin/agentbox triage                 # every box
./bin/agentbox triage ~/dev/app       # one of them
./bin/agentbox triage --json          # the same, as data
```

```
BOX                            VM        FOOTPRINT  VERDICT    ACTION  BOX-ONLY  WHY
agent-box-example              running   7.4G       active     keep    1.2G      a run is working
agent-box-other                running   6.1G       attention  keep    411M      1 handoff from this box is unread
agent-box-third                running   5.3G       idle       ask     0         a standing session is open; stopping the box would end it
agent-box-fourth               stopped   5.0G       parked     ask     ? 09-18   the last reading found work only inside this box (09-18)
agent-box-fifth                stopped   4.2G       spent      keep    0         nothing is only inside this box
agent-box-sixth                stopped   3.8G       unknown    ask     ?         never triaged while running; start it to see
```

- **VERDICT** is one of `active`, `waiting`, `attention`, `idle`, `parked`,
  `spent` or `unknown`; **ACTION** is `keep`, `pause`, `remove` or `ask`.
- **ACTION is narrower than it looks, and deliberately so.** A running box is
  asked about only when its verdict is `idle` and something a stop would end is
  open: a standing session, or a request still queued for it. Anything more
  urgent than `idle` — a working run, a lost run, leftovers, an unread handoff —
  sets the verdict and the action stays `keep`, because the row has already told
  you the thing you needed to know and stopping the box is not what it is asking
  for. A stopped box is asked about when it is `parked` (the last reading found
  work only inside it, or there are commits on `agent/` branches that are on no
  remote) or `unknown` (nothing has ever read it). `pause` appears only for an
  idle box while memory is scarce, and `remove` only for a `spent` box while
  disk is scarce; neither is ever printed just because a box looks quiet.
- **BOX-ONLY** is what exists only inside that box: run transcripts, the
  session's own state, repositories in the guest home, Docker volumes and
  images. That number is the reason `remove` is a considered answer rather than
  an obvious one. A stopped box still reports it, from a watermark `triage`
  recorded the last time the box was running — the column is then `? 09-18` (the
  watermark said yes, with its date) or `0` (it said no), never a byte figure,
  and a plain `?` when there has never been a reading at all. In `--json` that
  last case is the reason code `no-reading`; the text column only ever shows `?`.
- **FOOTPRINT** is what the box costs on this Mac, measured from the instance
  directory, never from the configured disk size.

One `scarce:` line closes the footer below the table, always, printed with the
numbers it came from: `none`, `disk` (there is not enough free space to create
another box of the largest size you already use), `compute` (the running VMs
have been promised more memory than the Mac has) or `both`. `compute` is about
*commitment*, not measured residency — whether the hypervisor takes that memory
up front or grows into it is not something this tool measures, and the line says
so in its own word, *promised*. A `note:` line follows it when this Mac's memory
could not be read at all. Nothing is printed above the header row.

There is no `--watch`. One pass over every box is cheap; a loop is a guest call
per running box every few seconds, aimed at boxes you did not name — the same
reason `status --watch` needs a box.

`triage` writes as it reads: the box-only watermark is recorded in this host's
instance record so a stopped box can still be described. `status` already does
the same thing when it reconciles a run.

`pause` is `agentbox stop <repo>`, which frees the box's memory and keeps
everything else; `remove` is `agentbox destroy <repo>`. **Pair `remove` with
revoking the token.** `destroy` deletes the VM and the token file inside it; the
credential itself is revoked at claude.ai → Settings → Claude Code, and only you
can do that.

### Notifications

`--notify` on a run, or `notify: true` in `~/.config/agent-box/config`, starts
a small background process **on the host** that polls the run every ten seconds
and shows a desktop notification when it ends. One watcher per run, tracked by
a pid file under `~/.config/agent-box/watchers/`. The guest has no way to reach
your desktop and is not given one.

## Self-healing

A run that fails unattended used to stop and wait for a person. Three pieces
change that, and all three live in the guest, so recovery does not depend on
anyone being at the host.

**Every brief gets a preamble.** `guest/conventions.md` is prepended to every
brief before the CLI sees it. It tells the agent five things: when it needs a
decision only the operator can make, write the question to
`/work/.agent-box/ask.md` and end the turn; when it had to fix something about
the environment, or found a defect in the brief or in this box, append an
entry to `/work/.agent-box/learnings.md`; never touch the firewall, the
token or the allowlist; run the project's own command rather than an equivalent
of it; and hand finished work to the host with `abx handoff`. Read the file; it
is short and it is the contract. Because it is prepended to every brief, those
lines are the most leveraged prose in the repository.

**Heal on failure: `run --heal N`.**

```
./bin/agentbox run ~/dev/my-app briefs/task.md --heal 2 --heal-delay 120
```

When that run ends `failed` (not stopped, not waiting, not exit 3), the guest
starts a follow-up run on its own. Failed after the CLI ran, that is: a run
that dies in its preconditions (no token, the firewall unit down, `/work` not a
repository) is refused before the agent exists, and a follow-up in the same
box would meet the same refusal, so none is started and the summary says why.
The follow-up is: same model, same caps, a fresh run id, and
a new `agent/` branch cut from wherever the failed run left the tree, so its
commits are kept and nothing is redone. Its brief is `guest/heal-brief.md` rendered with the failed run's
state, exit code, result, the tail of its console and its last words, followed
by the **original** brief. It says: diagnose before changing anything, repair
the environment and write the learning down, do not loop on a brief or
application defect, then continue from where the previous run stopped. Each
follow-up has one less attempt; the chain stops at zero and the summary says
"this needs a person". `--heal-delay` is the wait before each follow-up, so a
failure with a cooldown behind it is not retried into the same wall.

`runs --json` carries `heal_attempt` and `heal_parent`; `runs` shows the
follow-ups as ordinary runs, newest first, and `last-run.txt` names the child.

**Ask instead of die: the `waiting` state.** A run that left a question in
`ask.md` during its own lifetime is recorded as `waiting`, whatever its exit
code was, unless it was stopped. `runs`, `status` and porthole show it, `run
--wait` exits 75 for it, and nothing burns while it waits.

```
./bin/agentbox ask ~/dev/my-app                      # the question, scrubbed
./bin/agentbox resume ~/dev/my-app --answer "Option B, and keep the test."
./bin/agentbox resume ~/dev/my-app 20260907-192113 --answer-file answer.md
```

`resume` starts a new run whose brief is `guest/resume-brief.md`: the question,
the answer, then the original brief, with the instruction to take the answer
as decided. The answer goes in on stdin, never as an argument in the guest.
With no run id it resumes the newest waiting run. A resumed run keeps the
heal budget the waiting run had.

Answer from anywhere you can run the CLI. From a phone that means a Remote
Control session on the host, which is a session you already have.

**Learnings.** `agentbox learnings <repo>` prints
`/work/.agent-box/learnings.md`, scrubbed. The entries have a fixed shape
(symptom, cause, fix, prevent) and a cause class: `environment`, `brief`,
`framework` or `application`. `framework` entries are about agent-box itself
and are the list to work through when improving it. The file lives under
`/work` on purpose: it is the operator's record, it survives the box, and it
is excluded from git through `.git/info/exclude` like the rest of
`.agent-box/`.

**The watchdog, for the failure the guest cannot heal.** A stopped VM, a Mac
that slept through a run, Lima falling over: the guest cannot recover from
those because the guest is what went away. `agentbox keepalive <repo> on`
marks a box, and `agentbox watchdog --install` puts a launchd job on the host
that runs every five minutes and, for each marked box, starts it if it is
stopped and asks the guest to heal its newest run if that run is `lost` and
has heal budget left. It starts no new work and touches no unmarked box. The
log is `~/.config/agent-box/watchdog.log`.

What the loop does not do, on purpose: it never widens the allowlist, never
changes the egress mode, never raises a cap, never pushes. A heal that would
need any of those writes a learning and stops.

## Review on a second model

A run that ends `done` is one model's word for it. `--review M` makes the box
ask a second one:

```
./bin/agentbox run ~/dev/my-e2e-tests briefs/my-task.md --model sonnet --review opus
```

When the run ends `done` and its branch has commits past where it was cut
(or a dirty tree), the guest starts a follow-up run on `M` from
`guest/review-brief.md`: the original brief, the commit list, the diffstat and
the run's last words, with instructions to read the diff against the
definition of done, re-run the tests the brief names, look for the things a
single unattended run gets wrong (a weakened test, a claim the diff does not
support, work outside scope, a missed stop condition), fix what is real in its
own commits, and write `/work/.agent-box/review.md`: one row per finding with
a disposition, then the suite's result and whether the branch is fit to push.
A finding only you can settle goes to `ask.md` and the review parks as
`waiting`, like any other run.

The review runs on a branch of its own, cut from the reviewed run's branch, so
it carries the original commits plus its fixes; that is the branch to look at
on the host. `agentbox runs --json` shows the lineage as `review_of` on the
review and `review_model` on the run that asked for one. The reviewer must be
a different model from the run's: the CLI refuses the same name, because the
point is a second opinion. A review is never reviewed, and a run that produced
nothing gets no review; the summary says `nothing to review`. A heal or a
resume keeps the reviewer's name, so the review is still owed at the end of a
chain.

Put `review: opus` in `~/.config/agent-box/config` and every run gets one
unless it says `--no-review`. `model`, `max_budget_usd` and `heal` take
standing defaults the same way.

## Two sessions, one mount

The shape this is built for is two Claude Code sessions: one inside the box,
standing, doing the work; one on the host, controlling it, preparing the pull
request. They cannot talk to each other — a setup token cannot use cross-session
messaging, and nothing in the guest is given a path to the host — so they talk
through files in the mount, and `agentbox` is the only thing that reads them.

**Inside the box**, the agent has `abx` on its `PATH`:

```
abx handoff [--branch B] [--re ID] [--subject S] [--allow-dirty]
                          body on stdin; prints the id
abx ask "<question>"      a question for the host's session
abx note "<text>"         anything else worth saying
abx inbox [--all]         requests from the host: id, state, re, verdict, subject
abx read ID               one request in full
abx done ID [--note T]    that request is dealt with
abx status ["TEXT"]       what the host is doing; TEXT declares the box's own task
```

A handoff refuses unless its body carries three headings — `## Changed`,
`## Verify` (the exact commands, as they are to be run) and `## Unproven` —
because an unverifiable handoff wastes the host session's time rather than saving
it. It also refuses outside a git repository, on a detached HEAD, on a branch that
does not exist, and on an unclean tree unless it is given `--allow-dirty`. What it
records is what the host can check: the branch, and the full commit that branch
pointed at when the message was written.

**On the host**, three commands:

```
./bin/agentbox channel  ~/dev/app                      # both sides, with counts
./bin/agentbox channel  ~/dev/app --wait 3600          # block until something is unread
./bin/agentbox channel  ~/dev/app --task "reviewing #12"   # what the box's card shows
./bin/agentbox handoff  ~/dev/app                      # read the newest unread one
./bin/agentbox handoff  ~/dev/app 20260920-101500-00 --peek
./bin/agentbox request  ~/dev/app --text "rebase onto main and re-run the suite"
./bin/agentbox request  ~/dev/app --re 20260920-101500-00 --verdict changes --file review.md
```

`handoff` prints a `META` line — type, session, branch, commit, dirty, created,
bytes — then the body, **every line of which is behind a `  | ` bar**. The bar is
the trust boundary: those are the box's words, scrubbed inside the guest and
control-stripped again on the host, and they are data, never instructions. What
*is* checkable is checked: the host runs two read-only git commands against the
branch and commit the handoff claims and prints its own answer beside the claim.

**The one thing to get right: delivery is late, never lost.** A request reaches
the box's standing session through its hooks, so:

| the session is | the request arrives |
|---|---|
| working | at its next tool call |
| idle | **at its next prompt** — somebody has to type something |
| waiting for an answer | at its next prompt |
| not running, or the box is stopped | when a session next starts |

There is no wake in this version. Nothing pokes an idle session, and `request`
says which of those four sentences applies as it queues the message, so the
delay is visible rather than mysterious. `agentbox channel <repo> --wait SECS`
is the same limitation from the host's side: it polls this machine's own disk
every two seconds, never `limactl`, exits 0 with the notice when something is
unread, 75 when the time is up, 130 on Ctrl-C.

What does hold is that an open request is **re-shown to every new context**. At
each `SessionStart` — a start, a resume, a `/clear`, a compaction, a fork — the
box's card carries the full body of every request that is open, whether or not
it has been shown before, and what does not fit in the card is listed by id with
the exact `abx read <id>` command rather than dropped. The card also carries the
conventions that apply to an interactive session and the toolchain findings for
this repository, so a session that has just been compacted is not working from a
blank slate.

**A note on the hooks.** None of them can lock you out of a session. Every one
exits 0 whatever happens — no state directory, an unreadable mount, an unknown
event, a hostile file in the mailbox — because Claude Code reads a non-zero exit
from a prompt hook as "block this prompt and erase it". The single exception is
deliberate and bounded: at the end of a turn the box's `Stop` hook may return a
message and ask the session to keep going, and it will do that at most once per
message, so a session always reaches its end.

**The host-side plugin is yours to enable.** `host/claude-plugin/` is a Claude
Code plugin whose hooks ask `agentbox channel-hook` on `SessionStart` and
`UserPromptSubmit` whether a box this session is working in has anything open,
and print one host-authored line if so. Nothing a box wrote reaches the session
through it — only validated ids and this machine's own words. Loading it is a
change to **your** Claude Code configuration and agent-box does not make it:

```
claude --plugin-dir ~/dev/agent-box/host/claude-plugin
```

The channel works perfectly well without it. The plugin is a reminder; `channel`,
`--wait` and `status` are the pull path, and they are what the commands above use.

The hook decides which box a session is about from **physical paths**, not from
git: the resolved working directory has to sit inside a repository this host has
recorded for a box, or inside that box's bench. A box created before this version
has no repository recorded, so it becomes discoverable after its first
`agentbox start | session | claude | request | channel <repo>` on the new
checkout, which backfills the record.

A few honest edges: ids are UTC timestamps with a two-digit suffix, so they order
within one direction and no arithmetic is ever done on them; the box's own copies
of the read and done receipts are a courtesy for its card, and the host believes
only its own record under `~/.config/agent-box/channel/`; message bodies cannot
be read while the box is stopped, because the scrubber that knows the token lives
in the guest — ids, states and counts still work; and a headless `agentbox run`
receives nothing at all, because mid-run mail makes a result irreproducible.
`ask.md` stays a run's way to ask a question.

Old messages are swept once a UTC day: anything over 30 days by the date in its
name, and anything answered and over 7 days.

## The bench: verifying on the host

A handoff says "this branch works". Checking that on the host used to mean
building in the same directory the box builds in, which is the oldest friction in
this project: `/work` is a shared mount, so a Linux `.venv` or `node_modules` the
agent created lands exactly where the Mac's own copy was.

```
./bin/agentbox bench ~/dev/app                      # create or refresh it
./bin/agentbox bench ~/dev/app --branch agent/fix-login
./bin/agentbox bench --list                         # every bench, with its branch and HEAD
./bin/agentbox bench ~/dev/app --remove [--force]
```

The bench is a **clone** of the repository at `~/.config/agent-box/bench/<instance>/`,
outside the mount, made with `git clone --no-local` so that not one object file is
shared with a directory the guest can write. Build there, run the project's own
CI command there, and the Mac's copy of the repository is untouched.

`bench` never calls `limactl` and never touches the VM: it works on the
repository, so a stopped box is not a problem and a box that is gone is only a
problem if you gave a bare name rather than a path (the repository comes from this
host's record then, and a box created before this version may not have one until
its next `agentbox start`). With no `--branch` it takes the branch the repository
is on right now; on a detached HEAD it asks you to name one.

Four things worth knowing before you rely on it:

- **It sees commits only.** Every `bench` prints that sentence, every time:
  anything the box has not committed is not in the bench. The host does not
  measure the box's uncommitted work either — that would mean running `git status`
  in a repository whose `.git/config` the guest can write — so the box's own
  `dirty:` claim in a handoff is what you have, and it is behind the bar.
- **It is disposable, and two guards keep it so.** A refresh refuses if the bench
  has modified tracked files, and refuses if it holds a commit the repository does
  not — printing, rather than leaving you to reconstruct it, the exact command
  that moves those commits back: a `git cherry-pick` of the bench's extra commits,
  oldest first, run **in the mounted repository** and carrying the same three
  protections every git command this tool prints carries (`--no-pager`,
  `core.fsmonitor=false`, `core.hooksPath=/dev/null`). Read it before you paste
  it: a cherry-pick applies onto whatever branch the repository is standing on
  right now, so check that branch first — this does not put the commits somewhere
  out of the way, and a conflict lands in your own working tree. Untracked files
  are not counted, because untracked files in a bench are the build; so something
  you wrote by hand in there and never committed is not protected by `--remove`.
- **It is excluded from Time Machine**, for the same reason `~/.lima` is: it fills
  up with dependency trees that are rebuildable by definition.
- **It runs code the box wrote, on the host, outside the VM.** That is the point
  of it and it is also the one place the boundary is stepped around deliberately.
  Read the diff first; treat `## Verify` as a stranger's pull request.

`agentbox destroy` removes the box's bench with it.

## Ready, and what it means

Every box carries the same toolchain, pinned in `guest/toolchain.pins`, installed
at every start and idempotent: `uv`, `ruff`, Node with `npm`/`npx`, `mise`,
`trufflehog`, `actionlint`, `dprint`, `basedpyright`, `semgrep`, `playwright` and
a shared Chromium under `/opt/ms-playwright`. There is no flag: a create-time flag
would never reach a box that already exists, and unconditional provisioning
reaches every box at its next start.

```
./bin/agentbox toolcheck ~/dev/app                  # the table
./bin/agentbox toolcheck ~/dev/app --json
./bin/agentbox toolcheck ~/dev/app --project-only    # just this repository's pins
```

| exit | means |
|---|---|
| 0 | every baseline tool is at its pin, and this repository pins nothing differently |
| 10 | a baseline tool is missing, off its pin, or answered in a way nothing could read |
| 11 | the box is at baseline and **this repository pins a tool differently** |
| 1 | a usage error, or the box's pins file could not be read, so nothing was compared |

**A finding is a report, not a block.** The installer is fail-soft by design:
nothing in it may fail a boot, a failed tool is a warning that is retried at the
next start, and under 4 GiB free it does nothing at all and tells you to resize.
A box that will not open a shell because a formatter's download failed would be a
worse box. What changed is that a *new* box is not reported ready when it is not:
`create` runs the check at the end and exits with its status, printing
`NOT READY: <tool> …` lines, and the box still exists and is still usable.
`start` on an existing box prints the same lines as `WARNING:` and exits 0.

When the box's tools move, they move because you moved them: `host/refresh-pins.sh`
rewrites the pins file — downloading each asset and hashing it itself, writing
nothing if any download failed — and then each box picks the new pins up at its
next `agentbox start`. Nothing updates on its own.

### When the project pins a different version

`toolcheck` also reads the repository's own files — `mise.toml` and its four
siblings, `.tool-versions`, `.python-version`, `.nvmrc`, `.node-version`,
`pyproject.toml`, `uv.lock`, `package.json`, `package-lock.json`, and the
workflow files for a handful of known setup actions — and reports where the
project asks for something other than the box's pin, with `file:line` for each.

Nothing in the repository is executed to find that out, and the box does not
install the project's version for you. It could not do so safely: a version
string from `/work` is untrusted input, and acting on it automatically means
running a version chosen by whoever wrote the repository as part of starting a
box. The agent is the right actor — it can read the workflow and decide — so
convention 4 of `guest/conventions.md` tells it to, the findings are printed
above every brief, and the interactive session's card carries them too.

Two cases need a line in `~/.config/agent-box/guest/allowlist.local`, because
the base allowlist does not carry them:

- `plugins.dprint.dev` — `dprint` is installed and pinned, but it fetches its
  formatter plugins at run time, and under `deny` that fetch is refused. A
  repository whose CI runs `dprint check` needs the line.
- `semgrep.dev` — only if a project uses registry rule packs (`--config p/...`).
  Semgrep's own bundled rules work offline.

## What a run cleans up, and what it never touches

A run starts things: a dev server, a compose stack, a git worktree, a tmux
session. Before this version they outlived it silently. Now a run records what it
started and closes it again at the end, and what it could not close is reported.

```
./bin/agentbox leftovers ~/dev/app           # what earlier runs left running
./bin/agentbox leftovers ~/dev/app --json
```

Four classes are tracked — processes, listening ports, git worktrees and tmux
sessions — and the sweep runs in one order: re-observe, tmux sessions, processes,
worktrees, then ports (reported, never killed), and finally a `hygiene` line that
`summary.txt` keeps.

What it kills is narrow, on purpose. A process has to be in the run's own process
group **or** carry the run's own events directory in its environment, and it has
to have started after the run's baseline — a start-time comparison, because pid
numbers are reused. A worktree is removed by path only, and only a path that is an
existing directory in the box, is not the mount or a parent of it, and resolves
under the mount or the guest home; `git worktree prune` is never run, ever. A
process whose start time cannot be read is **never signalled and never hidden**:
it is reported as a survivor whose ownership could not be verified.

**A standing session's processes are never candidates.** Two independent
mechanisms say so — the session is in no run's process group, and its processes
predate the run's baseline — because the failure this prevents is the tool killing
the dev server you started yourself. The cost is honest: a session's leftovers are
shown and never cleaned, so a long-lived box accumulates them and you are the only
cleaner.

`leftovers` reports; it does not clean. The run's own sweep kills from inside, at a
moment it controls, only what it can prove it owns. A host-side cleaner would have
to kill a process it cannot identify on the strength of a record an agent could
have written, and if one is ever built it will be a separate, confirming command.

## Egress modes

Every box has one, chosen at create and shown by `agentbox egress`:

```
./bin/agentbox egress ~/dev/my-app             # show it
./bin/agentbox egress ~/dev/my-app observe     # change it, rebuild, verify
```

| mode | non-allowlisted traffic | logged | `firewall-check` asserts |
|---|---|---|---|
| `deny` | refused | no | the allowlist refuses what it should |
| `observe` | **allowed** | yes | the log rule is in place and the chain ends in ACCEPT, never a silent deny |
| `open` | allowed, unfiltered | no | INPUT is intact and OUTPUT is unfiltered |

One thing `observe` does **not** relax: DNS to a server other than the guest's
own resolver stays refused, in every mode except `open`. Port 53 to an
arbitrary host is a channel whose payload is the query name, so "allowed and
logged" there would carry data out while recording only that something went.

The mode every reporter shows is read from the **live ruleset**, not from the
file that records what was asked for. When the two disagree the answer is
`unknown`, with a `firewall_detail` saying what each of them said — which is
the honest answer to "which of these should I believe".

`firewall_detail` is **present only when there is something to say**: the mode
is `unknown`, or the file and the ruleset disagree. On a healthy box the key is
absent, not null. Every other nullable key in that object means "this was asked
for and is unavailable", so a null here would read as a fourth unknown rather
than as nothing to report.

Changing the mode rebuilds the firewall immediately and prints the
verification, so the answer to "did that take" is on the screen. `open` prints
a warning naming what it gives up. The mode appears in the create summary, in
`agentbox status`, and as the first line of `run` and `session` when it is not
`deny` — the quiet default stays quiet.

INPUT never changes. `open` is about what the guest may reach, not about what
may reach the guest: ssh from the hypervisor gateway remains the only way in,
and IPv6 egress stays closed in every mode.

### What an observe box tried to reach

```
./bin/agentbox egress-log ~/dev/my-app --since 24h
./bin/agentbox egress-log ~/dev/my-app --since 24h --json
./bin/agentbox egress-log ~/dev/my-app --since 24h --as-allowlist
```

Unique destinations, newest last, with the count, the times, and the name the
guest resolved for that address when the resolver's log still remembers it. A
dash means it does not — the agent connected to a literal address, or resolved
it before the window. `--as-allowlist` gives you lines to paste into
`allowlist.local`, with bare addresses commented out because an address without
a name is a judgement call.

## What goes in an allowlist

`allowlist.base` in the repository and `allowlist.local` on the host take three
line forms:

```
api.example.com       an exact name. Resolved on every rebuild, so it works
                      before anything looks it up, and also fed live.
10.0.0.0/8            an address range. No resolution, no expiry.
.staging.example      a suffix: the domain and everything under it.
*.staging.example     the same thing, if you prefer the glob.
```

**A dot line is a subtree and follows the resolver. A bare name is one host,
pinned at rebuild.** They are different mechanisms, not two spellings:

- `api.example.com` is resolved on every rebuild and its addresses are pinned
  until the next one. Nothing else under `example.com` is admitted.
- `.example.com` is not resolved in advance at all. It becomes a rule in the
  guest's resolver, which adds each address to a second set as the guest looks
  a name up — so `anything.example.com` is admitted the moment something
  resolves it.

So a dot line is how you say "this whole environment", and it is also how you
say "this host rotates its addresses faster than a rebuild can pin them" — the
two entries in `allowlist.base` written with a dot, `.cdn.playwright.dev` and
`.storage.googleapis.com`, are there for the second reason and carry the cost
of the first. Write a bare name unless you mean the subtree.

The two sets are kept apart on purpose. The rebuild owns the pinned one and
replaces it wholesale; the resolver owns the other and its entries expire after
an hour. That is what makes removing a line take effect: delete a suffix, and
the next rebuild flushes the resolver's set rather than carrying its addresses
forward for ever.

Three consequences worth knowing. **If the resolver is down, nothing resolves
and the box is closed to everything by name** — it fails closed, not open, and
`firewall-check` says `FAIL resolver-up` in as many words. **An IPv6 range is
accepted and reported as inert**, because v6 egress is closed entirely; the
line is remembered for the day that changes. And **a malformed line is a
warning, not a failure** — it is named in the log and skipped, so a typo in
`allowlist.local` cannot take the box down.

### Observe's log is a record, not a control

Worth being plain about, because the word "log" invites the opposite reading.
In observe mode the traffic is **allowed first and recorded second**, and the
recording is rate-limited per destination so that one chatty host cannot crowd
the others out of the journal. When the limit bites, packets still pass and log
lines are dropped — never the other way round. An agent that wanted to hide a
destination could bury it under its own noise, and the per-destination limit
raises the price of that without removing it. Observe tells you what a
repository reaches for when it is not trying to deceive you; it is not a
control, and a box you do not trust belongs in `deny`.

### The JSON is the contract

`runs --json`, `logs --json` and `status --json` are stable, snake_case, with
ISO 8601 UTC times and durations in seconds. Every subcommand stops reading
options at a literal `--`, which is how a caller that assembles a command line
says where its operands begin:

```
./bin/agentbox runs --json         -- ~/dev/my-e2e-tests
./bin/agentbox logs -f --json      -- ~/dev/my-e2e-tests 20260905-120001
./bin/agentbox stop-run            -- ~/dev/my-e2e-tests 20260905-120001
```

`status --json`'s `run` is the **newest** run whatever state it is in, so a run
that has finished stays visible with its state, its exit code and its total
duration in `elapsed_s`. It is `null` only when the box has never run anything,
or is not running. `state` is one of `running`, `done`, `failed`, `stopped`,
`lost` or `unknown`. `exit_code` is the code the run exited with, and it is
null only where there is no such code: `running`, `lost`, `unknown`, and a stop
the stopper had to record itself because the run never got to. A stopped run
that recorded its own exit therefore has a number there, usually 1 or 130.
`sessions` is `null`, never `[]`, when the list could not be read: an empty
array means the box genuinely has no sessions.

**The null rule, stated once, because five keys now depend on it.** `null` means
*nobody could answer*. An empty array or a zero means *genuinely none*. Absence
means neither and is reserved for exactly one key, `firewall_detail`, which is
present only when there is something to say. A stopped box therefore reports
`runs_total: null` and `sessions: null` rather than `0` and `[]`: runs live in the
guest, and a host that cannot reach the guest has not counted them.

Five keys are new in the per-box object, and the **guest's** object is printed
first with the host's own keys after it — `name`, `instance`, `repo`, `state`,
`channel` — so that a guest answer carrying a duplicate `"state"` loses, both `jq`
and Python taking the last of a repeated key.

| key | shape |
|---|---|
| `standing` | `{name, state, since, task, last_tool, last_text, runs_unseen}`, or `null` when the box has never run a standing session. `state` ∈ `working\|idle\|waiting\|gone`. |
| `channel` | `{to_host_unread, to_host_open, to_host_newest, to_box_queued, to_box_open, to_box_lost}` — **host-computed**, from file names and this host's own record, so it is present for a stopped box. `null` when the repository directory is gone or a path component of the mailbox is not a plain directory. |
| `toolchain` | `{state, missing, off_pin, checked_at}` with `state` ∈ `ok\|findings\|unknown`; `missing` and `off_pin` are counts, not names. Read from the snapshot written at boot; `null` when it could not be read. |
| `leftovers` | `{procs, ports[], worktrees[], tmux[], runs[], truncated}`, `null` when nobody could look. `truncated` is true when the scan stopped at its 200-row limit. |
| `sessions[]` | each row is `{name, kind, runid, state, age_s, last_event, produced}`. `kind` ∈ `run\|session\|other`; `produced` is `{"branch": …}` for a run row and `null` otherwise; `age_s` can be `null` (a clock that moved). |

`runs --json` gains `survivors`: the number of distinct things a run left running
after its own sweep, or `null` when the run has no sweep record to read.

`triage --json`, `ports --json`, `bench --json`, `channel --json`, `handoff --json`
and `toolcheck --json` are the same contract in shape and spirit. Two of them nest
the box's own answer under `untrusted` as the **first** key, with every host key
after it, for the reason above; `toolcheck --json` is forwarded from the guest
untouched, because the only host-side use of that report is its exit status.

`--watch` needs a named box. A one-shot `agentbox status` across every VM is
cheap; a loop across every VM is a python process and a tmux client inside each
of them every few seconds, aimed at boxes you did not name. A user interface built on this is
a renderer of those three commands: it never talks to `limactl` itself, and it
never reads anything inside the guest. That is what keeps the scrub in one
place. `status --json` looks like this:

```json
{"generated_at": "2026-09-05T16:00:00Z",
 "boxes": [{"name": "my-e2e-tests", "instance": "agent-box-my-e2e-tests",
            "repo": "/Users/you/dev/my-e2e-tests", "state": "running",
            "claude_version": "2.1.261 (Claude Code)", "firewall": "deny",
            "run": {"id": "20260905-120001", "state": "running", "exit": null,
                    "model": "sonnet", "branch": "agent/my-task-20260905-120001",
                    "started_at": "2026-09-05T12:00:01Z", "elapsed_s": 38,
                    "turns": 3, "cost_usd": 0.0412,
                    "last_tool": "Edit  tests/test_orders.py",
                    "last_text": "Reading the suite to see what it covers"},
            "runs_total": 4,
            "sessions": [{"name": "claude", "kind": "session", "runid": null,
                          "state": "running", "age_s": 900,
                          "last_event": null, "produced": null}],
            "standing": {"name": "claude", "state": "idle",
                         "since": "2026-09-20T09:45:00Z", "task": "reviewing #12",
                         "last_tool": "Bash", "last_text": null, "runs_unseen": 0},
            "toolchain": {"state": "ok", "missing": 0, "off_pin": 0,
                          "checked_at": "2026-09-20T09:30:00Z"},
            "leftovers": null,
            "channel": {"to_host_unread": 1, "to_host_open": 1,
                        "to_host_newest": "2026-09-20T10:15:00Z",
                        "to_box_queued": 2, "to_box_open": 2, "to_box_lost": 0}}]}
```

The host keys come last in the real output; they are shown here in the order a
reader finds them natural.

### What a run leaves behind, and where

Inside the VM, at mode 700, never on the host's disk:

```
~/.agent-box/runs/<runid>/
  meta.json      model, branch, brief, start time, tmux session, the caps
  events.jsonl   the raw stream-json from the CLI
  hooks.jsonl    one line per hook event
  console.log    what agent-run.sh printed, one timestamp per line
  status         running, then exit:<code> or exit:stopped
  summary.txt    the scrubbed summary, the same text that reaches the host
  owned.jsonl    what this run started, and what the sweep did with it
  owned-clear    written when every recorded thing is gone
  toolchain-report.txt  the project-pin findings that went into this run's brief
~/.agent-box/sessions/<name>/hooks.jsonl   the same for an interactive session
~/.agent-box/sessions/claude/              the standing session's own state:
  pid, task, last-text, channel.seen, runs-seen                 (mode 700/600)
```

Two things cross to the host's disk, both under `<repo>/.agent-box/`:
`last-run.txt`, the scrubbed run summary, and `channel/` — the mailbox the two
sessions talk through. Both are checked for token fragments: the summary before a
run reports success, and every file the box wrote into its outbox as part of the
same leak check.

```
<repo>/.agent-box/
  .gitignore     "*" — written by whichever side creates the directory first
  last-run.txt   the scrubbed summary of the newest run
  learnings.md   the operator's record; deliberately outside the guest
  ask.md         a waiting run's question
  review.md      a reviewing run's findings
  channel/
    to-host/<id>.md   + .read / .done sidecars   what the box sent
    to-box/<id>.md    + .delivered / .done       what the host sent
    host-status       a courtesy copy of the host's own line, for the box's card
```

The mailbox is guest-writable, which is the whole reason the host keeps its own
record under `~/.config/agent-box/channel/<instance>/` and believes that instead.
A forged `.read` or `.done` on the mount changes nothing the host reports.

## Host configuration layout

Everything site-specific lives here and nothing of it is ever committed:

```
~/.config/agent-box/
  config                     standing defaults, one `key: value` per line:
                             egress, model, max_budget_usd, heal, review, notify
  blocklist.txt              read on the host only, NEVER mounted
  watchdog.log               what the launchd job did, if you use keepalive
  watchers/<runid>.pid       one per `run --notify` watcher
  instances/<instance>       this host's record of a box, `key=value` per line:
                             egress, repo, keepalive, forward, bench, bench_branch,
                             boxonly, boxonly_bytes, boxonly_at
  channel/<instance>/        this host's own channel record, never the box's:
                             read, done, sent, host, gc.stamp
  bench/<instance>/          a host-side clone of the box's repository
                             (AGENT_BOX_BENCH_DIR moves this root)
  guest/                     mounted read-only at /opt/agent-box-config
    allowlist.local          extra egress entries, one per line: a name,
                             a CIDR range, or a .suffix
    ca.pem                   corporate TLS-intercept root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  files copied into the guest's config directory
      CLAUDE.md
      settings.json
      supervisor.json
      governor.json          legacy: the pre-2.0 name, still carried
      rules/*.md
```

The split between the parent directory and `guest/` is the important one:
`blocklist.txt` is the list of terms that must never leave, so it is the one
file an agent must not be able to read. `agentbox create` refuses to start if
it finds it inside `guest/`. Everything else above `guest/` is not mounted
either, and that is load-bearing for three of them: the instance record holds
host paths, the channel record is what makes a box unable to rewrite its own
read receipts, and the bench is a copy of the repository the box must not be
able to reach.

## What carries over, and what does not

Carried over, by name, on every launch:

| File | Effect in the guest |
|---|---|
| `claude/CLAUDE.md` | `$CLAUDE_CONFIG_DIR/CLAUDE.md` — your standing instructions |
| `claude/settings.json` | user settings for the guest CLI, **filtered** — see below |
| `claude/supervisor.json` | supervisor configuration, if you use that plugin |
| `claude/governor.json` | the pre-2.0 name, still carried, with a nag |
| `claude/rules/*.md` | `$CLAUDE_CONFIG_DIR/rules/` |

`rules/` is the one directory the sync owns outright, so it is the one place a
deletion follows: remove a rule on the host and the next launch prunes it in
the guest, with a `pruned` line saying so. The rest is additive — a `CLAUDE.md`
deleted on the host stays in the guest until you delete it there or destroy the
VM.

Deliberately not carried over, and refused out loud if you leave one there:

- **`.credentials.json` and anything `*.token`.** The VM gets exactly one
  credential, typed in by `agentbox token`, and it lives at
  `~/.config/agent-box/token` inside the guest at mode 600.
- **`projects/`, `history*`, `todos/`.** Your conversation history from other
  machines and other work has no business inside a VM pointed at a work
  repository. This is the inward direction of the threat model.
- **`plugins/`.** Installed plugin state is machine-specific; the guest
  installs its own from `plugins.txt`.
- **`.claude.json`.** It is the file the guest maintains itself, and it holds
  per-project history.

The copy is an allowlist, not a mirror, for the reason `docs/decisions.md`
gives: a blind copy of a directory you edit by hand is one careless `cp` away
from carrying a personal credential into a VM that runs against work code.

### `settings.json` is filtered, not just allowlisted

Matching on the file's name is not enough for this one, because the Claude Code
settings format can carry a credential inside a file that is legitimately on
the list. `env` is merged into the CLI's own process environment, so
`"env": {"ANTHROPIC_API_KEY": "sk-ant-..."}` is a literal key. `apiKeyHelper`
is a shell command the CLI runs to mint one. `awsAuthRefresh` and
`awsCredentialExport` do the same for Bedrock. None of that is exotic misuse —
it is the ordinary content of the very file you would copy in to get your
settings.

So the object is parsed and filtered on the way in. Those four keys are
removed, as is any value anywhere in the document that starts with `sk-ant-`,
and each removal is named:

```
sync-claude-config: STRIPPED settings.json:env — credential-bearing settings never cross into the guest
```

The same check runs again where the token is exported, so a `settings.json`
edited inside the guest cannot reintroduce one either: `agentbox run`,
`agentbox claude` and `agentbox verify-auth` refuse to start and name the key.
Both halves matter, because a key delivered this way would arrive *after* the
`ANTHROPIC_API_KEY` shell-environment check has passed, and would quietly bill
an API account instead of drawing on the subscription.

Two keys go the other way. `enabledPlugins` and `extraKnownMarketplaces` are
where `claude plugin install` records what it did, so they belong to the
guest's own CLI: the host's values are dropped and the guest's are preserved.
Without that, every sync would disable the plugins the guest had just
installed, and the host's marketplace entry — which names a directory on your
Mac — would be carried into a VM where that path does not exist.

Anything else in the file is yours and is copied as written, so a `hooks` entry
or a `statusLine` command that names a host path will simply not work in there.

## Plugins

Two mechanisms, for two different situations.

**Installed, from a marketplace.** Write `~/.config/agent-box/guest/plugins.txt`:

```
# one directive per line, '#' starts a comment
marketplace konyklabs/claude-plugins
install supervisor@konyklabs-plugins
install py-testing@konyklabs-plugins
```

`marketplace` takes what `claude plugin marketplace add` takes: an
`owner/repo`, a URL, or a path. `install` takes `plugin@marketplace`.

The marketplace **name** is not the repository name — it comes from the
marketplace's own `.claude-plugin/marketplace.json`. `konyklabs/claude-plugins`
registers as `konyklabs-plugins`. If you are unsure, add the marketplace and
read the name back:

```
./bin/agentbox shell ~/dev/my-e2e-tests
claude plugin marketplace add <owner/repo>
claude plugin marketplace list
```

The file is applied during provisioning, on first boot, and on demand:

```
./bin/agentbox plugins ~/dev/my-e2e-tests            # install what is missing
./bin/agentbox plugins ~/dev/my-e2e-tests --update   # refresh and update
```

It is idempotent: an already-registered marketplace and an already-installed
plugin are reported and skipped.

**Loaded per session, from the host.** Anything under
`~/.config/agent-box/guest/plugin-dir/` that contains
`.claude-plugin/plugin.json` is passed to the CLI as `--plugin-dir` by
`agentbox claude`, `agentbox run` and `agentbox verify-auth`. Nothing is
installed and nothing is written: the plugin is active for that session only,
straight from the read-only mount. This is the right shape for a plugin you are
still writing on the host — edit it there, run the next session, see the
change.

### The trust gotcha

A repository's own `.claude/settings.json` — its `extraKnownMarketplaces` and
`enabledPlugins` in particular — is **inert** in a folder Claude Code has never
been told to trust, and `-p` has no way to ask. The VM therefore marks `/work`
trusted for you, in `$CLAUDE_CONFIG_DIR/.claude.json`, every time it launches
anything. There is one folder in this VM and the host scanned it with
`preflight` before the VM was allowed to mount it, so this is a considered
decision rather than a convenience — but it is worth knowing that it happened,
because it means a repository's own plugin declarations do take effect in
there.

## Running an application stack

Only on an instance created with `--docker`. On any other, `docker` is simply
not installed — the profile is fixed when the VM is made.

```
./bin/agentbox create ~/dev/my-app --egress deny --docker --forward 3000
./bin/agentbox shell  ~/dev/my-app
```

Inside, it is ordinary Docker. The daemon is rootful, the guest user owns the
socket, and `docker compose` is the v2 plugin:

```
cd /work
docker compose up -d
docker compose ps
docker compose logs -f web
docker compose down
```

**Ports.** Publish on `127.0.0.1` inside the guest and the stack is reachable
at `127.0.0.1:PORT` in there, which is all a test running in the guest needs.
To open the page in a browser on the Mac, the port must also have been named at
create time:

```
ports:
  - "127.0.0.1:3000:3000"     # in compose.yaml, inside the guest
```

```
./bin/agentbox create ~/dev/my-app --egress deny --docker --forward 3000
```

`--forward` is fixed at create time on purpose, and it is the one widening in
the whole design: that guest port becomes reachable by any process on your Mac
for as long as the VM runs. Forward the ports you actually want to look at, not
a range.

**A held host port is refused rather than silently ignored.** Lima cannot bind a
host port something else already holds, and the forward then simply does not
answer — which reads as a guest problem and is not one. So `create` probes each
port first and refuses, naming the port and the process holding it; and because a
forward cannot be moved afterwards, `agentbox start` probes the box's recorded
forwards again and refuses too, since a port can be taken while a box is stopped.
`start --ignore-port-conflict` starts anyway and prints a warning naming the port
and saying that forward will not answer. A box's own Lima process holding its own
forward is not a conflict. Where no probing tool exists at all the refusal
degrades to a note and the box is created: a missing local tool must not block a
box.

**`agentbox ports` is the diagnosis when a forward is quiet.**

```
./bin/agentbox ports ~/dev/app
./bin/agentbox ports ~/dev/app --json
```

```
PORT   FORWARDED  HOST 127.0.0.1                 GUEST                REACHES
3000   yes        bound by this box (pid 4711)   listening any        yes
8080   yes        free                           not listening        no — nothing in the box is listening
9000   yes        conflict: pid 8123 (node)      listening loopback   no — the host port is held by something else (pid 8123)
```

It reads both sides and says which one is at fault: `FORWARDED` is what this host
recorded at create time (or, for a box created before that record existed, what
Lima itself reports); `HOST` is what holds the port on the Mac now; `GUEST` is
what the box is listening on, in the vocabulary `loopback`, `any` or `other`. A
guest socket bound to `other` — the guest's own interface address — is a real
listener that a forward cannot reach, and that is the trap the table exists to
name. A box with no forwards at all gets `"ports": []` from `--json` and a
refusal in text, because a person asking this about such a box has misremembered
what the box is.

**Which bind addresses a forwarded port reaches.** Both of the forms you would
normally write work — `ports: ["3000:3000"]`, which publishes on `0.0.0.0`, and
`ports: ["127.0.0.1:3000:3000"]`. The one that does not is publishing to the
guest's own interface address, `ports: ["192.168.5.15:3000:3000"]`; that socket
answers inside the guest and nowhere else, and nothing reports why. `agentbox
create` prints this beside the widening warning.

**A port you did not forward is not reachable, even published on `0.0.0.0`.**
That is enforced rather than assumed: `AGENTBOX-FWD` drops new connections
arriving on the uplink, so a container published the default way is reachable
from inside the guest and from nowhere else. The smoke test asserts both halves.

**What containers can and cannot reach.** The same allowlist as the guest, and
that is enforced rather than assumed: `AGENTBOX-FWD` is jumped to from
`DOCKER-USER` rule 1, before any of Docker's own rules. So:

| From a container | Result |
|---|---|
| another container on the same user-defined network | works, by service name |
| a published port, from the guest or the host | works |
| an allowlisted host — the model API, GitHub, npm, PyPI | works |
| Docker Hub, ghcr.io, `download.docker.com` | works; that is how images are pulled |
| anything else | rejected immediately, the same as from the guest |

`agentbox firewall-check <repo>` rebuilds the allowlist and then checks it,
including from inside a container: that one cannot reach `example.com` and can
reach `api.anthropic.com`. The rebuild is a restart of the firewall unit rather
than a direct run of the script, which serialises it against the 15-minute timer
and clears the unit if it had failed — so the command also unblocks
`agentbox run`, which refuses to start on a box whose firewall unit is not
active. If the rebuild fails you still get the full table, for the ruleset that
is still in force, with a line saying the rebuild did not work.

Three things make the container lines honest to read.

They are **advisory in one direction only**. A container that could not reach
`api.anthropic.com`, or one that could not be tested at all, prints `WARN`: an
absence is what an outage, a rate limit or a rotated CDN address produces, and
none of those is a reason to declare the box unsafe. A container that *reached*
`example.com` prints `FAIL` and fails the command, because nothing outside this
box can fabricate that — it means container egress is not being filtered.

The same rule decides the guest's own checks. `anthropic-allowed` and
`github-allowed` are advisory; `egress-denied`, `literal-ip-denied` and
`foreign-dns-denied` are fatal, because the only way they fail is by something
answering that should have been refused.

They are **skipped, out loud, rather than silently**: `SKIP` with the reason on
an instance without Docker, on one whose daemon is not up yet, and on one where
`alpine:3` is not present locally. The check deliberately does not pull it —
see the next paragraph.

And **nothing here pulls an image**. `docker system prune -af --volumes` below
will delete `alpine:3`, and a firewall that re-pulled it every fifteen minutes
because you tidied your disk would be a bad trade. `docker pull alpine:3`
once and the probes resume; building or running other images does not count,
because the probe looks for that one tag.

**Rosetta, for amd64 images.** `--rosetta` at create time, and then
`docker run --platform linux/amd64 …` works on Apple silicon. It needs Rosetta
2 installed on the Mac; if Lima sits at "Installing rosetta" for more than a
minute, run `softwareupdate --install-rosetta` on the host and try again.
Translated containers are slower than native ones — reach for it when an image
has no arm64 build, not by default.

**Disk hygiene.** `--docker` raises the default disk to 60GiB, and images,
layers and the build cache all live on it. A long-running instance fills up:

```
docker system df                 # what is using it
docker system prune -f           # stopped containers, unused networks, dangling images
docker system prune -af --volumes  # everything not currently in use. Blunt.
```

If that is not enough, grow the disk rather than rebuilding the VM:

```
./bin/agentbox resize ~/dev/my-app --disk 100GiB
```

It stops the VM if it is running and starts it again afterwards. The disk can
only grow; `--cpus` and `--memory` go either way.

## Browser and API tests

On every box. Node, the Playwright CLI and the system libraries the browsers link
against are part of the baseline, and so is one browser.

**Chromium is already there.** It is installed once, under
`$PLAYWRIGHT_BROWSERS_PATH` (`/opt/ms-playwright`), which is exported for every
run and every session — so a project's own Playwright finds a browser already
present and the first test run in a fresh VM downloads nothing. That reverses an
earlier decision, and the reason is that the cost it weighed (a few hundred
megabytes for a box that might never need a browser) was weighed against boxes
that in practice all needed one. The version the pins file names is the one that
is there; the shared directory is writable by the guest user, so the agent can add
Firefox or WebKit into the same place with `playwright install firefox`.

**A project that pins a different Playwright** still works: it installs its own
version in its own environment, and that version looks in
`$PLAYWRIGHT_BROWSERS_PATH` for a build. If it needs a build that is not there it
downloads it, from `cdn.playwright.dev`, which is on the allowlist —
`toolcheck --project-only` is what tells you the two versions differ before a test
run does.

**If a browser download is refused, retry it before you debug it.** The allowlist
holds addresses, not names, and `cdn.playwright.dev` is an Azure Front Door
endpoint that answers with a single address on a near-zero TTL. The firewall
resolves it through the system resolver as well as `dig` on every rebuild,
which is normally enough — but a download can still land on an address that was
not in the set at that moment and be rejected outright.
`agentbox firewall-check <repo>` forces a rebuild and refreshes the set, which
is the quickest fix; `PLAYWRIGHT_DOWNLOAD_HOST` pointed at a mirror you control
is the durable one. The full explanation is in `docs/decisions.md`.

Node:

```
cd /work
npm ci
npx playwright install chromium     # or `install` for all three engines
npx playwright test
```

Python:

```
python3 -m venv ~/.venvs/my-app     # NOT inside /work — see the friction list
. ~/.venvs/my-app/bin/activate
pip install pytest-playwright
playwright install chromium
pytest
```

**Headless only.** There is no display in the guest and none is wanted:
`--headed`, `--ui` and `npx playwright show-report` have nothing to draw on.
What you get instead is the artefacts, and they should be written under `/work`
so they cross to the host and can be opened there:

```
npx playwright test --trace on --output /work/test-results
```

Then, on the Mac: `npx playwright show-trace ~/dev/my-app/test-results/.../trace.zip`.
Screenshots, videos and traces all work this way; the report is HTML and opens
in a host browser.

**The app under test needs no allowlist entry.** It is running inside the same
guest — a container on a Docker network, or a process on `127.0.0.1` — and
neither path leaves the machine, so neither is filtered. What *does* need an
entry is anything the app itself calls out to: a staging API, an OAuth
provider, a payment sandbox, an S3 bucket, a CDN the page loads a font from. A
test that fails with a connection refused inside the guest while
`agentbox firewall-check` still passes is almost always one of those. Add the
name to `~/.config/agent-box/guest/allowlist.local`, one per line, and re-run
`agentbox firewall-check` — the rebuild picks it up.

## Which checkout a box is running

`/opt/agent-box` inside every guest **is** this checkout, mounted read-only, and
provisioning re-runs at every start. So "which version is this box on" is a
question about the host's working tree and nothing else:

```
./bin/agentbox version
```

It prints the checkout's short commit, its date, and whether the tree is clean or
dirty. The consequence worth internalising: the moment `~/dev/agent-box` moves,
every existing box runs the new provisioner at its next start. That is why the
toolchain installer is fail-soft and why the channel hooks are inert unless a
session is the tracked standing one — an upgrade must not brick a box that holds
real work.

## Keeping the CLI current

Background self-update is off in the guest (`DISABLE_AUTOUPDATER=1`), so a run
cannot have its binary replaced underneath it. Update deliberately:

```
./bin/agentbox update ~/dev/my-e2e-tests
```

It prints the version before and after. Updates come from
`downloads.claude.ai`, which is on the base allowlist.

## The supervisor, in here

If you use the supervisor plugin, the guest is a good place for its ledger:
the spend it prices is the same subscription any other device draws on. Its
configuration comes from `claude/supervisor.json` through the carry-over
above (the pre-2.0 name `governor.json` still crosses and is still read). Its
state lives in the guest and **dies with the VM**, so a destroyed box takes its
own accounting with it. Which `mode` to set, and why `enforce` slows a `sonnet`
run down, is in the README under "The supervisor plugin, in the box".

## The friction, listed rather than debugged

None of these is broken. They are the shape of the thing.

- **One VM per repository.** Lima fixes mounts at create time, which is what
  makes "can it see X" answerable once instead of continuously. A second
  repository means a second `agentbox create`, and a second few minutes.
- **A virtualenv or `node_modules` built inside the guest overwrites the
  host's.** The mechanism has not changed: `/work` is a shared mount, not a
  clone, so an environment the agent creates there lands at the same path the
  host uses, but built for the guest's Linux rather than the host's macOS — a
  host `.venv/bin/pytest` can come back reporting `bad interpreter:
  /work/.venv/bin/python3` afterward, because the binaries underneath it are no
  longer the ones the host put there. What changed is the answer for the host's
  half: build in the **bench** (`agentbox bench <repo>`), which is a clone
  outside the mount, and leave `/work` to the box. The box is deliberately still
  told to build where its CI builds, because a box whose environment sits
  somewhere CI does not is a less faithful box, not a safer one.
- **What a test talks to needs an allowlist entry; the app itself does not.**
  An app running inside the guest — a container, or a process on `127.0.0.1` —
  is reachable with no rule at all, because that traffic never leaves the
  machine. A staging API, an OAuth provider, an internal package mirror or a
  font CDN the page loads does need one. They go in `guest/allowlist.local`,
  one name per line. The symptom of a missing one is a connection refused
  inside the guest while `agentbox firewall-check` still passes.
- **A first boot that cannot reach GitHub installs no plugins.** A host simply
  off the allowlist fails fast, because the ruleset ends in REJECT. The slow
  cases are the other ones: GitHub accepting a connection and then not
  answering, or the hard-closed state a failed firewall init leaves behind.
  Every plugin CLI call is bounded at 120 seconds, so the boot finishes either
  way; `install-plugins` then exits 5 saying the marketplace was unreachable,
  and `agentbox firewall-check` is the next thing to run. The VM is fine, it
  just has no plugins yet.
- **Nothing pushes from the guest.** There is no git credential in there, and
  that is deliberate: you review the branch on the host and push it under your
  own identity.
- **The quota is shared with every other device on the account.** The token
  draws on the same five-hour and weekly limits. A long unattended run in the
  VM is a run you cannot do elsewhere that evening. `agentbox run` defaults to
  `sonnet` for that reason.
- **The interactive session is not scrubbed.** `agentbox run` checks its output
  for token fragments; `agentbox claude` hands you the terminal and cannot.
- **First boot is slow, later boots are not.** The Ubuntu image is cached under
  `~/Library/Caches/lima/download` and shared across instances.
- **The first start after the checkout moves is slower than the ones after it.**
  Provisioning runs at every start and the toolchain install is idempotent, so
  the first start against a new version installs what changed and every later one
  says `All toolchain pins already satisfied` and does nothing. Measured on one
  Mac on 2026-09-20: 1m25s for that first start of an existing box, 19s for the
  next.
- **An idle standing session does not notice a request until somebody prompts
  it.** There is no wake. The message is queued, `request` says so as it queues
  it, and `agentbox channel <repo>` shows the session as `idle` so the reason is
  visible. Type anything in the session and it arrives.
- **A standing session's leftovers are never cleaned.** A run sweeps its own; a
  session's are deliberately left alone, because the session is your hands. They
  show up in `leftovers` and in `status`, and you are the only cleaner.
