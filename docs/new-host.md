# Bringing agent-box up on a new host

A runbook for a second machine, written so that a coding agent can drive it
and a person only steps in where a keyboard is genuinely required. It assumes
nothing is installed yet. Read it top to bottom once; then execute phase by
phase, and do not start a phase until the previous one's check has passed.

On the first host this was proven twice: three brief-driven runs on a plain
box, then one on a Docker and Playwright box that built a compose stack,
downloaded Chromium, ran a pytest suite and committed a fix, all under
`--egress deny`. A second host has different device management, proxies and
networks, which is why every phase below ends with a check rather than an
assumption.

---

## 0. Who does what

Three steps need a human. Everything else an agent can do from a shell.

| Step | Why a person |
|---|---|
| Written permission (phase 1) | Nobody else can give it. |
| `agentbox token` (phase 6) | It reads the token from a terminal, unechoed. A shell tool without a TTY cannot paste into it, and the token must not pass through a prompt, a file or a command line. |
| Filling `blocklist.txt` and `allowlist.local` (phase 4) | Their contents are exactly the site-specific names this repository must never carry. The agent creates the files and checks their shape; the person types the values. |

Rules for the agent driving this:

- Never print, `cat`, `grep` or quote `~/.config/agent-box/blocklist.txt`.
  Check that it exists and its mode; nothing more.
- Never copy anything from `~/.config/agent-box/` into a repository, an issue,
  a PR or a chat message. The one exception is `plugins.txt`, which names
  public marketplaces.
- Branch names, brief files, commit messages and status reports carry no
  internal hostnames, product names or codenames. If a value you need is one
  of those, ask the person to type it into the config file and refer to it as
  "the staging suffix" or "the VPN range".
- Stop at any `FAIL`, at any denied action, and at the second recurrence of the
  same failure. Record where you stopped. Do not work around a refusal.

## 1. Permission and account

**Human.** Get written permission from whoever owns the repository the box will
mount. The template is in [first-run.md](first-run.md), section 1. Tell them the
egress mode you intend to use; `deny` and `observe` are different undertakings.

**Human.** On claude.ai, Settings → Privacy, turn "Help improve Claude" off.
Then, on any machine already logged in to Claude:

```
claude setup-token
```

Copy the token into a password manager. It prints once. The same token works on
every box you create under this account, so one token per host is fine.

**Check:** the reply granting permission is saved somewhere durable, and the
token is in the password manager. Nothing below needs either yet.

## 2. Host preconditions

Run each and read the answer before continuing.

```
uname -m                       # arm64 expected; x86_64 works but --rosetta is moot
sw_vers -productVersion        # 13 or newer
sysctl kern.hv_support         # must be 1: the virtualization framework is usable
which brew                     # Homebrew present, or install it first
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com   # 4xx is fine; a TLS error is not
```

What the answers mean:

- `kern.hv_support: 0`, or `limactl start` later fails at boot rather than at
  download, points at device management restricting virtualization. Stop and
  report; there is no workaround in this repository.
- A certificate error from `curl` means a TLS-intercepting proxy. You will
  need its root certificate as `~/.config/agent-box/guest/ca.pem` in phase 4.
  Export it from Keychain Access (System keychain, the corporate root) as PEM.
- No Homebrew: Lima and gitleaks both ship release binaries on GitHub, but
  install them the same way you would any other tool on this machine's policy.
  Do not improvise a package manager.

**Check:** `kern.hv_support: 1`, and `curl` returned an HTTP status code.

## 3. Install the tools and the two checkouts

```
brew install lima gitleaks uv
mkdir -p ~/dev ~/.local/bin
git clone https://github.com/konyklabs/agent-box ~/dev/agent-box
git clone https://github.com/konyklabs/porthole  ~/dev/porthole
ln -sf ~/dev/agent-box/bin/agentbox ~/.local/bin/agentbox
uv tool install git+https://github.com/konyklabs/porthole
```

`~/.local/bin` must be on `PATH` (it usually is with `uv`). porthole finds
`agentbox` on `PATH`, or via `--agentbox ~/dev/agent-box/bin/agentbox`.

**Check:**

```
limactl --version           # 2.x
gitleaks version            # 8.x
agentbox 2>&1 | head -3     # usage text, not "command not found"
porthole --version          # v0.x
```

## 4. Host configuration directory

Nothing in here is ever committed anywhere. Create the shape first:

```
mkdir -p ~/.config/agent-box/guest/claude ~/.config/agent-box/guest/plugin-dir
touch ~/.config/agent-box/guest/allowlist.local
printf 'egress: deny\n' > ~/.config/agent-box/config
```

Then the four files, in this order.

**`~/.config/agent-box/blocklist.txt` — human.** One literal term per line:
the names, hostnames and codenames that must never leave this machine. It sits
in the parent directory, never in `guest/`, and is never mounted. Two things
learned the hard way: a **public** product or company name does not belong on
it, because a public sample that names its vendor in every file will never
mount; and a repository that is itself full of internal names (a work
monorepo) cannot pass a scan for those names either. For that repository the
honest setting is an **empty** file, so preflight becomes the secrets scan
alone, which is the check that matters. Decide per host, write it down in the
local note (phase 10), and set it private:

```
chmod 600 ~/.config/agent-box/blocklist.txt
```

The agent verifies only this, and prints only this:

```
test -f ~/.config/agent-box/blocklist.txt && stat -f '%Sp %z bytes' ~/.config/agent-box/blocklist.txt
test ! -e ~/.config/agent-box/guest/blocklist.txt && echo "not in guest/: ok"
```

**`~/.config/agent-box/guest/allowlist.local` — human types the values.** What
the tests will talk to that is not the model, GitHub, npm or PyPI. The usual
shape for a staging environment reached over a VPN is two CIDRs and one domain
suffix, and the mode stays `deny`:

```
# ~/.config/agent-box/guest/allowlist.local
<corporate range>/8           # reachable over the host's VPN
<VPN carrier range>/10        # the VPN's own address pool
.<staging suffix>             # every host under the staging domain
```

A suffix line starts with a dot and needs no list of hosts; a CIDR needs no
resolution. Comments start with `#`. The agent checks shape, not content:

```
grep -vE '^\s*(#|$)' ~/.config/agent-box/guest/allowlist.local | wc -l    # count of live lines
```

If the values are not known yet, leave the file empty and use the observe
recipe in phase 9 instead of guessing.

**`~/.config/agent-box/guest/plugins.txt` — agent.** Public marketplaces only:

```
cat > ~/.config/agent-box/guest/plugins.txt <<'TXT'
# Marketplaces and plugins installed inside the guest at provisioning time.
marketplace konyklabs/claude-plugins
install supervisor@konyklabs-plugins
install py-testing@konyklabs-plugins
TXT
```

**The application's own credentials — not here.** A test app that needs an
OAuth client secret, a payment sandbox key or a gateway URL gets them inside
the guest, never in the mount: see phase 7b. Preflight will refuse a `.env`
in the repository, and it is right to.

**`~/.config/agent-box/guest/claude/CLAUDE.md` — agent, from the person's
existing one.** Copy only the standing instructions you want inside the box.
Only `CLAUDE.md`, `settings.json`, `governor.json` and `rules/*.md` cross;
anything else in that directory is refused at launch. Do not put a
`settings.json` here on the first pass; add it later if a setting is missed.

**`~/.config/agent-box/guest/ca.pem` — only if phase 2 found a TLS proxy.**

**Check:**

```
ls -la ~/.config/agent-box ~/.config/agent-box/guest
cat ~/.config/agent-box/config          # egress: deny
```

`blocklist.txt` is in the parent, mode `-rw-------`; `guest/` holds
`allowlist.local`, `plugins.txt`, `claude/`, `plugin-dir/` and nothing named
`blocklist`.

## 5. Preflight the repository, then create the box

The repository must be a git checkout with at least one commit; the run
branches from its current HEAD. Preflight scans it for secrets and for the
blocklist terms and reports paths only:

```
agentbox preflight ~/dev/<repo>
echo "exit $?"
```

Exit 0 continues. Exit 1 lists paths; fix or exclude them and re-run. Do not
create a box against a repository that fails preflight.

Create, with the profile the tests need. For a browser-tested application
stack that is Docker plus Playwright; leave either off if the repository does
not use it, because the profile is fixed for the life of the box:

```
agentbox create ~/dev/<repo> --docker --playwright --egress deny
```

Add `--forward 3000` (or whichever port) only if a person wants to open the app
in a browser on the Mac. It is the one widening in the design and it is fixed
at create time.

What to expect: preflight runs again, the effective sizing is printed
(defaults with `--docker`: 4 CPUs, 8GiB, 60GiB), the egress mode is printed with
where it came from, then Lima downloads the Ubuntu image (several minutes, once
per host) and provisions. First boot installs Docker, Node 22, the Playwright
system libraries and the plugins from `plugins.txt`. A summary follows.

Where it can stop, and what that means:

- Stalls or fails during the image download: network or proxy. Check phase 2.
- Fails at boot after the download: virtualization restricted. Report it.
- Sits at "Installing rosetta": only with `--rosetta`; run
  `softwareupdate --install-rosetta` on the host.
- Boot completes but the plugin step says the marketplace was unreachable:
  the VM is fine and has no plugins yet. Continue to phase 7 and run
  `agentbox plugins ~/dev/<repo>` after the firewall check passes.

**Check:**

```
agentbox status
```

One line for the new box, `running`, `fw=deny`, a Claude Code version, `runs=0`.

## 6. The token — human, in a separate terminal

```
agentbox token ~/dev/<repo>
```

Paste the token from the password manager. It is not echoed, not written to the
host, not passed as an argument and not put in the environment. It lands inside
the guest at `~/.config/agent-box/token`, mode 600.

The agent's part is to wait for the person to say it is done, then continue.

## 7. Prove it works before any run

```
agentbox verify-auth ~/dev/<repo>
```

This makes one real model call with the token and prints pass or fail with the
reply. It is the only proof that authentication works. If it fails, in order:
an `ANTHROPIC_API_KEY` in the guest environment (`agentbox shell`, then
`echo $ANTHROPIC_API_KEY`, must be empty), then the firewall, then a managed
Claude Code configuration on the device restricting sign-in.

```
agentbox firewall-check ~/dev/<repo>
```

Every guest line must say `PASS`. The container lines say `SKIP` on a fresh
box, because the probe uses `alpine:3` and will not pull it from inside the
firewall unit; a run that builds its own images does not change that. Pull it
once, then re-run:

```
limactl shell agent-box-<repo basename> -- docker pull alpine:3
agentbox firewall-check ~/dev/<repo>
```

A container line saying `FAIL` means container egress is not filtered: stop.

If `allowlist.local` has values, prove one of them from inside the box before
trusting a test that depends on it. `agentbox shell ~/dev/<repo>` opens a tmux
shell in `/work`; from there `curl -sS -o /dev/null -w '%{http_code}\n'
https://<a staging host>` should return a status code, not a connection
refused. Type the host name in that shell; do not put it in a report.

**Check:** verify-auth `pass`, firewall-check all `PASS` or `SKIP`, one staging
host reachable if the allowlist names one.

## 7b. The application's credentials, into the guest

Test-tier values only. They go to `~/app.env` in the guest home, mode 600,
outside the mount, and the brief exports them with `set -a; . ~/app.env; set +a`.
That line is **shell**, not dotenv: quote every value, because a street with a
space or a suite number with `#` otherwise ends the export at that line and
the run starts with half an environment. From the host, one line, nothing
printed:

```
limactl shell agent-box-<repo basename> -- sh -c 'umask 077; cat > ~/app.env' < /path/on/this/mac/app.env
```

Then, inside the guest, make sure it sources cleanly:

```
limactl shell agent-box-<repo basename> -- sh -c 'set -a; . ~/app.env; set +a; echo sourced ok'
```

`python-dotenv`, `pydantic-settings` and Node's `dotenv` all read the process
environment ahead of a `.env` file, so no application change is needed. If a
value is only ever read from a file, point the app at `~/app.env` with its own
option; never write `/work/.env`.

**Check:** `sourced ok`, and a `wc -l` of the file that matches the source.

## 8. The first run

Write the brief by copying `templates/brief.md`. The whole file is the prompt.
It must say what done looks like, which files are in scope, the exact test
commands, and when to stop. Build environments under the guest's home, never
under `/work`, because `/work` is the host's own directory and a Linux venv
built there overwrites the Mac's. A worked example that exercises Docker,
Playwright and a seeded bug is the demo stack's `brief.md` from the first host.

```
agentbox run ~/dev/<repo> briefs/<task>.md --model sonnet --heal 2 --heal-delay 180
agentbox logs ~/dev/<repo> -f
```

The run is detached; `logs -f` follows it, `agentbox runs ~/dev/<repo>` lists
it, `agentbox stop-run ~/dev/<repo>` interrupts it, and `porthole` shows all of
that in one window. The agent works on a branch named `agent/<slug>-<stamp>`
and cannot push.

`--heal 2` lets the box retry a failure twice on its own, each attempt told
what failed and to repair the environment first; `--heal-delay` should exceed
any cooldown the live tier is subject to. Two states to know:

- **`waiting`**: the agent needed a decision only you can make and wrote it
  down instead of guessing. `agentbox ask ~/dev/<repo>` prints the question;
  `agentbox resume ~/dev/<repo> --answer "…"` continues the brief with your
  answer. From your phone, that is a Remote Control session on this host.
- **`failed` with "this needs a person"**: the heal budget is spent. Read
  `agentbox logs`, then `agentbox learnings ~/dev/<repo>`, which is where the
  runs write what they had to fix and what should change in the brief, the
  box or the app.

To have the box survive a stopped VM or a sleeping Mac unattended:

```
agentbox keepalive ~/dev/<repo> on
agentbox watchdog --install        # once per host; a launchd job every 5 minutes
```

When it ends:

```
agentbox runs ~/dev/<repo>
cat ~/dev/<repo>/.agent-box/last-run.txt
git -C ~/dev/<repo> log --oneline main..agent/<branch>
git -C ~/dev/<repo> diff main..agent/<branch> --stat
```

Read the diff on the host, in the host's tools. An exit code of 3 means the
leak check found a token fragment in the output: rotate the token (phase 11)
before anything else.

If the repository has a Python test environment on the host, expect to
recreate it after the first run if the brief let the agent build one under
`/work`; the fix is to keep the two apart by path, as the brief above does.

**Check:** a run with state `done`, exit 0, a branch with one commit, and a
diff a person has read. If the Chromium download logged connection retries
before succeeding, that is the near-zero-TTL CDN address described in
[daily-use.md](daily-use.md); it recovers on its own, and `firewall-check`
refreshes the set if it does not.

## 9. If the repository's reach is unknown: observe first

When nobody can say what the tests talk to, do not guess an allowlist:

```
agentbox create ~/dev/<repo> --docker --playwright --egress observe
# token, verify-auth, firewall-check as above; then run the suite for a day
agentbox egress-log ~/dev/<repo> --since 24h
agentbox egress-log ~/dev/<repo> --since 24h --as-allowlist >> ~/.config/agent-box/guest/allowlist.local
```

**Human reads the appended lines before keeping them**: observe records what
the code did reach, not what it should. Then:

```
agentbox egress ~/dev/<repo> deny
```

which rebuilds the firewall and prints the verification. Tell whoever gave
permission that the box has moved from observe to deny.

## 9b. The work monorepo

Everything above applies; the differences are in the repository, and they are
the subject of [preparing-a-repo.md](preparing-a-repo.md): clone rather than
mount the working copy, one command per tier written down, a `mock|live`
switch every service reads, the live tier's cost stated at the top of its
README, and a box sized for several services:

```
agentbox create ~/dev/<monorepo> --docker --playwright --egress observe \
    --cpus 6 --memory 12GiB --disk 80GiB
```

Start in `observe`, run the live tier once, turn the log into the allowlist,
switch to `deny`. The first brief for such a repository is not the refactor;
it is "make the three tier commands true", so the refactor runs against a
suite the agent can execute unattended.

## 10. Record it

The setup produced facts that are not in any repository and that the next
session will need. Write them in a local note, `.local/agent-box-host.md` or
equivalent, never in a commit: which phases needed a human, what the
preconditions returned, the box name, which profile flags were used, whether
a `ca.pem` was needed, and the exact output of verify-auth and firewall-check.
Anything worth changing in this repository — a check that lied, a step that
was missing — becomes an issue on `konyklabs/agent-box` with the internal
names removed.

## 11. Stop, rotate, decommission

```
agentbox stop    ~/dev/<repo>       # keep the box, free the memory
agentbox destroy ~/dev/<repo>       # delete the VM, its disk and the token file
```

After `destroy`, revoke the token at claude.ai → Settings → Claude Code. Both
halves matter. Rotation is the reverse: revoke, mint, `agentbox token` again;
no other box on the host is affected unless it used the same token, in which
case run `agentbox token` on each.

## Quick reference: what "good" looks like at each gate

| Phase | Command | Good |
|---|---|---|
| 2 | `sysctl kern.hv_support` | `1` |
| 3 | `agentbox`, `porthole --version` | usage text; a version |
| 4 | `ls ~/.config/agent-box` | `blocklist.txt` mode 600 in the parent, nothing named blocklist under `guest/` |
| 5 | `agentbox preflight` | exit 0 |
| 5 | `agentbox status` | `running`, `fw=deny`, `runs=0` |
| 7 | `agentbox verify-auth` | `pass` and a reply |
| 7 | `agentbox firewall-check` | all `PASS`; container lines `PASS` after `docker pull alpine:3` |
| 7b | `sh -c 'set -a; . ~/app.env'` in the guest | `sourced ok` |
| 8 | `agentbox runs` | one `done`, exit 0; or `waiting` with a question you can answer |
