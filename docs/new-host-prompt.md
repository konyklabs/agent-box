# A prompt to hand an agent on a new host

Paste this into a Claude Code session on the new machine, in an empty
directory, after replacing the two bracketed values. It drives
[new-host.md](new-host.md) and stops at the steps only a person can do.

---

You are setting up agent-box on this Mac so that an unattended coding agent can
run inside a VM against one repository. The procedure is in a runbook you will
clone; follow it phase by phase, and do not begin a phase until the previous
phase's check has passed and you have shown me its output.

Start:

```
brew install lima gitleaks uv
git clone https://github.com/konyklabs/agent-box ~/dev/agent-box
ln -sf ~/dev/agent-box/bin/agentbox ~/.local/bin/agentbox
```

Then read `~/dev/agent-box/docs/new-host.md` top to bottom before running
anything else. It is the authority; where anything I say here disagrees with
it, tell me and follow the runbook.

Facts for this host:

- The repository the box will mount: `[path or clone URL of the repo]`.
- What its tests need: `[e.g. Docker compose stack with a database and a mock
  worker, Playwright browser tests, a live identity provider in one mode and a
  local mock in the other]`.
- Egress for the first box: `observe`. We will turn the log into an allowlist
  and switch to `deny` after the first green run.

Rules that override everything else:

1. Never print, cat, grep or quote `~/.config/agent-box/blocklist.txt`. Check
   that it exists and its mode, nothing more. I fill it in; you may empty it
   only if I say so.
2. Never copy anything from `~/.config/agent-box/` into a repository, an
   issue, a pull request, or a message to me. Internal hostnames, ranges and
   names live only in that directory.
3. Three steps are mine: written permission, `agentbox token`, and typing the
   site values into the blocklist and the allowlist. When you reach one, stop,
   tell me the exact command or edit, and wait. Do not paste a long command;
   keep each one under 100 characters or put it in a script I run.
4. The application's own credentials go into the guest at `~/app.env`, quoted
   for `sh`, never into the mounted tree. Preflight refusing a `.env` in the
   repository is correct behaviour, not a bug to route around.
5. Stop at any `FAIL`, at any permission denial, and at the second recurrence
   of the same failure. Do not work around a refusal. Record where you stopped
   and what you saw.
6. Every claim comes with the command and its output. Never "it works".

Install the window onto the boxes as well, in phase 3, and use it:

```
uv tool install git+https://github.com/konyklabs/porthole
porthole
```

porthole is a terminal window that lists every box with its egress mode, the
run each one is on, and streams that run's log. It only calls the `agentbox`
CLI and reads its `--json` output. In it: `j`/`k` or arrows pick a box, the
right pane follows its newest run, `enter` lists the box's runs, `s` stops the
selected run after a confirmation, `a` attaches a terminal to its session,
`r` refreshes, `l` toggles log follow, `?` is help, `q` quits. When I am not at the machine I will use the CLI
instead, so also tell me these when the first run is going:

```
agentbox status                                  # one line per box
agentbox runs ~/dev/<repo>                       # this box's runs, newest first
agentbox logs ~/dev/<repo> -f                    # follow the newest run
agentbox stop-run ~/dev/<repo>                   # interrupt it; nothing is reverted
agentbox ask ~/dev/<repo>                        # the question a waiting run left
agentbox resume ~/dev/<repo> --answer "..."      # answer it and continue
agentbox learnings ~/dev/<repo>                  # what the runs wrote down
agentbox egress-log ~/dev/<repo> --since 24h     # what an observe box reached
```

After the first green run, turn the observe log into the allowlist and switch
the box to deny:

```
agentbox egress-log ~/dev/<repo> --since 24h --as-allowlist
# show me that output; I decide what goes into ~/.config/agent-box/guest/allowlist.local
agentbox egress ~/dev/<repo> deny
agentbox firewall-check ~/dev/<repo>
```

When the box is up, the token is in, verify-auth passes and the firewall check
passes, write the first brief from `templates/brief.md`: not the real task yet,
but "make the repository's test tiers runnable from one command each and paste
their output", with a stop condition for anything that needs a credential or a
host we have not allowed. Start it with `--heal 2` and a `--heal-delay` longer
than any cooldown the live tier has. Then show me `agentbox runs`, and if the
state is `waiting`, show me `agentbox ask` and stop.

At the end, write a local note at `~/dev/agent-box/.local/host-setup.md`
(gitignored) with: what each precondition returned, which phases needed me,
the box name and flags, whether a proxy certificate was needed, and the exact
output of verify-auth and firewall-check. Nothing from `~/.config/agent-box/`
goes in it.
