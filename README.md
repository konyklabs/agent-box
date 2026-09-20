# agent-box

A safe box for an unattended coding agent.

For anyone who wants to let an agent run unattended without handing it their
laptop.

The guarantee: the agent gets exactly one mounted repository and its own
subscription token, deny-by-default outbound network, no reach into the rest
of the host, no ability to push, and a scrubbed one-line summary as the only
thing that comes back.

## How it works

agent-box is a disposable Linux VM (Lima, on Apple's own virtualization
framework) with Claude Code installed inside it. `bin/agentbox` fixes its
mounts at creation time — the repository at `/work`, this checkout read-only,
and an optional host config directory — so "can the agent see X" is decided
once and cannot drift while the VM is running. The isolation cuts both ways:
the agent must not reach anything on the host beyond that one repository — not
other projects, not SSH keys, not browser profiles — and the subscription
token must not reach anything the agent writes. The agent runs with
`--dangerously-skip-permissions` and can write anywhere under `/work`, so its
transcript stays sealed inside the VM and only a scrubbed summary, checked for
fragments of the token, ever crosses to the host's disk. An egress allowlist
sits in the middle: the agent can reach the model, GitHub, npm and PyPI, and
nothing else, so a repository's contents cannot be posted somewhere by
accident.

How rigid that middle is, you choose per box and at creation time, with
`--egress`:

- **`deny`** refuses anything not on the allowlist. The default in spirit, and
  the one to use unless you know otherwise.
- **`observe`** allows it and writes it down. Point a box at an unfamiliar
  repository for a week, then turn the log into an allowlist with
  `agentbox egress-log --as-allowlist`.
- **`open`** turns the packet filter off. Everything else — the VM boundary,
  the single mount, the token handling, the no-push rule — is unchanged.

There is no default: `create` refuses without `--egress` and prints the three
options, because a box's reach is the one thing nobody should end up with by
accident. Put `egress: deny` in `~/.config/agent-box/config` to make the choice
once, and create will say which mode it took and where it got it.

The allowlist takes address ranges (`10.0.0.0/8`) and domain suffixes
(`.staging.example`) as well as exact names, so naming a staging environment
does not mean listing every host in it. A local resolver adds each address to
the allowed set as the guest resolves it, which is what makes a suffix possible
and also what stops a rotating CDN breaking a download.

## Before you point it at code you do not own

Get permission first, in writing, from whoever owns the repository and the
data in it. This tool enforces the technical boundary — one repository, one
token, no host access, no push — but it cannot get you permission to run an
agent against someone else's code, and nothing below substitutes for asking.
What to ask for, and a template, are in
**[docs/first-run.md](docs/first-run.md)**.

Tell them the egress mode too. "It can only reach these hosts" and "it can
reach anything and I am keeping a log" are different undertakings, and the
person granting permission is entitled to know which one they are agreeing to.

## Quick start

```
brew install lima gitleaks
git clone <this repo> ~/dev/agent-box
cd ~/dev/agent-box
./bin/agentbox create ~/dev/my-e2e-tests --egress deny
./bin/agentbox token  ~/dev/my-e2e-tests        # paste a token from `claude setup-token`
./bin/agentbox verify-auth ~/dev/my-e2e-tests   # the only real proof it works
./bin/agentbox toolcheck   ~/dev/my-e2e-tests   # every baseline tool at its pin
```

`create` takes a few minutes the first time, mostly downloading the Ubuntu
image, and ends by checking the toolchain by name — so a box that is not at
baseline says which tool and exits non-zero rather than reporting itself ready.
Full walkthrough, including what each step actually checks:
**[docs/first-run.md](docs/first-run.md)**. Setting up a second machine, with
the human-only steps marked so an agent can drive the rest:
**[docs/new-host.md](docs/new-host.md)**.

## Commands

One instance per repository, named `agent-box-<repo basename>`.

| Command | What it does |
|---|---|
| `agentbox preflight <repo>` | Scan a repo for secrets and configured terms. Exit 1 on findings. |
| `agentbox create <repo> [options]` | Preflight, then create and start that repo's VM. Options below. |
| `agentbox resize <repo\|name> [--cpus N] [--memory SIZE] [--disk SIZE]` | Resize an existing VM. Stops it if running, then starts it again. The disk can only grow. |
| `agentbox start <repo>` | Preflight, then start an existing VM. |
| `agentbox token <repo>` | Read an OAuth token from the terminal into the VM. Never echoed, never stored on the host. |
| `agentbox verify-auth <repo>` | Prove the token authenticates, with one real model call. |
| `agentbox claude <repo> [args]` | Interactive Claude Code in the VM, in `/work`. Arguments pass through to the CLI. |
| `agentbox session <repo> [brief.md]` | The same, in a tmux session you can detach from and come back to. |
| `agentbox shell <repo>` | Interactive shell in the VM, in `/work`, in a tmux session. |
| `agentbox attach <repo> [session\|runid] [-r]` | Attach to a session. A run's session is read-only. |
| `agentbox sessions <repo> [--json]` | List the VM's tmux sessions, with age and last activity. |
| `agentbox run <repo> <brief.md> [options]` | Start one headless task from a brief and return at once. Default model `sonnet`. |
| `agentbox runs <repo> [--json]` | List this VM's runs, newest first, with state, turns and cost. |
| `agentbox resume <repo> [runid] --answer TEXT \| --answer-file F` | Answer a `waiting` run's question and continue its brief in a new run. |
| `agentbox ask <repo> [runid]` | Print the question a `waiting` run left. |
| `agentbox learnings <repo>` | Print what the runs wrote down about what they had to fix and what should change. |
| `agentbox channel <repo> [--json] [--task TEXT\|--clear-task] [--wait SECS]` | Both sides of the box's mailbox: what its session sent, what is queued for it. `--wait` blocks until something is unread. |
| `agentbox handoff <repo> [id] [--json] [--peek] [--done] [--force-unsafe]` | Read one message from the box, scrubbed in the guest, with this host's own check of the branch and commit it claims. |
| `agentbox request <repo> [--re ID] [--verdict accepted\|changes] [--subject S] --text T \| --file F\|-` | Queue a request for the box's standing session. Works while the box is stopped. |
| `agentbox keepalive <repo> on\|off\|status` | Mark a box for the watchdog: restart it when stopped, heal its newest run when lost. |
| `agentbox watchdog --install\|--uninstall\|--run` | The launchd job (every 5 minutes) behind `keepalive`. |
| `agentbox logs <repo> [runid] [-f] [--json]` | Read a run back, formatted and scrubbed inside the guest. |
| `agentbox stop-run <repo> [runid]` | Interrupt the newest running task, or a named one. Nothing is reverted. |
| `agentbox leftovers <repo> [--json]` | What earlier runs left running in the box, and which run left it. Reports; never cleans. |
| `agentbox plugins <repo> [--update]` | Apply `plugins.txt` inside the VM. |
| `agentbox update <repo>` | Update Claude Code inside the VM, printing the version before and after. |
| `agentbox stop <repo\|name>` | Stop the VM. |
| `agentbox destroy <repo\|name>` | Stop and delete the VM, and remind you to revoke the token. |
| `agentbox bench <repo\|name> [--branch B] [--json] \| --list [--json] \| <repo\|name> --remove [--force]` | A host-side clone for rebuilding and checking the box's branch, outside the mount. |
| `agentbox status [repo] [--json] [--watch [SECS]]` | One line per box: current run, sessions, firewall, standing session, channel counts, toolchain, leftovers. |
| `agentbox triage [repo\|name] [--json]` | Across the fleet: keep, pause, remove or ask — and what is only inside each box. |
| `agentbox egress <repo\|name> [MODE]` | Show, or change, the egress mode: `deny`, `observe` or `open`. A change rebuilds the firewall and prints the verification. |
| `agentbox egress-log <repo\|name> [--since DUR] [--json] [--as-allowlist]` | What an `observe` box tried to reach, with the names it resolved. `--as-allowlist` emits lines to paste into `allowlist.local`. |
| `agentbox firewall-check <repo\|name>` | Rebuild the egress allowlist and re-verify it, inside the VM. The container probes are advisory. |
| `agentbox ports <repo\|name> [--json]` | Which forwarded ports actually reach the guest, and which side of a quiet forward is at fault. |
| `agentbox toolcheck <repo\|name> [--json] [--project-only]` | Every baseline tool at its pin, and where this repository pins one differently. |
| `agentbox version` | The checkout this CLI — and every box's guest scripts — comes from. |
| `agentbox help` | The whole surface, with the options for each command. |

`run` takes `--model M`, `--max-turns N`, `--max-budget-usd X`, `--wait`,
`--notify`, `--heal N [--heal-delay SECS]` and `--review M`. Heal: when the
run fails, the box itself starts up to N follow-up runs, each told what failed
and to repair the environment before continuing the same brief. Review: when
the run ends `done` with commits, the box starts a second run on model M (which
must differ from the run's own) that reads the diff against the brief, re-runs
the tests, fixes real defects in their own commits and writes
`.agent-box/review.md`. Standing defaults for `model`, `max_budget_usd`,
`heal` and `review` go in `~/.config/agent-box/config`, one `key: value` per
line, so a run typed with no flags is still capped and reviewed. How the heal
loop, the `waiting` state, the review and the learnings file fit together is
in [docs/daily-use.md](docs/daily-use.md) under "Self-healing" and "Review on
a second model". `resize`, `stop`, `destroy` and `firewall-check` also take a bare
instance name, so a VM can still be shut down, resized and deleted after its
repository directory is gone. Every subcommand stops reading options at a
literal `--`, so a caller that builds a command line rather than typing it can
always say where its operands begin: `agentbox runs --json -- <repo>`. For
`agentbox claude` the `--` may only come before the repository, because
everything after it belongs to the CLI.

Runs are detached: `agentbox run` returns as soon as the task has started, and
`runs`, `logs -f`, `stop-run` and `status --watch` are how you follow it. The
whole loop is in [docs/daily-use.md](docs/daily-use.md) under "Watching and
steering".

`channel`, `handoff` and `request` are the other loop: a standing interactive
session inside the box hands finished work out with `abx handoff`, and you send
it work with `agentbox request`. **A request reaches an idle session at its next
prompt** — late, never lost; there is no mechanism in this version that wakes an
idle session, and `agentbox channel <repo> --wait SECS` is the waiting half on
the host's side. `host/claude-plugin/` is a Claude Code plugin that reminds a
host session about an open message, and **enabling it is your own configuration
change** (`claude --plugin-dir ~/dev/agent-box/host/claude-plugin`): the channel
works without it, because the three commands are the pull path. The whole shape
is in [docs/daily-use.md](docs/daily-use.md) under "Two sessions, one mount".

`toolcheck` is the readiness check: exit 0 when every baseline tool is at its
pin, 10 when one is missing or off it, 11 when the box is clean and this
repository pins a tool differently, 1 for a usage error or a sweep that could
not read the box's pins. `create` ends with the same check and exits with its
status, so a new box that is not at baseline names the tool rather than
reporting itself ready; `start` of an existing box prints the same lines as a
warning and exits 0.

### create options

All optional, all off by default, and all fixed for the life of the instance
except the sizing. The same reasoning as the mounts: what a VM can do is
decided when it is made, not adjusted while it runs.

| Option | What it adds |
|---|---|
| `--docker` | Docker Engine, buildx and compose inside the guest. Containers are held to the same egress allowlist as the guest itself. |
| `--playwright` | **Deprecated and ignored.** Node, Playwright and Chromium are part of the baseline every box carries — see below. The flag still parses, because a create-time parameter is frozen for the life of an instance and an existing box passes it for ever. |
| `--rosetta` | Run `linux/amd64` images on Apple silicon. Needs Rosetta 2 on the Mac; `softwareupdate --install-rosetta` if Lima stalls at "Installing rosetta". |
| `--egress deny\|observe\|open` | **Required.** How rigid the network is. No default: create refuses without it, unless `egress: <mode>` is in `~/.config/agent-box/config`. |
| `--forward PORT[,PORT...]` | Forward guest `127.0.0.1:PORT` to host `127.0.0.1:PORT`. Reaches a guest socket bound to `127.0.0.1` or `0.0.0.0`, not one bound only to the guest's own address. `create` refuses a host port something else already holds, and `start` refuses too, because a forward cannot be moved afterwards; `agentbox ports` says which side of a quiet forward is at fault. A widening — see Limits below. |
| `--cpus N` | Default 4. |
| `--memory SIZE` | Default `6GiB`, or `8GiB` with `--docker`. |
| `--disk SIZE` | Default `40GiB`, or `60GiB` with `--docker`. |

`--docker` raises the memory and disk defaults because images, layers and a
build cache all land on the guest disk and a compose stack plus a browser is a
different memory profile from a shell and an editor. An explicit `--memory` or
`--disk` overrides that. The effective sizing is printed at create time and
again in the summary.

```
./bin/agentbox create ~/dev/my-app --egress deny --docker --forward 3000,8080
```

## Every box carries

There is no toolchain flag. Every box installs the same set at every start,
idempotently, from `guest/toolchain.pins` — one version and one per-architecture
sha256 per tool, the only writer of which is `host/refresh-pins.sh`:

| | |
|---|---|
| `uv`, `uvx` | Python environments and tools |
| `ruff` | Python lint and format |
| `node`, `npm`, `npx` | at `/opt/node`, on `PATH` |
| `mise` | the task runner a repository's CI is likely to invoke |
| `trufflehog` | secret scanning the box can run on itself |
| `actionlint` | workflow lint, so the agent can read what CI actually runs |
| `dprint` | formatting |
| `basedpyright` | Python types |
| `semgrep` | its own rules only; the rule registry is not reachable under `deny` |
| `playwright` + Chromium | shared at `/opt/ms-playwright`, so a project's own Playwright finds a browser already there and downloads nothing |

The installer is deliberately **fail-soft**: nothing in it may fail a boot, a
tool that fails is a warning and is retried at the next start, and under 4 GiB
free it skips itself and tells you to resize. `agentbox toolcheck` is the
by-name report, and `agentbox start` prints its findings as a warning.

Measured on one Mac (an M-series laptop, cached Ubuntu image, 2026-09-20 — your
machine will differ): create from scratch 50s, the first start of an existing
30GiB box against the new checkout 1m25s, a start with nothing to do 19s, and
about 2.6 GiB of guest disk for the whole toolchain. That is why new boxes
default to 40GiB; an existing 30GiB box keeps its size and has room, and
`agentbox resize <repo> --disk 40GiB` grows it if you want the headroom.

Claude Code itself is the one tool that is **not** pinned: `CLAUDE_CODE_VERSION`
is written as `latest` in the pins file, as an explicit statement rather than an
omission, because the CLI's currency is a feature. Background self-update is off
in the guest, so it never moves on its own; `agentbox update` moves it
deliberately.

## Layout

```
bin/agentbox            the host CLI; the only thing you run directly
lima/agent-box.yaml     the VM: three mounts (two read-only), no home directory
guest/provision.sh      first-boot setup, as root
guest/init-firewall.sh  the egress allowlist, as root, on a 15-minute timer
guest/allowlist.base    generic allowed domains, one per line
guest/lib.sh            the preconditions and token handling the next three share
guest/agent-run.sh      one headless task, as the non-root guest user
guest/claude-session.sh one interactive session, as the non-root guest user
guest/verify-auth.sh    one small model call, to prove the token works
guest/run-ctl.sh        start, stop, heal, resume and list the guest's runs
guest/run-ledger.sh     what a run started, and the sweep that closes it again
guest/conventions.md    prepended to every brief: ask, write learnings, hands off the rails,
                        run the project's own command, hand work out with abx handoff
guest/heal-brief.md     the follow-up brief a failed run starts itself with
guest/review-brief.md   the brief a finished run hands to its reviewer on a second model
guest/resume-brief.md   the follow-up brief `agentbox resume` builds from the answer
guest/hook-event.sh     the hook command; one JSON line per hook event
guest/hooks.settings.json    the hooks block, merged in with --settings
guest/run-format.py     merge the sensors and print them, scrubbed, in the guest
guest/box-status.sh     one JSON or text line describing this box
guest/box-listeners.sh  which of the asked-for ports the box is actually listening on
guest/box-triage.sh     the guest half of `triage`: one facts object, nothing else
guest/channel.sh        the box's side of the mailbox, and the delivery hook
guest/bin/abx           what the agent types in the box: handoff, ask, note, inbox, read, done
guest/bin/toolcheck     `toolcheck` on the agent's PATH inside the box
guest/toolcheck.sh      every baseline tool at its pin; the project's pins beside them
guest/project-pins.py   what this repository pins, read from its own files, never executed
guest/toolchain.pins    one version and two sha256 digests per tool; the only pin file
guest/toolchain/*.requirements.txt  hash-pinned, universal, compiled by refresh-pins.sh
guest/install-toolchain.sh   the baseline install: root, idempotent, fail-soft
guest/sync-claude-config.sh  carry named config files in; mark /work trusted
guest/install-plugins.sh     apply plugins.txt inside the guest
host/preflight.sh       repository scan; reports paths only, never contents
host/refresh-pins.sh    the only writer of toolchain.pins; hashes each asset itself
host/claude-plugin/     a Claude Code plugin for a HOST session: channel hooks and a skill
templates/brief.md      the task brief to copy and fill in
test/smoke.sh           builds a real VM, checks it, destroys it
test/no-vm.sh           the regression checks that need no VM; seconds to run
test/fake-limactl       a stand-in limactl, so the host half can be tested with no VM
docs/first-run.md       permission, token, daily loop, decommissioning
docs/new-host.md        bringing a second machine up, phase by phase, agent-drivable
docs/new-host-prompt.md the prompt to hand an agent on that machine
docs/preparing-a-repo.md  what to do to a repository, especially a monorepo, before its first create
docs/daily-use.md       the two modes, the channel, config carry-over, plugins, the friction
docs/decisions.md       why it is built this way, and what was rejected
```

Anything specific to where you work lives in `~/.config/agent-box/`, never in
this repository. It is split in two on purpose:

```
~/.config/agent-box/
  config                     standing defaults: egress, model, max_budget_usd, heal, review
  blocklist.txt              read on the host only, NEVER mounted
  watchdog.log               what the launchd job did, if you use keepalive
  watchers/                  one pid file per `run --notify` watcher
  instances/<instance>       this host's record of a box: egress, repo, keepalive,
                             forward, bench, bench_branch, boxonly, boxonly_bytes, boxonly_at
  channel/<instance>/        this host's own channel record: read, done, sent, host, gc.stamp
  bench/<instance>/          a host-side clone of the box's repository (see daily-use)
  guest/                     mounted read-only at /opt/agent-box-config
    allowlist.local          extra egress domains, one per line
    ca.pem                   TLS-intercepting proxy root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  CLAUDE.md, settings.json, supervisor.json, rules/
```

- `~/.config/agent-box/guest/` is mounted read-only into the VM at
  `/opt/agent-box-config`. **Everything above it is not mounted at all** — the
  instance records, the channel record and the bench are this host's own memory,
  and the box is never given a path to any of them.
- `~/.config/agent-box/blocklist.txt` is a local term blocklist: names,
  hostnames or codenames you never want to leave this machine. It is read on
  the host only and is **never** mounted, because it is the one file whose
  contents an agent must not see.
- `channel/<instance>/` is why a box cannot rewrite its own read receipts: the
  copies on the mount are a courtesy for the box's own display, and this
  directory is what the host believes. `AGENT_BOX_BENCH_DIR` moves the bench
  root elsewhere if you want it on another disk.

Both distinctions are deliberate: see [docs/decisions.md](docs/decisions.md).
What of `claude/` crosses into the guest, and what is refused, is in
[docs/daily-use.md](docs/daily-use.md).

## The supervisor plugin, in the box

Two budgets apply to a run, and they do different jobs. `agentbox run
--max-budget-usd X` is Claude Code's own cap: it stops the whole run, subagent
spend included. The supervisor plugin's budget gates only its expensive tier
(fable and mythos by default), so a `sonnet` run never reaches it; what the
plugin adds inside a box is the rest of its policy — workers pinned to a cheap
model, forks denied, report contracts enforced, and a spend ledger you can read
back.

Configure it with one file on the host, carried into the guest on every
`start`, `run`, `shell` and `claude`:

```
~/.config/agent-box/guest/claude/supervisor.json
```

```json
{
  "mode": "observe",
  "readout": "off",
  "budget_usd": 25.0,
  "budget_profiles": {"small": 5.0, "medium": 25.0, "large": 100.0},
  "worker_model": "sonnet"
}
```

`mode` is the setting to think about. The plugin's default, `off`, is dormant
until someone types `/supervisor:start`, and nobody types anything in a
headless run, so it must be `enforce` or `observe`. `enforce` applies the
delegation policy: the conductor hands work to subagents and reads their
evidence. That is right when the run model is expensive and wrong when it is
`sonnet` talking to a `sonnet` implementer: measured on the same brief and box,
9 turns in 40s at $0.15 with the plugin dormant against 2 turns plus subagents
in 3m38s at $0.37 under `enforce`. So: `observe` for a `sonnet` run (the ledger
and the readout, nothing denied or delegated), `enforce` only when the run is
on the expensive tier. `readout: "start"` injects the policy once rather than
a spend line every turn; `"off"` injects nothing. Every other key works as on the host; the box's project path, for a
`projects` map, is always `/work`. To check what the guest sees, from a shell
in the box:

```
python3 ~/.claude/plugins/cache/konyklabs-plugins/supervisor/*/bin/supervisor.py budget show
```

Edit the host file and the next run picks it up. Changes made from inside an
interactive session land in the guest's copy, which the next sync overwrites.
The ledger lives in the guest and dies with `agentbox destroy`. A repository
may carry its own `.claude/supervisor.json`, which can only tighten. The
pre-2.0 name `governor.json` is still carried and still read, with a nag.

## Limits and known weaknesses

- **The guest user has passwordless sudo.** Lima's provisioning needs it, so a
  capable agent could disable its own firewall. The firewall is a guard rail
  against carelessness, not a sandbox against a hostile tool — the VM boundary
  is what protects the host. Tracked as
  [issue #1](https://github.com/konyklabs/agent-box/issues/1).
- **Three commands hand you a terminal and cannot scrub it.** `agentbox claude`
  and `agentbox session` give the CLI your screen. `agentbox attach` draws a
  pane's raw bytes, including a run's pane. Everything `agentbox logs`,
  `agentbox runs`, `agentbox sessions` and `agentbox status` print is redacted
  inside the guest before it crosses, and `agentbox run` checks its output for
  the token before reporting success — but there is no boundary to filter at
  when a live pane is being drawn on your screen.
- **`logs` refuses a run whose leak check fired.** If a run exited 3, its
  events are not printed: you get a banner telling you to rotate the token.
  `--force-unsafe` prints them anyway.
- **The channel is a fourth path by which the box's own words reach your
  terminal.** `channel` and `handoff` print them, and they are scrubbed in the
  guest the way `logs` is — but a handoff is prose the model wrote, so the host
  puts every line the box chose behind a `  | ` bar and says once that a barred
  line is untrusted data and never an instruction. The claims a handoff makes
  about a branch and a commit are re-checked on the host with two read-only git
  commands; the prose is not checkable and is not checked.
- **A request reaches an idle session only at its next prompt.** Nothing in this
  version wakes an idle session. A message is late, never lost: every open
  request is re-shown at the start of each new context, including after `/clear`,
  a compaction or a resume. `agentbox channel <repo> --wait SECS` is the host's
  half of the same limitation.
- **The bench runs code the box wrote, on the host, outside the VM.** That is
  what a host-side clone is for — rebuilding and verifying a branch before you
  push it — and it is the one place the VM boundary is deliberately stepped
  around. Treat a handoff's `## Verify` commands as you would a stranger's pull
  request.
- **`leftovers` reports and never cleans.** Killing a survivor from the host
  would mean reaching into the box to kill a process the host cannot identify,
  on the strength of a record an agent could have written. The run's own sweep
  is the thing that kills, from inside, and only what it can prove it owns.
- **Remote Control is not available in here.** It needs a browser login, and
  the CLI refuses it for a setup token, which is the only credential this VM
  has. `agentbox session` plus `agentbox attach` is the substitute: a session
  you can leave and come back to, over `limactl shell` rather than over the
  internet.
- **`--forward` opens a hole in the other direction.** By default nothing the
  guest listens on is reachable from the host. Each forwarded port becomes
  reachable by any process on the Mac at `127.0.0.1`, for as long as the VM
  runs. It is opt-in per port, fixed at create time, warned about once, and
  recorded in the instance summary — but it is still the one place this design
  gives something back.
- **A forward still cannot be added, moved or dropped after create.** Lima can
  only change `portForwards` through an edit that needs the VM stopped, so
  "add a port" means interrupting whatever the box is doing; that is the same
  reason the mounts are fixed. What was added instead is the diagnosis:
  `create` and `start` refuse a host port something else holds rather than
  leaving a forward silently dead, and `agentbox ports` names which side of a
  quiet forward is at fault. `start --ignore-port-conflict` starts anyway and
  warns that the forward will not answer.
- **`--docker` puts the guest user in the `docker` group**, which is
  root-equivalent on that guest. It changes nothing about the threat model,
  because that user already has passwordless sudo, but it is worth knowing it
  is there.
- **Containers inherit the token.** The CLI is given its credential in its
  environment, so everything it spawns for the length of a run can read it,
  including `docker`. `docker compose` also interpolates it into a compose
  file that asks for `${CLAUDE_CODE_OAUTH_TOKEN}`, with no `-e` and nothing
  that looks unusual in the log. The VM boundary and the egress allowlist are
  what contain it; the token is meant to be revocable, not secret from the
  agent. See docs/decisions.md.
- **A macvlan or ipvlan network escapes the allowlist.** Container egress is
  filtered in `DOCKER-USER`, which only sees traffic that traverses `FORWARD` —
  true of bridge networks, not of macvlan or ipvlan, whose packets leave
  through a sub-interface of the NIC. `agentbox firewall-check` still passes,
  because it probes on a bridge. The firewall is a guard rail against
  carelessness; the VM is the boundary.
- **DNS resolves through the host's resolver.** The guest can resolve internal
  names it cannot connect to, and each lookup reaches the host's resolver with
  the VM as its origin. See "What the guest can still see: names" in
  [docs/decisions.md](docs/decisions.md).
- **MDM and corporate proxies are untested.** Some device-management profiles
  restrict the virtualization framework this depends on, and a
  TLS-intercepting proxy needs its root certificate supplied by hand. Neither
  has been verified against a real deployment. See "Known unknowns" in
  [docs/first-run.md](docs/first-run.md).

`test/smoke.sh` builds a real Lima instance from a throwaway repository,
checks the mounts, the firewall and the non-root user, and destroys it again.
`test/no-vm.sh` is the part that needs no VM and runs in seconds.
