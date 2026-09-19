# Daily use

`docs/first-run.md` gets the box built once. This is what using it looks like
afterwards: the two ways to drive it, what of your own setup comes with you,
what deliberately does not, and the friction you should expect rather than
debug.

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
agent-box-my-e2e-tests         running   fw=deny  claude=2.1.261  runs=4  tmux=2
                                         run 20260905-120001 running 38s turns=3
                                         cost=$0.0412  last: Edit tests/test_orders.py
```

`firewall` is read from the live `iptables` OUTPUT policy, not from whether a
systemd unit is enabled: `drop`, `open`, or `unknown` when it could not be
read at all. A stopped box costs nothing to display, and a running one costs
exactly one `limactl shell` per refresh.

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
brief before the CLI sees it. It tells the agent three things: when it needs a
decision only the operator can make, write the question to
`/work/.agent-box/ask.md` and end the turn; when it had to fix something about
the environment, or found a defect in the brief or in this box, append an
entry to `/work/.agent-box/learnings.md`; and never touch the firewall, the
token or the allowlist. Read the file; it is short and it is the contract.

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
            "sessions": [{"name": "claude", "age_s": 900, "last_event": null}]}]}
```

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
~/.agent-box/sessions/<name>/hooks.jsonl   the same for an interactive session
```

The only thing that crosses to the host's disk is `<repo>/.agent-box/last-run.txt`,
and it is checked for token fragments before the run reports success.

## Host configuration layout

Everything site-specific lives here and nothing of it is ever committed:

```
~/.config/agent-box/
  blocklist.txt              read on the host only, NEVER mounted
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
it finds it inside `guest/`.

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

Only on an instance created with `--playwright`, which installs Node 22 and the
system libraries the browsers link against — the `libnss3`, `libatk`, font and
graphics packages that `npx playwright install-deps` pulls in.

**Browsers are not baked into the image.** Each repository's own Playwright
version downloads the builds it was pinned against, on first use, from
`cdn.playwright.dev`, which is on the allowlist. So the first test run in a
fresh VM spends a minute or two downloading Chromium and then never does it
again. That is deliberate: baking in one set would be the wrong set for most
repositories and would double every instance's disk footprint.

**If that download is refused, retry it before you debug it.** The allowlist
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
  host's.** `/work` is a shared mount, not a clone, so an environment the
  agent creates there lands at the same path the host uses, but built for the
  guest's Linux rather than the host's macOS — a host `.venv/bin/pytest` can
  come back reporting `bad interpreter: /work/.venv/bin/python3` afterward,
  because the binaries underneath it are no longer the ones the host put
  there. Keep environment directories out of the shared tree, or give each
  side a distinct name (`.venv-host` on the host, say), and expect to
  recreate the host's environment after a run that touched it.
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
