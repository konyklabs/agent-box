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
```

`create` takes a few minutes the first time, mostly downloading the Ubuntu
image. Full walkthrough, including what each step actually checks:
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
| `agentbox keepalive <repo> on\|off\|status` | Mark a box for the watchdog: restart it when stopped, heal its newest run when lost. |
| `agentbox watchdog --install\|--uninstall\|--run` | The launchd job (every 5 minutes) behind `keepalive`. |
| `agentbox logs <repo> [runid] [-f] [--json]` | Read a run back, formatted and scrubbed inside the guest. |
| `agentbox stop-run <repo> [runid]` | Interrupt the newest running task, or a named one. Nothing is reverted. |
| `agentbox plugins <repo> [--update]` | Apply `plugins.txt` inside the VM. |
| `agentbox update <repo>` | Update Claude Code inside the VM, printing the version before and after. |
| `agentbox stop <repo\|name>` | Stop the VM. |
| `agentbox destroy <repo\|name>` | Stop and delete the VM, and remind you to revoke the token. |
| `agentbox status [repo] [--json] [--watch [SECS]]` | One line per box: current run, sessions, firewall. |
| `agentbox egress <repo\|name> [MODE]` | Show, or change, the egress mode: `deny`, `observe` or `open`. A change rebuilds the firewall and prints the verification. |
| `agentbox egress-log <repo\|name> [--since DUR] [--json] [--as-allowlist]` | What an `observe` box tried to reach, with the names it resolved. `--as-allowlist` emits lines to paste into `allowlist.local`. |
| `agentbox firewall-check <repo\|name>` | Rebuild the egress allowlist and re-verify it, inside the VM. The container probes are advisory. |

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

### create options

All optional, all off by default, and all fixed for the life of the instance
except the sizing. The same reasoning as the mounts: what a VM can do is
decided when it is made, not adjusted while it runs.

| Option | What it adds |
|---|---|
| `--docker` | Docker Engine, buildx and compose inside the guest. Containers are held to the same egress allowlist as the guest itself. |
| `--playwright` | Node 22 from nodejs.org, plus the system libraries `playwright install-deps` installs. Browsers are not baked in: each repository's own Playwright downloads the builds it was pinned against, on first use. |
| `--rosetta` | Run `linux/amd64` images on Apple silicon. Needs Rosetta 2 on the Mac; `softwareupdate --install-rosetta` if Lima stalls at "Installing rosetta". |
| `--egress deny\|observe\|open` | **Required.** How rigid the network is. No default: create refuses without it, unless `egress: <mode>` is in `~/.config/agent-box/config`. |
| `--forward PORT[,PORT...]` | Forward guest `127.0.0.1:PORT` to host `127.0.0.1:PORT`. Reaches a guest socket bound to `127.0.0.1` or `0.0.0.0`, not one bound only to the guest's own address. A widening — see Limits below. |
| `--cpus N` | Default 4. |
| `--memory SIZE` | Default `6GiB`, or `8GiB` with `--docker`. |
| `--disk SIZE` | Default `30GiB`, or `60GiB` with `--docker`. |

`--docker` raises the memory and disk defaults because images, layers and a
build cache all land on the guest disk and a compose stack plus a browser is a
different memory profile from a shell and an editor. An explicit `--memory` or
`--disk` overrides that. The effective sizing is printed at create time and
again in the summary.

```
./bin/agentbox create ~/dev/my-app --egress deny --docker --playwright --forward 3000,8080
```

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
guest/conventions.md    prepended to every brief: ask, write learnings, hands off the rails
guest/heal-brief.md     the follow-up brief a failed run starts itself with
guest/review-brief.md   the brief a finished run hands to its reviewer on a second model
guest/resume-brief.md   the follow-up brief `agentbox resume` builds from the answer
guest/hook-event.sh     the hook command; one JSON line per hook event
guest/hooks.settings.json    the hooks block, merged in with --settings
guest/run-format.py     merge the sensors and print them, scrubbed, in the guest
guest/box-status.sh     one JSON or text line describing this box
guest/sync-claude-config.sh  carry named config files in; mark /work trusted
guest/install-plugins.sh     apply plugins.txt inside the guest
host/preflight.sh       repository scan; reports paths only, never contents
templates/brief.md      the task brief to copy and fill in
test/smoke.sh           builds a real VM, checks it, destroys it
docs/first-run.md       permission, token, daily loop, decommissioning
docs/new-host.md        bringing a second machine up, phase by phase, agent-drivable
docs/new-host-prompt.md the prompt to hand an agent on that machine
docs/preparing-a-repo.md  what to do to a repository, especially a monorepo, before its first create
docs/daily-use.md       the two modes, config carry-over, plugins, the friction
docs/decisions.md       why it is built this way, and what was rejected
```

Anything specific to where you work lives in `~/.config/agent-box/`, never in
this repository. It is split in two on purpose:

```
~/.config/agent-box/
  blocklist.txt              read on the host only, NEVER mounted
  guest/                     mounted read-only at /opt/agent-box-config
    allowlist.local          extra egress domains, one per line
    ca.pem                   TLS-intercepting proxy root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  CLAUDE.md, settings.json, supervisor.json, rules/
```

- `~/.config/agent-box/guest/` is mounted read-only into the VM at
  `/opt/agent-box-config`.
- `~/.config/agent-box/blocklist.txt` is a local term blocklist: names,
  hostnames or codenames you never want to leave this machine. It is read on
  the host only and is **never** mounted, because it is the one file whose
  contents an agent must not see.

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
