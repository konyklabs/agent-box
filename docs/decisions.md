# Decisions

Why this is built the way it is, and what was rejected. Each entry names the
thing it is protecting against, because a control whose threat is forgotten
gets removed by the next person who finds it inconvenient.

## Why the premise is an unattended agent, not a particular user

The isolation this project builds — one mounted repository, one token,
default-deny egress, no push — was worked out against a single scenario:
running an agent against a repository under a personal subscription. Nothing
in the actual design depends on who owns the machine or why the token is
personal, though. It depends on one thing: an agent is being allowed to run
without someone watching every action it takes, which is what turns an
ordinary mistake or a prompt injection into something expensive rather than
merely embarrassing.

So the premise is stated as the general case rather than the scenario it was
first built for. Whoever is running this — against their own project, a
client's repository, or code someone else owns — needs the same two
boundaries: the agent must not reach anything beyond the one thing it was
given, and whatever token it authenticates with must not be visible to what it
writes. Tying the tool to one relationship between operator and code owner
would have meant re-deriving the same guarantees for every other one; stating
the premise as "an unattended agent" instead means the isolation it earns does
not depend on the reason you needed it.

## The two directions of isolation

Everything below serves one of two goals, and it is worth being explicit about
which, because they pull in different directions:

- **Outward.** The agent must not see the host. Not other repositories, not
  the host's SSH keys, not browser profiles, not the rest of its filesystem.
- **Inward.** A subscription token must not end up on the host's disk, in its
  backups, or in its logs.

A control that only serves one of these is not enough on its own.

## Why a virtual machine, and why Lima

A container shares the host kernel and, on macOS, would run inside a Linux VM
anyway. A VM boundary is the one that is easy to reason about and easy to
explain to whoever has to approve this.

Lima specifically, over the alternatives:

- **Apple's Virtualization.framework** through `vmType: vz`, so there is no
  emulation layer on Apple Silicon and no third-party hypervisor kext.
- **Mounts are declared, not discovered.** The instance sees exactly the
  directories the template lists. Lima's own default template mounts the host
  home directory read-only; this template does not, which is the single most
  important line in it.
- **Instances are disposable and scripted.** `limactl delete` takes the disk
  image and everything in it, including the token.
- It is a single Homebrew formula with no daemon and no login.

Rejected: **Docker Desktop** (licensing on a managed Mac, shared kernel, and
the default bind-mount ergonomics encourage mounting too much). **UTM** (GUI
first, awkward to script). **A devcontainer** (the isolation is the container's,
which is the boundary being avoided). **A second physical machine** (correct,
and not available).

## Why one instance per repository

Lima fixes mounts at create time. That is a limitation turned into a feature:
the set of files a VM can reach is decided once, when the VM is made, and
cannot drift afterwards. There is no command that adds a directory to a running
box, so there is no command to reach for at 11pm when something is nearly
working.

The cost is a disk image per repository, which is why `agentbox destroy` is a
first-class command rather than a footnote.

## Why the mounts are template parameters

Lima expands `{{.Param.Key}}` in `mounts[].location` (a host template) and in
`mounts[].mountPoint` (a guest template). Verified against Lima 2.2.0's own
annotated reference config, which shipped at
`/opt/homebrew/share/lima/templates/default.yaml`:

> "location" can use these template variables: {{.Home}}, {{.Dir}}, {{.Name}},
> {{.UID}}, {{.User}}, {{.Param.Key}}, {{.GlobalTempDir}}, and {{.TempDir}}.

So `bin/agentbox` passes `--param repo=... --param box=...` and the template
needs no rewriting. The two alternatives the spec allowed were not needed:
a `--set` yq expression (harder to read, and Lima restricts some yq operators),
and generating a derived YAML per instance into a config directory (a second
copy of the template that can go stale against this one).

The `param:` defaults in the template are placeholders. They exist so that
`limactl validate lima/agent-box.yaml` resolves to real paths on a bare
checkout; `bin/agentbox` always overrides both.

## Why `CLAUDE_CONFIG_DIR` is set by the provisioner, not by `env:`

`env:` values are **not** template-expanded. The list of fields that are
expanded is explicit in Lima's source (`pkg/limayaml/defaults.go`,
`executeGuestTemplate` / `executeHostTemplate` call sites): `user.home`, the
`provision` script, content, path and owner fields, `probes`, the mount
locations and mount points, port-forward sockets, and `copyToHost`. `env` is
absent from that list.

That matters because the guest home is not `/home/<user>`. Lima's builtin
default is `/home/{{.User}}.guest`, with `/home/{{.User}}.linux` kept as an
accessible alias; `limactl template copy --fill` on this template resolves it to
`/home/<user>.guest`. A literal path in `env:` would therefore be wrong, and a
templated one would be written through verbatim as the string `{{.Home}}`.

So the template's `env:` carries only the two literals that need no expansion
(`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`), and the provision script —
which *is* expanded, and receives `{{.User}}` and `{{.Home}}` as arguments —
appends `CLAUDE_CONFIG_DIR` to `/etc/environment` and writes
`/etc/profile.d/agent-box.sh`. Lima rewrites `/etc/environment` during boot,
before provisioning runs, so appending on every boot is both necessary and
safe.

## Why the firewall is in the guest

The rules could live on the host — a packet filter rule per VM interface, or a
proxy the guest is forced through. Both were rejected:

- Host-level packet filtering means changing a system-level configuration on
  the host itself, which may not even be yours to change. That is exactly the
  sort of change this project exists to avoid needing.
- A proxy has to terminate TLS to filter by hostname, which means minting a CA
  and trusting it in the guest — building the very interception this setup
  otherwise treats as a hazard.

Inside the guest, `iptables` plus an `ipset` of resolved addresses is small,
inspectable, and the same mechanism Anthropic ships in its own devcontainer.
`guest/init-firewall.sh` is derived from that reference script and says so.

The honest limitation: the agent runs as a user that can `sudo`, because Lima's
guest user has passwordless sudo and the provisioning depends on it. An agent
that decided to disable the firewall could. This is a guard rail against a
capable tool doing something careless, not a sandbox against a hostile one. The
VM boundary is what protects the host; the firewall protects against
exfiltration by accident.

Two smaller choices inside it:

- **Rebuild every 15 minutes.** Allowlist entries are names, the ipset holds
  addresses, and the CDNs behind `api.anthropic.com` rotate theirs. A stale set
  fails closed — the agent simply stops being able to reach the model — which
  is safe but confusing, so a timer refreshes it.
- **IPv6 is closed entirely.** No v6 allowlist is maintained, and leaving v6
  open would be a way around every v4 rule.
- **Policies are reset to ACCEPT immediately after the flush.** The reference
  script assumes it runs once, from a clean container. Here it also runs from
  the timer, when the policy is already DROP — and the rebuild itself needs DNS
  and `api.github.com`. Without the reset, every refresh after the first would
  fail.

## Why `allowlist.local`, `blocklist.txt` and `ca.pem` live outside this repo

They are the three files whose contents are specific to wherever this is being
used: which internal hosts the app under test needs, which terms must never
leave, and which corporate root signs intercepted TLS. Each is a small
description of the environment it runs in.

They live in `~/.config/agent-box/` on the host, and the `guest/` subdirectory
of it — containing `allowlist.local` and `ca.pem`, and nothing else — is mounted
read-only into the guest at `/opt/agent-box-config`. It is a mount, not a copy,
and that distinction is the whole point.

**The split into a subdirectory is not tidiness.** `blocklist.txt` stays in the
parent, unmounted. It is the literal list of terms that must never leave, so it
is the single file in this project that most needs to stay out of a VM which
talks to a model under your subscription. Mounting the whole config
directory would have put it at `/opt/agent-box-config/blocklist.txt`, readable
by an agent running with `--dangerously-skip-permissions`, one `cat` away from
the transcript — and repository content is untrusted input that could steer an
agent into reading it. Nothing in the guest needs it: the firewall reads only
`allowlist.local` and provisioning reads only `ca.pem`. `agentbox create`
refuses to start if it finds `blocklist.txt` inside the mounted subdirectory.

An earlier version copied them into this checkout's gitignored `.local/`
directory. That was wrong twice over. A `.gitignore` is one `git add -f`, one
`git clean -x` mishap, or one repository-wide scanner away from publishing an
internal hostname, and the rule is that blocklisted strings never enter
a durable artifact at all — not that they enter one and are then excluded. It
also coupled every instance to one shared file: creating a VM for repository B
rewrote the allowlist that repository A's running VM would read at its next
refresh, and running the smoke test with a hermetic config directory deleted the
real one out from under every live instance.

A mount has none of those properties. `agentbox create` creates the directory if
it is missing, and it is allowed to be empty.

`host/preflight.sh` reports **paths only** for blocklist matches — never the
matching line and never the term. A finding report is something you might paste
into a ticket; it must not become the leak it was looking for.

## Why the token never touches the host

`agentbox token` reads it with `read -rs` from `/dev/tty` and pipes it straight
into `limactl shell`. It is never a command-line argument (argv is world-visible
in `ps`), never an environment variable, never a file on the host, and never
echoed. On the guest it lands at `~/.config/agent-box/token`, mode 600, on a
disk image that `agentbox destroy` deletes.

`guest/agent-run.sh` refuses to start if `ANTHROPIC_API_KEY` or
`ANTHROPIC_AUTH_TOKEN` is set, because either silently outranks the OAuth token
and would bill an API account instead of drawing on the subscription. A silent
wrong-account run is worse than a loud failure.

## Why the guest user is not root

Claude Code refuses `--dangerously-skip-permissions` when running as root. That
flag is the point of a headless run in a disposable VM: the isolation is the
VM, so per-action prompting buys nothing and prevents unattended work. So the
agent runs as Lima's ordinary guest user, and `agent-run.sh` asserts it.

## Why the agent never pushes

`agent-run.sh` creates a branch, runs the task, and stops. Pushing is a durable,
outward act; a human reviews the diff on the host and pushes it under their own
identity. `ssh.forwardAgent` is false in the template, so the VM has no
credential to push with even if the script were changed.

Run logs are excluded through `.git/info/exclude` rather than the work repo's
`.gitignore`, because the work repo belongs to someone else and its tracked
files should not acquire a line about this tool.

**Amended.** The superseded claim is not the mechanism but who writes it: the
exclude entry used to be written by `agent-run.sh` alone, so a box that had only
ever held an interactive session had no entry at all. It is now
`abx_exclude_state_dir` in `guest/lib.sh`, called unconditionally by both
`agent-run.sh` and `claude-session.sh`, and it does nothing unless
`git rev-parse --git-dir` answers, so a mount that is not a repository is left
untouched. The channel's directory on the mount also carries its own `.gitignore`
of `*`, written by whichever side creates it first, because either session may
create it before a run has ever happened.

## Why `agentbox start` re-runs preflight

A repository is scanned before it is mounted, but a repository changes between
sessions. Re-scanning on every start costs seconds and catches the case where
something confidential arrived in the repo after the VM was created.

## Why the firewall rebuild never removes the live ruleset

The reference devcontainer script flushes every rule, sets the policies to
ACCEPT, rebuilds incrementally, and sets them to DROP at the very end. That is
fine for a container that runs it once at startup. It is not fine here, for two
reasons that only appear when the same script runs on a timer.

**Every error path in between leaves the machine wide open.** Eight things can
fail between the flush and the final DROP: the `api.github.com` fetch, the JSON
field check, `pipefail` on a CIDR grep that matches nothing, an unparseable
CIDR, a missing default gateway. Any one of them ends the script with no rules
and an ACCEPT policy. The unit goes to `failed`, nothing restores the deny, and
the next attempt is fifteen minutes away. A brief GitHub outage at one timer
tick would silently give the box full internet access.

**And the rebuild window itself is a hole.** Between the flush and the final
policy there are no rules at all, for as long as one HTTP fetch plus one DNS
lookup per allowlisted name takes. Four times an hour, forever, unlogged.

So the new state is built beside the old one and swapped in:

- addresses go into a second ipset, populated fully, then `ipset swap`ped with
  the live one — atomic from the kernel's point of view;
- rules are applied with a single `iptables-restore --noflush`, which replaces
  the contents of the three chains agent-box owns as one transaction and leaves
  every other chain in the table alone. The original version omitted
  `--noflush` and replaced the whole filter table instead, which was equivalent
  until Docker arrived and then was not; see "Why the firewall owns three
  chains rather than the whole table" below.

The rebuild therefore runs *under* the standing deny. It needs only DNS to the
configured resolvers and the GitHub ranges, both of which the previous run's
ruleset already permits. The first run is the one exception: there is no
ruleset yet, so the machine is briefly open, which is why provisioning does all
its downloading before the firewall is ever started.

**On failing closed.** There is an `ERR` trap, but it does not slam the box down
to loopback unconditionally, and that is deliberate. Because nothing tears down
the live ruleset, an error normally leaves the previous deny ruleset intact —
already the safe outcome, and a recoverable one, since the next timer tick can
still reach DNS and GitHub to try again. A box cut down to loopback-only cannot
rebuild itself at all: the rebuild needs exactly the access that was just
removed, so it would stay off the network until someone restarted it. The hard
close is therefore reserved for the one case where it is the only safe option —
an error when there is no standing deny ruleset to fall back on.

**And the hard close keeps the operator's door open.** Closing to loopback only
would be a mistake of a different kind: Lima reaches the guest over TCP to port
22, so a lo-only ruleset drops both new `limactl shell` connections and any
session already open — including the one needed to run the recovery the script
prints. The realistic trigger is a transient `api.github.com` failure on first
boot, which is exactly when someone needs to get in and look. So the hard close
also accepts `ESTABLISHED,RELATED` in both directions and inbound TCP port 22
from the gateway. Egress stays shut, because no *new* outbound connection is
permitted; only replies on connections that already exist. The one thing that
survives it is a connection opened before the close, which on a first-boot
failure means nothing is running yet.

## Why DNS is restricted to the configured resolvers

`-A OUTPUT -p udp --dport 53 -j ACCEPT` with no destination is an open
exfiltration channel, and it bypasses everything else in the file. A query name
is data: a lookup of `<base64-of-the-token>.attacker.example` against any
resolver on the internet carries the payload out, and never touches an
allowlisted address, the ipset, or the REJECT rule.

So both DNS rules carry `-d`, restricted to the resolvers the guest actually
has. Ubuntu may point `/etc/resolv.conf` at systemd-resolved on `127.0.0.53`, in
which case the addresses that really leave the machine are the upstream servers
in `/run/systemd/resolve/resolv.conf`, so both files are read; if neither yields
a non-loopback address, the gateway is used, because that is where Lima's host
resolver lives.

The verification asserts this directly: `dig @9.9.9.9` must fail.

## Why there is no blanket accept toward the host subnet

An earlier version turned the gateway address into a `/24` and accepted all
traffic to and from it, on every port, in both directions. Under `vmType: vz`
that subnet is the host plus every other VM on the machine, so the agent could
reach any port the host had bound on that interface, entirely outside the
allowlist.

The justification given was `limactl shell`, and it was wrong: that is an
inbound SSH connection, already covered by the ESTABLISHED rule and by a single
inbound accept for port 22 from the gateway address. Nothing outbound is needed
for it. Everything else the guest legitimately needs from the host is either an
already-established connection or carried over vsock.

`propagateProxyEnv` is set to `false` for a related reason. Lima otherwise
copies the host's `http_proxy`, `https_proxy` and `no_proxy` into the guest's
`/etc/environment`. On a managed host those routinely name internal hosts —
exactly the strings this VM exists to keep away from a model — and
they would hand the agent a general-purpose egress relay the allowlist does not
govern. A proxy that is genuinely wanted goes in `allowlist.local` and `ca.pem`,
which makes it a decision someone made rather than one that happened.

## Why verification asserts the mechanism, not one symptom

"`curl https://example.com` did not connect" is a weak claim. It passes just as
happily when DNS is broken, when curl is missing, when the interface is down, or
when the ruleset was never applied at all. It is also blind to the two holes
above: `example.com` is neither a DNS destination nor on the host subnet, so a
firewall with wide-open port 53 and a wide-open host subnet still prints PASS.

So the checks now assert what is actually true of a working ruleset: that the
OUTPUT policy is DROP, that a rule references the allowlist ipset, that the
IPv6 OUTPUT policy is DROP, that a *literal* address outside the allowlist is
refused (which tests the REJECT rule rather than name resolution), and that DNS
to a foreign resolver fails. The name-based probes are kept on top of that, not
instead of it.

IPv6 is closed outright, and its failure is no longer swallowed. Every
`ip6tables` call used to end in `|| true`, so on a kernel without the
`ip6_tables` module all of them failed, the script logged "IPv6 egress closed",
and IPv6 was wide open with every check still green.

## The token's residual risk, stated plainly

The token never touches the host filesystem: `agentbox token` reads it with
`read -rs` from `/dev/tty` and pipes it into the guest, never as an argument
(argv is visible in `ps`), never in the environment, never echoed.

What is *not* true is that the token can never reach the host. Inside the VM,
the agent runs with `--dangerously-skip-permissions`, can read the token file,
and can write anywhere under `/work` — which is the host's filesystem, and
its Time Machine backups. That needs no malice on anyone's part: repository
content is untrusted input to a model, and the model's own output used to be
written straight onto the host mount.

Two changes, and one honest limitation:

- The full JSON transcript now stays in the guest home, at `~/.agent-box/runs/`.
  Only a scrubbed summary — branch, starting ref, model, exit code, a count of
  changed files — crosses to `/work/.agent-box/last-run.txt`.
- After every run, the transcript, `git status`, and both diffs are checked for
  the first and last eight characters of the token. A hit prints a loud warning,
  exits 3, and tells the user to rotate.

The limitation: this is a backstop, not a boundary. It catches the accident and
the obvious case. It would not stop a determined agent that encoded the value
before writing it. The boundary that actually holds is the VM plus the egress
allowlist; this check is there because the cost of a leaked subscription
credential on the host is high enough to be worth a cheap second look.

**Amended: more than the summary crosses now.** The first bullet above said the
scrubbed summary is the only thing written to `/work`. Since the channel, the box
also writes messages into `<repo>/.agent-box/channel/to-host/`, which is the
host's disk by the same argument. Three things keep that from weakening the
paragraph. The messages are produced by the same guest-side scrubber as the
summary, so the token check happens before the bytes cross rather than after. The
run's leak check was extended to cover them: `check_stream_for_token "the channel
outbox"` reads every file in that directory newer than the run's own
`meta.json`, so a run that wrote a message containing a token fragment still
exits 3. And a message a leak-flagged run wrote is refused by `agentbox handoff`
with the same banner `logs` uses. The limitation is unchanged and is the same
limitation: a determined agent that encodes the value defeats all three.

## What the guest can still see: names

Lima's host resolver answers the guest's DNS queries using the host's own
resolver configuration. Two consequences follow, and both are accepted rather
than fixed.

The guest can **resolve** internal names, including split-horizon names that
only exist on a private network. It cannot connect to them — the allowlist
governs where packets may go, and an internal address is not on it — but
existence and address are learnable. In the other direction, each lookup reaches
the host's resolver with the VM as its origin.

This is accepted because the alternative is worse for the actual use case:
turning off the host resolver and pinning a public one in `dns:` would break the
common case where the app under test is reachable only through a private
resolver, which is precisely what `allowlist.local` exists to support. The thing
that limits damage is the allowlist, not the resolver. If a deployment does not
need internal names at all, setting `hostResolver.enabled: false` with an
explicit public `dns:` closes this, at the cost of that capability.

## Why the guest has a git identity

Provisioning sets `user.name` to `agent-box` and `user.email` to
`agent-box@localhost`, system-wide. Without them, a brief that says "commit your
work" ends at `Please tell me who you are`, or the agent improvises a `git
config` of its own, which is worse. The identity is deliberately generic:
nothing identifying the host user belongs in a commit an agent made. `--system`
keeps it out of the work repository's own config.

`safe.directory` is set for `/work` for a mechanical reason: over virtiofs the
tree is owned by the host uid, and git otherwise refuses to operate in it.

## Why plugins are installed inside the guest, and why the config sync is an allowlist

Two related choices, one about where plugins come from and one about what may
follow you in from the host.

**Plugins install from a public marketplace, inside the VM.** The obvious
alternative was to mount the host's `~/.claude/plugins` read-only and let the
guest use it directly. Rejected, for three reasons. It carries installed state
that is specific to another machine — cache layouts, versions, a marketplace
registered from a local checkout path that does not exist in the guest — so it
is not even portable. It widens the read-only mount from a handful of files the
user wrote to a directory the CLI manages on its own, which makes "what can the
agent see" a question about someone else's implementation detail. And it hides
provenance: a plugin that arrives by mount has no version and no source, where
one installed from `konyklabs/claude-plugins` has both, in a file that can be
read back with `claude plugin list`.

The install runs after the firewall comes up, deliberately. It pulls from
GitHub, which the allowlist permits through the ranges fetched from
`api.github.com/meta`, so every first boot is a live test of that rule. When
the GitHub range rule breaks, it says so during provisioning rather than the
next time someone needs a package.

The marketplace is public, which is the part that makes this work without a
credential: nothing about registering `konyklabs/claude-plugins` needs an
account. `plugins.txt` is applied during provisioning, before the token has
been typed in, and again on demand through `agentbox plugins`.

A plugin still being written on the host does not want any of that. For those
there is `--plugin-dir`, which loads one plugin root for one session, installs
nothing and writes nothing: the roots live under
`~/.config/agent-box/guest/plugin-dir/`, arrive through the same read-only
mount as the allowlist, and are passed to every session the box starts. Edit on
the host, run again, see the change.

**The config sync copies an allowlist of names, never a directory.** The
source is a subdirectory of a mount the user edits by hand, and the obvious
implementation — copy `claude/` into `$CLAUDE_CONFIG_DIR` — is one careless
`cp` away from carrying `.credentials.json` from the host into a VM pointed at
a repository that is not the host's own. That is the inward direction of the
threat model, the one that is easy to forget because nothing visibly breaks
when it fails.

So the names that may cross are written down — `CLAUDE.md`, `settings.json`,
`supervisor.json`, `rules/*.md` (and `governor.json`, the pre-2.0 name, carried
as a legacy alias) — and everything else stays behind. Credential
and history-shaped names are not merely skipped, they are refused out loud:
a silent skip and a successful copy look identical in a log, and the one case
where the operator must not be left guessing is the one where a credential was
in the directory.

Trust is marked in the same script, for a mechanical reason. Claude Code will
not act in a folder it has not been told to trust, a repository's own
`.claude/settings.json` is inert until it has been, and `-p` cannot ask. There
is exactly one folder in this VM and `host/preflight.sh` scanned it on the host
before the VM was allowed to mount it, so the decision is made here, visibly,
rather than by a flag buried in a launch command.

## Why there is an interactive `agentbox claude`, given `agentbox run`

`agentbox run` is the mode with the safety rails: a branch per run, the JSON
transcript sealed inside the VM, a scrubbed summary as the only thing written
to the host, and a check of that summary and both diffs for token fragments
before it will report success. Everything about it assumes the output is
untrusted and the host's disk is precious.

`agentbox claude` has none of that, on purpose. It hands the terminal to the
CLI, which is what makes an interactive session useful and also what makes it
unscrubbable: there is no boundary to filter at when the model's output is
being drawn on the operator's screen in real time. The choice was between
having no interactive mode at all — which sends people to `agentbox shell`
followed by a `claude` that cannot authenticate, or worse, to exporting the
token by hand — and having one that is honest about what it does not do.

What it does keep is every precondition `agent-run` insists on, from the same
`guest/lib.sh`: not root, a 0600 token file, no `ANTHROPIC_API_KEY` quietly
outranking the subscription, the firewall active. Those live in one file rather
than three copies precisely because three copies is how one of them ends up
being the lenient one.

**Amended: it is now the box's tracked standing session.** The superseded claim
is "none of that, on purpose" read as *no bookkeeping at all*. An interactive
`agentbox claude` — and `agentbox session`, which is the same launch in tmux —
now takes the session name `claude`, gets a session directory under
`~/.agent-box/sessions/`, has the channel hooks wired, and is the session
`agentbox request` delivers to. What has **not** changed is the sentence that
mattered: the terminal is still unscrubbable, and that is still said out loud
once per launch.

The two commands reach the same name by different routes, which is why the rule
lives once in the guest script rather than twice in the CLI. `agentbox session`
names it explicitly: it passes `--tmux claude`, which becomes
`--session-name claude` in the process inside tmux. `agentbox claude` passes
nothing and *converges* on the same name when three conditions hold, because
taking it wrongly is worse than not taking it:

- **The launch is genuinely interactive.** Stdin and stdout are both ttys, no
  session name was given, and none of `-p`, `--print`, `--version`, `-v`,
  `--help` or `-h` is being forwarded to the CLI. An invocation that prints and
  exits holds no terminal and ends in seconds; a request delivered into one is a
  request nobody reads.
- **The name is free**, and freedom is decided by the recorded pid plus that
  process's own command line — not by a status file, not by tmux. So a hard VM
  stop, or a pid the kernel has since reused, reads as free rather than as a
  session that is still working.
- **Nobody else is taking it at the same moment.** The liveness check and the pid
  write happen under one lock, so two launches racing for the name are serialised
  rather than both believing they won.

A launch that loses says so on stderr, naming `agentbox attach` as the way to
reach the real one, and then continues exactly as it did before: untracked,
receiving nothing. It is not refused, because a second interactive session is a
reasonable thing to want; it simply is not the one the host talks to, and saying
so is what stops somebody waiting for a request that is being delivered to
another pane. The one case that *is* refused is a tmux launch whose name is held
by a live non-tmux session — and it is refused in the process the operator is
looking at, naming the pid, because a refusal inside a freshly created tmux pane
vanishes with the pane.

## Why background self-update is off in the guest

`DISABLE_AUTOUPDATER=1` is set both in the Lima template's `env:` block, so it
holds from the first boot, and by the provisioner, so it survives Lima
rewriting `/etc/environment`.

An automatic update is a new binary arriving over the network in the middle of
a run, changing the thing being tested while it is being tested. That is
unwelcome in any VM whose whole purpose is a reproducible box. It is worse
here, because the failure mode of a *blocked* update is not an error: it is a
slow start, or a hang, with nothing pointing at the network. `agentbox update`
does it deliberately and prints the version either side, which turns an
invisible background action into a visible one with evidence.

## Why settings.json is parsed rather than trusted, and where that is enforced

The carry-over allowlist matches file names. `settings.json` is on it, because
it is the file that makes the guest CLI behave the way its owner expects. It is
also a file that can hold a credential, which means a name-based allowlist
alone does not deliver what the entry above promises.

Three keys, all ordinary content of that format:

- `env` is merged into the CLI's own process environment, so
  `"env": {"ANTHROPIC_API_KEY": "..."}` is a literal key.
- `apiKeyHelper` is a shell command the CLI runs to mint one.
- `awsAuthRefresh` and `awsCredentialExport` do the same for Bedrock.

The `env` case is the sharp one, because of *when* it takes effect.
`abx_assert_environment` refuses to run when `ANTHROPIC_API_KEY` is set in the
shell environment, and says why: an API key silently outranks the OAuth token
and bills an API account instead of drawing on the subscription. A key arriving
through `settings.json` is injected by the CLI *after* that check has passed.
The refusal is intact and the thing it refuses walks in behind it.

So the file is parsed, not copied: those keys are removed, along with any value
anywhere in the document that starts with `sk-ant-`, and each removal is named
in the log the way a refusal is. The host's own file is never touched.

The same check then runs again in `abx_assert_environment`, against the
installed copy, and refuses to launch. Two places, deliberately: the filter
covers the file that crosses the mount, and the assertion covers a
`settings.json` written or edited inside the guest, which the filter never
sees. A guarantee enforced only at the point of copying is a guarantee about
copying, not about running.

## Why the trust merge locks, and never renames the file aside

`sync-claude-config.sh` runs before every launch and does a read-modify-write
of `.claude.json`, a file Claude Code also writes. An earlier version answered
a parse failure by renaming the file aside and starting fresh. That is the
worst available response to the most likely cause.

The most likely cause is not corruption. It is catching the file mid-write —
an interactive session in one terminal, `agentbox run` in another. Renaming
then takes a live session's config, with every other project's trust decision
and history in it, and puts it in a `.corrupt-<epoch>` file nobody will ever
look at; the running CLI writes its own state over the two-key replacement, and
the loss is permanent and silent.

Now: an flock on a sibling lockfile serialises this script against itself, and
a parse failure means re-read once after a short pause and then, if it still
does not parse, say so and exit non-zero **without touching the file**. The
caller already treats a failed sync as non-fatal, so the cost is one launch
running with the trust flag unset — recoverable on the next command. Displacing
a live config is not recoverable at all.

The lock cannot serialise this script against the CLI, which is why the second
half matters more than the first.

## Why settings.json is merged, not copied: the file has two owners

Carrying `settings.json` across looks like copying one file. It is not, because
two parties write to it.

The operator writes their preferences. The CLI writes `enabledPlugins` and
`extraKnownMarketplaces`, which is where `claude plugin install` records what
it installed. A wholesale copy makes the host the only author and destroys the
CLI's half — so the guest installs its plugins during provisioning, the next
launch syncs the config over the top, and every one of them is quietly
disabled. `claude plugin list` still reports them as installed. The smoke test
caught exactly this, which is why it now asserts the plugin is *enabled* rather
than merely present.

The same two keys are wrong in the other direction as well. The host's
`extraKnownMarketplaces` names a directory on the host — a path that does not
exist in the guest, and one there is no reason to write into a VM. That makes
these keys machine-specific state, the same category as the `plugins/`
directory that was already on the refused list.

So they are guest-owned: dropped from the incoming file, preserved from the
guest's own. Everything else in the file is the operator's and crosses as
written, which does mean a `hooks` or `statusLine` entry naming a host path
will not work in the guest. That is left as the operator's problem rather than
guessed at, because rewriting someone's commands is a worse failure than
letting one of them not run.

## Why tmux and `-p`, and not `claude --bg`

The CLI has a background mode of its own: `claude --bg` starts a session
detached, `claude agents --json` lists them, and `claude attach`, `logs`, `stop`
and `rm` drive them. On paper that is exactly the feature this section is
about, and it was the first thing tried.

Three things ruled it out for now.

The caps only exist for `-p`. `--max-budget-usd` — and `--max-turns`, wherever
it lands — are documented as working with `--print` only. A box whose whole
premise is an unattended agent on a shared subscription quota needs a spend
ceiling more than it needs a nicer process model.

`--bg` with bypassed permissions needs a disclaimer accepted interactively
first, in the guest, before it will start. An unattended box that requires
somebody to have clicked through something once is a box with an undocumented
manual step in it, and the step is invisible until the first run fails.

And the background daemon is a research preview. A preview is a fine thing to
build on when the alternative is nothing; here the alternative is tmux, which
is thirty years old, is one apt package, and gives the same detach-and-return
behaviour for interactive sessions and headless runs with the same commands.

So: `-p` inside a tmux session, `agentbox attach` to look, `agentbox stop-run`
to interrupt. Worth revisiting when the daemon leaves preview and the caps work
outside `--print`; the shape of `runs`, `logs` and `stop-run` would not have to
change, only what they drive.

Remote Control was considered for the same job and is not available at all: it
needs a browser login, and the CLI refuses it for a setup token, which is the
only credential this VM has.

## Why the sensors are stream-json and hooks, and never the transcript

Three things could tell you what a run is doing. Two are used.

`--output-format stream-json --verbose` gives one JSON object per line as the
run happens: the `system` init, each `assistant` message with its text and its
tool calls, each `user` message carrying a tool result, and a final `result`
carrying turns, cost, duration and whether the CLI considered the run to have
failed. `--include-hook-events` folds the hook lifecycle into the same stream.
This is a documented output format with a `--output-format` flag in front of
it, which is as close to a contract as the CLI offers.

Hooks give the other half. A hook command receives one JSON object on stdin
with the event name, the session, and for tool events the tool name, its input
and its response. `guest/hook-event.sh` turns each into one line of
`hooks.jsonl`. It always exits 0, because a PreToolUse hook that exits non-zero
blocks the tool, and an observer that can stop the thing it is observing is not
an observer.

The third is the transcript JSONL the CLI keeps under
`$CLAUDE_CONFIG_DIR/projects/`, and it is deliberately not read. It is internal
state, its shape changes between releases, and nothing promises otherwise. A
log built on it works until the next `agentbox update` and then produces
either an error or, worse, a plausible-looking wrong answer. The two sensors
above are narrower and they are what the CLI says it emits.

One consequence worth naming: only the `assistant` and `user` events carry a
timestamp of their own. `system` and `result` events inherit the last one seen,
which keeps the stream in its own order while letting hook lines and console
lines — both stamped as they are written — land between the stream events they
happened between. It is a merge by time where there is a time and by order
where there is not, and it is honest about which is which rather than
inventing precision.

## Why the formatter and the status script run in the guest

`agentbox logs`, `agentbox runs` and `agentbox status` all print text the model
produced. The one thing that must never reach the host's terminal is a fragment
of the OAuth token, and the only way to guarantee that is to redact before the
bytes cross — scrubbing on the host would mean the unscrubbed bytes had already
crossed, into a terminal, into scrollback, and into whatever is recording it.

So `guest/run-format.py` and `guest/box-status.sh` run inside the guest, read
the token file for the same head and tail `abx_scrub_token` uses, and print
only redacted text. The host CLI formats nothing it did not already know: it
knows the instance name, the repository path and the Lima state, and everything
else arrives as a finished line or a finished JSON object.

That has a second consequence, and it is the more important one. Everything a
user interface would need is already in `runs --json`, `logs --json` and
`status --json`. A UI is therefore a renderer of those three commands. It does
not talk to `limactl`, it does not read anything inside the guest, and it is
not a second place where the scrub has to be got right. There is exactly one
boundary, it is in the guest, and adding a front end does not add another.

## `--settings` merges hook arrays; it does not replace them

`guest/agent-run.sh` and `guest/claude-session.sh` both pass
`--settings /opt/agent-box/guest/hooks.settings.json`, and the whole
watch-and-steer design assumes that adds the sensor's hooks to whatever the
operator's own `settings.json` declares. If it replaced them instead, an
operator with their own hooks block would silently get no `hooks.jsonl`, and
nothing would report it: the only note in the code fires when the settings
FILE is missing, not when its contents are displaced.

Measured on 2026-09-05 against Claude Code 2.1.261, the version the guest
installs. A `SessionStart` hook in `$CLAUDE_CONFIG_DIR/settings.json` writing
one marker file, a different `SessionStart` hook in the file passed to
`--settings` writing another, one `claude -p` run:

```
--- SessionStart hook events in the stream ---
   2 hook_response SessionStart:startup
   2 hook_started SessionStart:startup
--- markers written ---
extra.marker
user.marker
```

Both fired. `--settings` merges. The comment in `guest/lib.sh` that says so is
therefore correct, and it is now correct on the record rather than on
assumption. Worth re-measuring if the CLI's settings resolution ever changes;
the symptom of a regression is an empty `hooks.jsonl` on a box whose operator
has their own hooks.

## Why the repository's own settings.json is refused, and the operator's is not

`sync-claude-config.sh` marks `/work` trusted before every launch, and its own
comment says that is what makes a repository's `.claude/settings.json` live
rather than inert. Nothing filtered that file. It arrives on a mount, so the
sync never sees it.

The repository is untrusted input by this project's own threat model. A
`settings.json` it ships can carry an `env` block with an API key that outranks
the subscription token, or a `hooks` block whose commands run in a process tree
that holds `CLAUDE_CODE_OAUTH_TOKEN`. The egress allowlist is what contains the
damage, which is not the same as preventing it.

So `abx_assert_settings_carry_no_credential` now reads three files, not one:
the guest's own `settings.json`, `/work/.claude/settings.json` and
`/work/.claude/settings.local.json`. The credential keys are refused in all
three. `hooks` is refused only in the repository's two, and the asymmetry is
the point: in the operator's own configuration a hook is a choice they made,
and in the repository's it is a command chosen by whoever wrote the repository
for a folder this VM marks trusted on the operator's behalf. Refusing is
abrupt, and it is the right kind of abrupt — the message names the file and the
key, so the operator can read the hook and decide, which is the decision that
was previously being made for them by default.

## Why nothing the guest writes is used before it is matched against a shape

The agent runs as the guest user, with `--dangerously-skip-permissions` and a
Bash tool. Every file the host CLI reads out of the guest is therefore a file
the agent can write: `~/.agent-box/runs/<runid>/status` is an ordinary file in
its own home.

That was not a theoretical concern. `--notify`'s watcher read that status file
and spliced the value into an `osascript -e` program as a double-quoted
AppleScript string literal. A double quote in the value closes the literal, and
what follows is parsed as AppleScript, where `do shell script` runs a command
**on the host, as the host user, outside the VM**. Reproduced on this machine:
the payload's `do shell script` created the file it named. The guest's
default-deny egress is irrelevant to it, because the fetch would happen on the
host; so is the token never touching the host, because the host's `~/.ssh` and
the blocklist the whole mount split exists to protect are both readable once
code runs there.

Two defences now, deliberately not one:

- **The shape.** `running`, `exit:stopped`, or `exit:` and digits. Anything else
  becomes `unknown`, and the offending value is reported as unrecognised rather
  than echoed, because echoing it is most of what makes it dangerous. The same
  discipline covers run ids (`%Y%m%d-%H%M%S`), session names and model names.
- **The interface.** `osascript` receives the text as an argument through
  `on run argv` and `--`, never as program text. Numeric comparisons on a
  guest-derived value use `case` patterns, never `[ -eq ]`, whose arithmetic
  evaluator word-expands an array subscript and so runs `$(...)` inside it.

Either alone would close today's hole. Both, because the first is a policy that
a later change could widen and the second is a property of how the call is made.

## Why a run records its own stop, instead of the stopper recording it

`agentbox stop-run` used to work the way it reads: send SIGINT, wait for the
status file to move, and if it moved, report what it now says. That was wrong
in a way nothing caught until a real run on a real box, and it is issue #14.

Claude Code 2.1.261 in `-p` mode **exits 0 when it is interrupted**. It says
what happened only in its result event:

```
20:38:53  result  error_during_execution  turns=3  cost=$0.0205  duration=21s  is_error=true
20:38:53  status  exit:0  done
```

So `agent-run.sh` recorded `exit:0`, the stop loop saw a status appear and
announced that the run had "ended by itself", and `runs`, `status --json` and
the summary all agreed it was `done`. Every one of them was reporting a stopped
run as a successful one.

Two things were wrong, and they need different fixes.

**The outcome is the CLI's verdict, not its exit status.** `agent-run.sh` now
reads `is_error` and `subtype` out of the result event and, when the process
exited 0 but the result says otherwise, records the run as failed and prints
one line saying why. A missing result event counts the same way: with
`--output-format stream-json` the CLI always emits one, so its absence means
the stream was cut off.

**The stop is recorded by the run, because only the run knows both halves.**
The stopper knows it asked; the run knows how it ended. Neither alone can tell
an interrupted run from one that happened to finish in the same second, and the
stopper is the one that cannot see the difference. So `run-ctl.sh stop` writes
`stop-requested` into the run directory before it sends any signal, and
`agent-run.sh`'s exit trap writes `exit:stopped` if that file is there and the
run did not end cleanly. The stopper then reads the answer rather than guessing
it, and "ended by itself" is reserved for the one case where it is true.

The alternative was to have the stopper write `exit:stopped` whenever it had
signalled and the run subsequently ended. That is the version the review round
already rejected for a different reason: it overwrites the record of a run that
finished on its own terms a moment before the signal landed. Both failures come
from the same mistake, which is inferring a run's fate from outside it.

## Why the stop is a marker beside the exit code, not a status instead of it

The first version of the fix above wrote `exit:stopped` over whatever code the
run had finished with. That looked tidy and lost two things.

It lost the reason a run failed. A run that failed on its own terms in the same
second as a stop was recorded as `stopped` with no exit code at all, and the
failure went with it.

And it lost a guarantee. `exit:3` is what the leak check writes when it found
the OAuth token in output that reaches the host, and `agentbox logs` refuses to
print a run whose status is exactly that. A stop that landed on a leaking run
replaced the 3, the refusal never fired, and the credential the exit-3 path
exists to withhold was printed to the terminal it exists to protect. The two
mechanisms were fighting over one field.

So the status file keeps the exit code, always, and the stop is a separate
marker file the run writes beside it. `run-format.py` derives the state from
the two: `exit:stopped` still means stopped, because the stopper's own fallback
writes it when the run never got to record anything; a marker beside any other
code means stopped as well; and `exit:3` means failed whatever else is there,
because the leak is the headline and nothing may reinterpret it.

The general rule is worth stating on its own: a value with downstream meaning
does not get overwritten to express something else. If two facts need
recording, record two facts.

## Why the Docker profile is opt-in per instance

Every instance could have Docker, Node 22 and Playwright's system libraries.
None of them is dangerous on its own, and the firewall now holds containers to
the same allowlist as the guest. The reason not to is that all three are large,
slow and attack surface: the Docker packages, containerd and the buildx and
compose plugins are a few hundred megabytes, `playwright install-deps` pulls in
most of a desktop's graphics and font stack, and both need the disk to be twice
the size before a single image is pulled. A box that exists to run one agent
against one repository of TypeScript should not carry a container runtime it
will never start.

So the profile is three flags on `create`, and it is fixed for the life of the
instance — the same reasoning as the mounts. "Can this VM run containers" is
answerable once, from the command that made it, rather than being a thing that
might have been turned on at some point. Sizing is the one exception:
`agentbox resize` exists because outgrowing a 60GiB disk is an ordinary event
and rebuilding the VM to fix it is not a reasonable answer.

## Why rootful Docker, not the rootless engine

Lima ships a `docker` template that installs the rootless engine, and rootless
is the better default nearly everywhere: the daemon runs as the user, a
container escape lands in an unprivileged account, and nothing needs
`CAP_NET_ADMIN`.

It cannot be used here, for a specific and checkable reason. Rootless Docker
does its networking inside a user network namespace with slirp4netns or
pasta, and populates **none** of the `DOCKER*` chains in the host namespace.
There is no `DOCKER-USER` to hook into, no `FORWARD` traffic to filter — the
container's packets appear on the guest's uplink as if the daemon's own process
had sent them, and the only thing standing between a container and the internet
would be the guest's `OUTPUT` chain, which is the daemon's, not the container's.
The egress allowlist would still hold at the outer boundary, but "which
container reached what" would be unanswerable and the per-container rules the
`AGENTBOX-FWD` chain expresses would have nowhere to live.

The rootful engine, from Docker's own apt repository, creates
`DOCKER-USER` and `FORWARD` jumps to it before anything else. That chain is
Docker's documented place for exactly this, and since Engine 28.0.1 it has no
implicit `RETURN`, so a rule placed there governs container traffic properly.

The cost is stated rather than hidden: the guest user is in the `docker` group,
which is root-equivalent on that guest. It changes nothing about the threat
model, because the guest user already has passwordless sudo — see the first
entry under "Limits and known weaknesses" in the README. The VM boundary is
what protects the host; the firewall is a guard rail against carelessness.

**And a cost that is new with containers, accepted rather than closed.** The
CLI is handed its credential in its environment, and everything it spawns for
the length of a run inherits it — `docker` and `docker compose` included. Two
paths follow. The obvious one is `docker run -e CLAUDE_CODE_OAUTH_TOKEN` or a
bind mount of the home directory, which a container process running as root
reads straight through the 0600 on the token file. The one worth naming because
nobody expects it is that `docker compose` interpolates variables into the
compose file from the CLIENT's environment: a compose file in `/work` with
`environment: [X=${CLAUDE_CODE_OAUTH_TOKEN}]` receives the real token without
anyone passing `-e` and without the agent doing anything that looks unusual.
Egress from that container is not a dead end either, because the allowlist
admits GitHub's whole web, api and git ranges — the trade-off recorded under
"Why DNS is restricted to the configured resolvers" and reachable by any
allowlisted host, container or not.

This is not closed, and the reason is that closing it properly means not putting
the credential in the environment at all, which is a change to how the CLI is
invoked rather than to the Docker profile. A `docker` wrapper that unsets the
variable is the cheap version and was rejected: PATH is the agent's to change,
so a wrapper it can step around is a rule that reads stronger than it is. What
holds instead is what has always held — the VM boundary, the egress allowlist,
and a token that is worth revoking rather than protecting. The README's Limits
list says so beside the `docker` group note.

The repository key is pinned. Docker's current install pages give the key's URL
and no fingerprint beside it, so provisioning fetches the key once, reads its
fingerprint with `gpg --show-keys`, and refuses to point apt at the repository
unless it is `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` — the
fingerprint of "Docker Release (CE deb) <docker@docker.com>", rsa4096, created
2017-02-22, read back from that URL in a guest on 2026-09-05. That is a pin
against a future substitution, not proof of provenance today: the first fetch
was trusted, and it is the pin that makes the second and every later one
checkable. Saying so is the point.

Playwright's version is pinned for the same reason and it is the weakest of the
three, so it is worth being exact about what it buys. `npx playwright
install-deps` runs as **root**, at the one moment provisioning has set all three
policies to ACCEPT and flushed the AGENTBOX chains, in a guest with read-write
access to the host's real repository directory at `/work`. `playwright@latest`
resolved at provision time and executed whatever had been published that day;
`playwright@1.63.0` executes a version that cannot be changed retroactively. It
is a pin, not a checksum — npm's own integrity metadata is what stands behind
the bytes — and it governs only the apt system libraries, since the browser
builds come from each repository's own Playwright on first use. 1.63.0 was the
`latest` dist-tag on registry.npmjs.org, read on 2026-09-05. Raise it
deliberately.

## Why the firewall owns three chains rather than the whole table

The old ruleset was applied with `iptables-restore` and no `--noflush`, which
replaces the entire filter table in one transaction. That was a virtue while
agent-box was the only thing writing rules. With Docker installed it is a
defect, and a quiet one.

Docker creates six chains — `DOCKER`, `DOCKER-USER`, `DOCKER-FORWARD`,
`DOCKER-CT`, `DOCKER-BRIDGE`, `DOCKER-INTERNAL` — and **does not put them back
if something else removes them**. Only a daemon restart does. So the
whole-table restore would have cut every container off the network on the first
15-minute timer tick after the daemon started, and left it that way: the
symptom is a compose stack that worked for twelve minutes and then did not,
with nothing in any log to say why.

The fix is to own three chains and nothing else:

| chain | reached from | holds |
|---|---|---|
| `AGENTBOX-IN` | `INPUT` rule 1 | loopback, established, port 22 from the gateway |
| `AGENTBOX-OUT` | `OUTPUT` rule 1 | the guest's own egress allowlist |
| `AGENTBOX-FWD` | `DOCKER-USER` rule 1 | the same allowlist, for container traffic |

and to declare only those three, plus the three policies, in a restore file
applied with `--noflush`. Two behaviours make that work, and both were checked
in a guest rather than taken from documentation:

- declaring a **user** chain (`:AGENTBOX-OUT - [0:0]`) under `--noflush`
  replaces its contents outright, so a rebuild is still one atomic swap and
  never duplicates a rule;
- declaring a **builtin** chain (`:INPUT DROP [0:0]`) under `--noflush` sets its
  policy and leaves its rules alone.

That asymmetry is the whole reason the accept rules moved out of `INPUT` and
`OUTPUT` into chains of our own. Rules left directly in a builtin chain could
not be rebuilt in place: appending them again each run would duplicate them,
and flushing the builtin first would remove `FORWARD`'s jumps to Docker's
chains.

The jumps themselves are placed with `-C || -I`, inserted before any duplicate
is deleted, so there is no instant in which `DOCKER-USER` does not reach our
rules. `AGENTBOX-FWD` begins with `! -o <uplink> -j RETURN`: traffic that is not
leaving by the default route's interface is container-to-container or a
published port arriving from the other side, neither of which is egress, and
`DOCKER-FORWARD` is the chain that should decide it.

`iptables -F` with no argument has the same defect as the whole-table restore
and appears in two more places — the provisioner opening the network for a
download, and the hard-close path. Both now flush the three builtin chains and
our own three, never the table.

**What this does not cover: macvlan and ipvlan.** The whole container-egress
argument rests on `FORWARD` jumping to `DOCKER-USER` before anything of
Docker's own. That is true of bridge networks, which is every network Docker
creates by default and every network this profile was built for. It is not true
of `macvlan` or `ipvlan`: those attach the container to a sub-interface of the
parent NIC, so the packets leave through the parent without traversing the
host's `FORWARD` chain at all. `DOCKER-USER` never sees them, and therefore
neither does `AGENTBOX-FWD`.

A compose file that declares such a network — a normal thing to do when a
service needs a routable address of its own — would have unfiltered egress, and
`agentbox firewall-check` would still report every check PASS, because its
container probe runs on a bridge network. Refusing those drivers needs an
authorization plugin or a wrapper, and both are more machinery than the risk
justifies on a box whose user already has passwordless sudo. So it is written
down instead: the firewall is a guard rail against carelessness, and this is
one kind of carelessness it does not catch. The VM boundary is what protects
the host, and it is unaffected.

**And one rule that is inbound, in a chain that is otherwise about egress.**
`AGENTBOX-FWD` rule 1 drops NEW connections arriving on the uplink. Without it
the `! -o <uplink> -j RETURN` below is symmetric in a way its reasoning is not:
`docker run -p 8080:80` publishes on 0.0.0.0, Docker DNATs the inbound packet
in PREROUTING, and it is then FORWARDed rather than INPUTed — so it never meets
the `INPUT DROP` policy that implements "nothing the guest listens on is
reachable from outside it", and the RETURN hands it to `DOCKER-FORWARD`, which
accepts published-port traffic by construction.

Measured, and the measurement is worth recording because it cuts both ways. On
this Mac the guest sits behind Lima's usernet, and the host has no route to the
guest's address at all — `curl 192.168.5.15:4999` from the Mac times out with
or without the rule. So the rule closes nothing that is open today. It is here
because the invariant is stated in three places as a property of the box, and
it was in fact a property of the network Lima happened to give it: a
`networks:` entry added later, or a vmnet-shared configuration, would have
made the claim false with nothing in the repository changing. The rule makes it
true at the boundary that the claim is about.

`--forward` is unaffected, and structurally rather than by luck: Lima serves a
forwarded port over ssh, so the connection to it is opened by sshd *inside* the
guest and leaves through `OUTPUT`, never crossing `FORWARD` from the uplink.
Verified with the rule in place — a container published `-p 4998:80` on a box
created with `--forward 4998` still answers on the Mac at `127.0.0.1:4998`,
while the same container on a port that was not named does not.

## Why a probe that needs the internet cannot decide whether the box is safe

`verify()` is the last thing `init-firewall.sh` does, so its return value is the
unit's exit status. Provisioning restarts that unit as a bare command under
`set -euo pipefail`, and the EXIT trap retries once and then hard-closes the
guest. That cascade is sound when every check is an assertion about the ruleset:
those are read from the kernel, need no network, and are true or false
regardless of what any remote host is doing.

The Docker profile added three checks that are not like that. Two launch a
container, and the third used to pull `alpine:3` from Docker Hub. Docker Hub
rate-limits anonymous pulls at 100 per six hours per address. So a `--docker`
create on a busy afternoon could end like this: the pull returns 429, two checks
FAIL, `verify()` returns 1, the unit fails, `systemctl restart` returns
non-zero, `set -e` aborts provisioning, the EXIT trap restarts the unit, it
fails identically, and the guest is left on loopback and ssh only. A ten-minute
`agentbox create` exits non-zero and hands back a new VM with no egress —
because a registry had a bad minute.

Two changes, and the principle is the second one.

**Nothing in this unit pulls.** If `alpine:3` is not present locally the two
container probes print SKIP with that reason. Using the pull as a registry test
was a genuinely nice idea and it belongs in the smoke test, where a failure is a
test result rather than a boot outcome. It also removes a second problem nobody
would have connected to it: the timer ran `verify()` every fifteen minutes, so a
box whose operator followed this project's own advice and ran
`docker system prune -af --volumes` would have re-pulled the image four times an
hour, for ever.

**And the checks that leave the machine are advisory.** They print `WARN`, they
are counted separately, and they do not touch the exit status; only the ruleset
checks do. The distinction is worth stating as a rule, because it will come up
again the next time someone adds a check here: *this function answers "is the
ruleset what it should be", not "is the internet working".* The two questions
have different failure modes and only the first one should be able to close a
box.

What is deliberately NOT advisory is `docker-user-jump`. It reads the live
ruleset like every other fatal check, needs no network, and is only evaluated
once `docker info` has answered — so if it fails, containers really are
unfiltered, and that is exactly the kind of thing this unit exists to refuse to
be quiet about.

**The line is the direction of failure, not local versus remote.** The first
version of this entry said "a probe that needs the internet cannot decide
whether the box is safe", moved the Docker probes, and left five outbound
checks fatal — so the cascade it described was still reachable, now through
`api.anthropic.com` instead of Docker Hub. Stated properly:

- A check is **fatal** when it can only fail on affirmative evidence that the
  ruleset is wrong. `literal-ip-denied`, `foreign-dns-denied` and
  `egress-denied` all send packets and all three are fatal, because the only
  way they fail is by something ANSWERING that should have been refused. No
  outage produces that.
- A check is **advisory** when it fails on an absence. `anthropic-allowed` and
  `github-allowed` are absences, and an outage, a rate limit, a rotated CDN
  address or a captive network all produce them identically.

`docker-egress` was the case that showed the first version had the wrong idea,
because it fails in both directions and was given one treatment. A container
that could not be tested at all is inconclusive — a warning. A container that
REACHED `example.com` is a containment breach, is a fact about this box that no
remote condition can fabricate, and is fatal. Those are three outcomes and
`container_probe` already returned three values; the code was collapsing them
into two.

## The check that the allowlist permits something, without asking the internet

Applying that rule left a hole, and it is worth naming because it is the
predictable cost of getting the rule right. Once the outbound probes became
advisory, **no fatal check asserted that the allowlist lets anything through.**
`allowlist-rule` looks like it does and does not: it greps the chain for a rule
referencing the set, which is exactly as true of a set holding nothing.

The state is reachable without any race. One name that fails to resolve is a
journal WARN and a `continue`, and `resolved_any` is satisfied by a single name
out of nineteen, while the GitHub ranges are added unconditionally. So a rebuild
during a partial DNS failure could swap in a set holding the GitHub ranges and
almost nothing else, exit 0, and leave the unit active — with `firewall-check`
exiting 0, `agentbox status` reporting `drop`, and an overnight run starting at
02:30 and dying on its first call to the model API. Every signal green on a box
where no agent can work.

Two changes close it, and both keep the direction-of-failure rule intact.

**The rebuild records what it resolved.** One line per name in
`/run/agent-box-firewall-resolved`, written only once the swap has happened, so
the file can never describe a set that is not live. `verify()` then asks a
question that is entirely local: does the live set still contain every address
the last rebuild recorded for `api.anthropic.com`? Both halves are readable from
the kernel, and it fails only on affirmative evidence — the file says these went
in, and `ipset test` says they are not there.

**And that one name's resolution failure is a rebuild failure.** Not a WARN and
a `continue`. Without `api.anthropic.com` the box cannot do the single thing it
exists to do, so the rebuild refuses the swap, keeps the standing ruleset with
its previous addresses, and exits non-zero — visible, and retried on the next
tick.

### An emptied allowlist is self-sealing, which the test had to learn

Worth recording because the obvious repair does not work. The smoke empties the
live set and asserts the new check fails; the first version then simply
restarted the unit to put the box back, and the restart failed. It has to: the
rebuild needs `api.github.com` for the meta ranges, `api.github.com` is only
reachable through the ipset, and the ipset is what was emptied. A box in that
state cannot rebuild its way out on its own.

That is the same property the hard close has, and the recovery is the same
shape: open egress by hand, then rebuild. There is a second step to it that is
easy to get wrong, and the test got it wrong once before measuring it: **the
policy is not what refuses the packet.** `AGENTBOX-OUT` is jumped from `OUTPUT`
rule 1 and ends in REJECT, so a rejected connection never reaches the `OUTPUT`
policy at all, and `iptables -P OUTPUT ACCEPT` on its own changes nothing. The
chain has to be flushed as well:

```
sudo iptables -P OUTPUT ACCEPT
sudo iptables -F AGENTBOX-OUT          # not -F on its own: that takes Docker's chains
sudo systemctl restart agent-box-firewall.service
```

Which is precisely what `open_network_for_provisioning` does, for precisely this
reason. Anyone who empties that set on a real box needs both lines, and the
recovery text the hard close prints is right to name the chain flush rather than
only the policy.

## Why `firewall-check` rebuilds, having only verified

`agentbox firewall-check` ran `init-firewall.sh --verify-only`, which returns
before the allowlist is read, before any name is resolved, and before the ipset
is swapped. Four sentences in this repository — two of them in `daily-use.md`,
one here, one in `allowlist.base` — offered the command as the fix for a
problem that only a rebuild solves:

- a name added to `allowlist.local`, which will not be in the set for up to
  fifteen minutes;
- a CDN that handed out an address which was not in the set when it was last
  resolved, which is the `cdn.playwright.dev` case argued at length above.

In both, the operator ran the command, watched every line print PASS, retried,
and was refused again with nothing to explain it. The documentation was not
describing the code; it was describing what the command obviously ought to do.

So the command now does it. **How it does it matters more than that it does.**
The obvious implementation — exec the whole script under sudo — was written
first and was wrong in three ways at once, all of which come from bypassing
systemd:

- **It raced the timer.** The timer rebuilds by restarting the unit, which
  serialises against itself because a `Type=oneshot` already running will not
  start twice. A direct exec is invisible to that. Both paths then destroy and
  refill one fixed ipset name, `allowed-domains-new`, so one run's
  `ipset destroy` lands on the other's half-filled set. The loud outcome is a
  failed unit, which blocks every agent run. The quiet one is worse: whoever
  wins the swap with a nearly empty set leaves the live allowlist short of most
  of its addresses while every check still prints PASS.
- **It could not clear a failed unit.** `guest/lib.sh` gates every run on the
  unit being active. An operator whose unit had failed would repair the ruleset,
  watch every line print PASS, and still be told "the egress firewall is not
  active" by `agentbox run`. Three signals disagreeing is worse than one bad
  signal.
- **It could print nothing at all.** A full run exits at its first failure —
  the `api.github.com` fetch, the schema check, a resolution pass — all of
  which come before `verify()`. A diagnostic tool that goes silent exactly when
  the network is broken is a diagnostic tool for the case you do not have.

So `firewall-check` restarts the unit and then runs `--verify-only` as a
separate step. That rebuilds, serialises through systemd, clears a failed unit,
and prints the table whether or not the rebuild worked, saying which happened.
`--verify-only` remains the right thing for any caller that must not depend on
DNS or on `api.github.com`.

**And the script takes a lock of its own**, `flock` on
`/run/agent-box-firewall.lock`, held by the rebuild and by the Docker hook.
Driving the unit is the fix for the paths this repository controls; the lock is
what protects a box where someone runs the script by hand. Every `iptables` and
`iptables-restore` call also carries `-w 5`, which covers the xtables lock
independently of either.

## Why docker.service gets a drop-in, and why the socket is owned by name

Two lines in `/etc/systemd/system/docker.service.d/agent-box-firewall.conf`,
for two different failures.

`After=agent-box-firewall.service` orders the daemon behind the firewall at
boot, so `AGENTBOX-FWD` exists before `DOCKER-USER` does.

`ExecStartPost=…/init-firewall.sh --docker-hook` closes the window a restart
would otherwise open. A daemon restart recreates whatever of its chains are
missing; if the jump were left to the 15-minute timer, a `systemctl restart
docker` at 12:01 would leave containers reaching anything they liked until
12:15. As an `ExecStartPost` the hook runs as part of starting the daemon, so
`systemctl restart docker` does not return until the jump is back. The hook
does one thing and does not rebuild anything, because a rebuild needs DNS and
`api.github.com` and must never be on the critical path of starting a daemon.

A second drop-in, on `docker.socket`, names the guest user as the socket's
owner. `usermod -aG docker` is also done and is not enough: supplementary
groups are fixed when an SSH connection authenticates, and Lima multiplexes
every `limactl shell` over one long-lived connection opened before provisioning
ran. Verified rather than assumed — after `usermod`, a fresh `limactl shell`
still reported the old group list and `docker info` said "permission denied".
The group would only take effect after a stop and start, which means the box
you just built to run Docker cannot run Docker. Lima's own docker template sets
`SocketUser` for the same reason.

**The ordering that fixes one problem creates another, and the second one
deadlocks the boot.** `After=agent-box-firewall.service` means that while the
firewall unit runs at boot, dockerd has not started. `docker.socket`, however,
is already listening — systemd socket activation is independent of the service
job. So the container probes at the end of `verify()` connected to that socket,
systemd queued a `docker.service` start job that could not run until the
firewall unit finished, and the firewall unit waited for a reply that could
never come. Measured on a `--docker` box, ten minutes after a restart:

```
$ systemctl list-jobs
150 agent-box-firewall.service           start running
152 docker.service                       start waiting
2   multi-user.target                    start waiting

$ ps -eo pid,ppid,etime,args
685   1    10:44  /bin/bash /opt/agent-box/guest/init-firewall.sh
1609  685  10:39  docker image inspect alpine:3

$ systemctl show agent-box-firewall.service -p TimeoutStartUSec
TimeoutStartUSec=infinity
```

Nothing would ever have broken it: the unit is a oneshot with no start timeout,
`multi-user.target` never came up, and Lima's own `agentbox start` therefore
timed out after ten minutes waiting for the guest to be ready. Downstream,
`guest/lib.sh` refuses to run an agent unless the firewall unit is active, so
the box also reported itself unprotected while being, in fact, protected.

Two changes, and the second is the one that generalises. The container checks
are now gated on a *reachable daemon* — `timeout 5 docker info` — rather than on
an installed binary, and print `SKIP` with the reason when it is not up, because
at boot that is the correct and expected state: the jump is installed moments
later by the `ExecStartPost` hook. And every call into the container runtime
from this unit is bounded by `timeout`, on the principle that the firewall must
never be held open by the runtime it exists to constrain. After the change the
same restart brings the unit up in under three seconds with three SKIP lines,
and a second run once dockerd is up reports all three as PASS.

## Why there is still one Lima template, and no generated file per instance

`--docker`, `--playwright` and `--rosetta` reach the guest as template
parameters, which Lima expands in the provision script. `--forward`, the
Rosetta setting and the sizing cannot work that way, and the reason is worth
recording because it looks like it should.

Lima parses the template as YAML **first** and expands `{{.Param.x}}`
afterwards, in a handful of string fields only. So `enabled: {{.Param.rosetta}}`
is a YAML parse error before any parameter exists, `enabled: "{{.Param.rosetta}}"`
parses but is never expanded and reaches the VM as that literal string, and
`- guestPort: "{{.Param.port}}"` is rejected outright because `guestPort` is an
integer. All three were tried against `limactl validate` rather than reasoned
about.

The obvious next step is a derived per-instance YAML written under
`~/.config/agent-box/instances/`, and it is not needed: `limactl create` takes
`--rosetta`, and `--set` with a yq expression, which together express both. So
`agentbox create` passes `--set '.cpus = N | .memory = "…" | .disk = "…"'`,
adds `--rosetta` when asked, and prepends port-forward entries with
`--set '.portForwards = [{"guestPort": N}] + .portForwards'`. Prepends, because
the template's two catch-all entries ignore every port and Lima takes the first
entry that matches.

The result keeps the property that mattered: **one template, in the repository,
readable as a file**. A generated per-instance YAML would have put the real
configuration of a running VM somewhere nobody reviews, and would have needed
its own regeneration story every time the template changed. `agentbox resize`
uses the same mechanism against an existing instance with `limactl edit --set`.

## What `--forward` gives up

Every other design decision here points one way: nothing the guest listens on
is reachable from the host. `--forward` is the exception, and it exists because
watching a browser test against a stack running in the VM is otherwise
impossible — you cannot look at `http://localhost:3000` if nothing is
forwarded.

It is a widening in the direction the rest of the file spends its effort
closing, so it is opt-in per port, per instance, fixed at create time, warned
about in one line at create, and recorded in the instance summary.

**Which guest sockets a forwarded port actually reaches, measured.** The
prepended entry is `{"guestPort": N}` and takes Lima's defaults, so the answer
is not obvious and the failure mode is silence: a port that does not match
falls through to the template's catch-alls, which are `ignore: true`, and
nothing on either side says why the page will not load. On a `--docker` box
created with `--forward 4998`, with a container published each way:

| the guest socket is bound to | in `--forward`? | `127.0.0.1:N` on the Mac |
|---|---|---|
| `0.0.0.0` — `docker run -p N:80`, the default | yes | answers |
| `127.0.0.1` — `docker run -p 127.0.0.1:N:80` | yes | answers |
| the guest's own address — `-p 192.168.5.15:N:80` | yes | **does not answer** |
| any of the above | no | does not answer |

So the ordinary habit works and only the third form is a trap, which is the
opposite of what the entry's `guestIP` default suggests. `agentbox create` now
prints that as a second line beside the widening warning, because a rule that
holds three times out of four is exactly the kind that gets misremembered. What it
grants is narrow: a process on the Mac can connect to that one guest port at
`127.0.0.1`. It grants the guest nothing new in the other direction. The
alternative considered and rejected was forwarding on demand from a separate
subcommand, which would have made "what is exposed right now" a question with a
time-varying answer — the same thing the fixed-mounts rule exists to avoid.

**Amended: the host side of a forward is now checked, and diagnosable.** The
table above is about which *guest* socket a forward reaches. The other half of
the silence was the host end: Lima cannot bind a host port something else holds,
and says nothing useful when it fails, so a forward could be dead from the
moment the box started. `create` and `start` now probe each recorded forward
before they do anything else and refuse, naming the port and the process holding
it; `agentbox ports` reads both ends and says which is quiet. That is a new
behaviour, not a restatement. The rejection of forwarding on demand stands
exactly as written above, for the reason written above — what was missing was
never the mutation, it was the diagnosis.

## Why the allowlist resolves through two paths, and more than once

The allowlist is names; the ipset is addresses. Something has to turn one into
the other, and `dig` on its own turns out to be the wrong instrument.

**`dig` does not resolve the way anything else does.** It sends its query
straight to the nameserver in `/etc/resolv.conf` — on this guest, Lima's host
resolver on the gateway. Every other program goes through glibc to
systemd-resolved on `127.0.0.53`, which keeps its own cache and its own idea of
which address the name has. For a name with eight A records the two answers
overlap enough that nothing is noticed. For `cdn.playwright.dev` — an Azure
Front Door endpoint that answers with exactly **one** A record, on a near-zero
TTL — they disagreed outright, in the same second, in a guest:

```
$ dig +short A cdn.playwright.dev        # what the firewall pinned
150.171.109.113
$ getent ahostsv4 cdn.playwright.dev     # what curl would use
150.171.109.70
```

So the firewall allowlisted an address nothing was going to connect to, and
rejected the one everything did. The symptom is a host that is plainly on the
allowlist being refused, which is the most misleading failure this design can
produce: it looks like the allowlist file is wrong when it is right.

The fix is to resolve the way the applications resolve. `getent ahostsv4` goes
through the same NSS path curl, Node and apt do, and its result is unioned with
`dig`'s, which still contributes the fuller multi-address answers that `getent`
returns one line at a time. Measured in a guest after the change: five
consecutive requests to `cdn.playwright.dev` under the standing deny all
connected, all to `150.171.109.66`, the address both paths now agree on.

**And a pass count that defaults to one, having been three.** A CDN hands out
part of its pool per query, so a single lookup pins a single slice for fifteen
minutes. Several passes over the whole list, spaced past the TTL, collect more
of it. That was implemented, measured, and then turned down to one pass,
because the measurement said so:

| resolution passes | first boot of a plain instance |
|---|---|
| 1 | 50-59s, across four runs |
| 3 | 611s, past Lima's own start budget, so `agentbox create` failed |

The cost is not the DNS traffic. It is `getent`: it takes no timeout of its own
and NSS blocks while systemd-resolved is still coming up, which is exactly when
this script first runs. The lookup is now bounded with `timeout`, and the extra
passes — which on the case above changed nothing, because the two-path union
had already fixed it — sit behind `AGENT_BOX_RESOLVE_PASSES` for whoever meets
a CDN that needs the breadth and can afford the boot time.

**This is a mitigation, not a guarantee, and pretending otherwise would be the
real defect.** An address that enters a pool between rebuilds still fails.
Three things follow:

- A rejected connection to an allowlisted CDN is worth retrying before it is
  worth debugging. `agentbox firewall-check` forces a rebuild and refreshes the
  set.
- The smoke test's reachability checks retry up to six times each, the same
  shape a real downloader has. A name that is genuinely absent still fails all
  six, and the check that found this in the first place is the one that curls
  every newly allowlisted name from inside the guest *under the standing deny*
  — provisioning downloads with the firewall stopped, so nothing else would
  ever have noticed.
- Two alternatives were considered and not taken. Widening to the CDN's
  covering prefix (`150.171.108.0/22` for that Front Door pool) allowlists
  every other tenant on the same CDN. Keeping addresses with an `ipset`
  timeout instead of replacing them wholesale would accumulate a pool over
  hours, but it trades the atomic swap — the property that makes a rebuild safe
  under the standing deny — for an hour-long tail of addresses that are no
  longer the allowlisted host's.

### What the pool actually does, measured

The earlier characterisation had `cdn.playwright.dev` answering with one address
that the two-path union then agreed on. That was true on the day. It is not the
steady state. Six lookups from the host over thirty seconds, on 2026-09-05:

```
19:42:06  150.171.109.66
19:42:11  150.171.109.118
19:42:16  150.171.109.66
19:42:21  13.107.253.41  13.107.226.41     <- a different Front Door pool entirely
19:42:26  150.171.109.116
19:42:32  150.171.109.115
```

Five addresses in half a minute, across two unrelated /16s. No single resolution
pass can hold that, which means no snapshot-based allowlist can. Both rejected
alternatives get worse in the light of it, not better: the covering prefix is
now *two* prefixes, one of which (`13.107.0.0/16`) is a large slice of
Microsoft's edge; and an `ipset` timeout long enough to accumulate this pool is
long enough to keep a meaningful tail of addresses that have moved on to some
other tenant.

### So the smoke's runtime check for this one host is advisory

The check was asserting something the box does not promise. What is promised is
that the name is on the allowlist, and that Playwright's browsers are fetched
during provisioning, when the network is open. Reachability of that host at an
arbitrary later moment is not a property of this design, and an agent that needs
a browser later has the documented remedy — `agentbox firewall-check`, which
rebuilds and re-pins.

So it prints WARN, counted separately from passes and failures, and it prints it
only after the retry has run that remedy and it did not help. `api.anthropic.com`
and `github.com` stay hard failures: they are not behind a pool that behaves
like this, and the box does promise them.

### The structural fix, for later

A snapshot allowlist and a name that rotates faster than the snapshot is a
design mismatch, not a tuning problem, and there is a known shape that resolves
it: **make the set follow resolution instead of polling for it.** `dnsmasq` can
add an answer's addresses to an ipset as it resolves the name —
`ipset=/cdn.playwright.dev/allowed-domains` — so the guest's own lookup is what
authorises the address it is about to connect to. The window between resolving
and connecting is milliseconds rather than up to fifteen minutes, and it works
for every rotating host without naming any prefix.

It is not free and that is why it is recorded rather than done. It puts a
resolver in the guest that everything must go through, it needs the atomic-swap
rebuild to coexist with entries dnsmasq adds between rebuilds (an ipset with a
timeout for the dnsmasq-added half, alongside the swapped base set, is the
obvious shape), and it makes the firewall depend on a daemon that can itself
fail. Worth evaluating as its own piece of work, against the current behaviour,
which is: correct, occasionally inconvenient for one host, and honest about it.

### Superseded: this was built, and it works

The limitation above is no longer the behaviour. dnsmasq now runs in every box
and feeds the set as the guest resolves, which is what the paragraph proposed;
what follows is what the building taught, because two of the three costs it
predicted turned out differently.

**The resolver everything must go through.** systemd-resolved was not removed.
`/etc/resolv.conf` on this image is a symlink to its stub, and Lima and
cloud-init both rewrite resolver state on boot, so a script that fights them
for that file is a script that loses on some future boot. Instead resolved
keeps the stub at `127.0.0.53`, its upstream becomes dnsmasq at `127.0.0.1`,
and **its own cache is turned off**. Nothing else in the guest has to know, and
there is no file to fight over.

`Cache=no` is not a performance choice, it is the mechanism: an answer resolved
by resolved from its own cache never reaches dnsmasq, so nothing would be added
to the set and the connection would be refused.

**Coexisting with the atomic swap.** The set is now `hash:net timeout 3600`.
The rebuild adds everything it knows with `timeout 0`, which means permanent;
dnsmasq's additions take the default and age out an hour later. That makes the
two populations distinguishable with no bookkeeping, which is what the swap
needs.

The spec left the swap's behaviour open and preferred the cheap option — let a
rebuild forget dnsmasq's entries and let the next lookup put them back, if
lookups are cheap. **The measurement says do the other thing.** Lookups are
cheap; the problem is that there is often no lookup at all:

```
query[A] api.github.com from 127.0.0.1
cached api.github.com is 140.82.113.6      <- answered from dnsmasq's own cache
entries in the set afterwards: 0            <- and NOT re-added
```

dnsmasq feeds the set when it FORWARDS an answer and not when it serves one
from cache. Forgetting on every rebuild would therefore black-hole a
suffix-matched host for the rest of its TTL, and longer if the application
caches too. So the rebuild copies the live set's timed entries into the new set
before the swap, with their remaining time. Measured after the change: `Carried
67 resolver-added address(es) across the swap`, and the address that a
suffix match had added was still there and still reachable.

**The daemon that can itself fail.** It can, and the direction it fails in is
the safe one. With dnsmasq stopped, nothing resolves at all, so the box is
closed to everything reachable by name rather than open to anything. Measured:
`www.iana.org no longer resolves`, `curl http=000`, and verification says
`FAIL resolver-up  dnsmasq is NOT running: nothing will resolve, so the box is
closed to everything by name`. A fatal check rather than a warning, because a
stopped daemon is a local fact and not a remote absence.

What has not changed: the rebuild still pre-resolves every exact name, so a box
works from the moment it boots rather than from its first lookup.

## Why an egress mode per box, chosen at create

Three modes, one per box, and the choice is made once when the box is made.
Three alternatives were available and each is worse in a specific way.

**A global setting** would be a single value on the host that every box reads.
It is the least work and the most dangerous: the reason to open a box is always
a particular repository on a particular afternoon, and a global that was
loosened for that repository stays loosened for the next one, which nobody
re-reads the config before creating.

**A runtime flag** — `agentbox run --egress open` for one task — is worse
still. It puts the decision at the moment of most impatience, when something
has just failed and the flag is the quickest way past it. A box's reach should
not be a thing you can change by pressing up-arrow and editing the line.

**No modes at all**, which is where this started, is not tenable once the box
is aimed at ordinary test automation against environments the operator names.
Deny with exact hostnames is right for an unattended agent on someone else's
code and wrong for an engineer who knows exactly which staging environment they
mean; refusing them the choice just means they stop using the box.

So: per box, at create, recorded in two places — `/etc/agent-box/egress-mode`
in the guest and `~/.config/agent-box/instances/<name>` on the host, so
`status` can answer for a box that is not running. `agentbox egress` changes
it, which is a deliberate act on a named box, and it rebuilds and re-verifies
on the spot so that the change is either true or reported as failed.

**And there is no default.** `create` refuses without `--egress` and prints the
three options. A default nobody chose is the one people forget they have, and
the failure is silent in the direction that matters. An operator who wants one
writes `egress: deny` in their own config, and then create tells them which
mode it took and which file it came from — a default you can see is a different
thing from one you inherited.

Provisioning writes the guest's copy exactly once. Lima re-runs the provision
script on every start with the parameters the box was CREATED with, so writing
it unconditionally would silently revert a deliberate `agentbox egress` at the
next restart.

## Why observe logs and allows, rather than logs and denies

An "observe" mode that logged and then denied would be a deny mode with better
diagnostics. That is a useful thing, but it is not the thing that is needed:
the question observe exists to answer is *what does this repository's test
suite actually reach for*, and you cannot answer it by watching the first
request fail. A suite that cannot reach its staging API does not go on to tell
you about the font CDN and the telemetry endpoint behind it; it stops.

So observe allows. The cost is real and is stated plainly at create, when the
mode is changed, and on the first line of every `run` and `session`: while a
box is in observe mode it can reach anything, and the only thing standing
between a repository's contents and the internet is the VM boundary and the
fact that someone is going to read the log.

The log is `-j LOG` with a fixed prefix rather than NFLOG. Both load on this
image and NFLOG is the more modern target, but reading it needs a userspace
collector — another package, another daemon, another thing to fail — while LOG
lands in the kernel ring buffer and therefore in the journal, where
`journalctl -k` already reaches it. It is rate-limited to 60 lines a minute
with a burst of 30, and the limit is on the LOG rule only: the ACCEPT after it
is unconditional, so a busy agent loses log lines and never loses packets.

Two things make the log worth more than a list of addresses. dnsmasq runs with
`log-queries` in observe mode only, so `egress-log` can say which name resolved
to each address — the packet filter never sees a name, and this is the only
place it exists. And `--as-allowlist` emits the names directly while commenting
out the bare addresses, because an address the guest never resolved is a
judgement the operator has to make rather than one the tool should make for
them.

### The rules the feed has to obey, and why each is a rule

Four constraints came out of building this, and each is the kind that reads as
a detail and is actually the whole mechanism.

**Cache TTL strictly below entry TTL, always.** dnsmasq feeds the set when it
FORWARDS an answer and not when it serves one from its own cache. So if the
cache outlived the set entry there would be a window — up to the difference
between them — in which the name still resolves, nothing is re-added, and the
host has silently gone dark on a box that looks healthy. `max-cache-ttl=900`
against an entry lifetime of 3600 leaves three-quarters of the entry's life as
margin. Change one and you must change the other.

**Exact names are never fed.** `ipset=/example.com/set` matches `example.com`
and every subdomain of it, so feeding exact names turned every line in
`allowlist.base` into a wildcard for its subtree: `api.anthropic.com` would
have admitted `anything.anthropic.com` the moment something resolved it. Only
suffix lines are fed. A host that genuinely needs the feed says so by being
written with a leading dot, and pays the subtree cost knowingly —
`.cdn.playwright.dev` and `.storage.googleapis.com` are the two, and both
comments say why.

**The resolver's addresses live in a set of their own.** One set with two
populations distinguished by their timeout was the first design. It made
removal impossible — a rebuild carried the old addresses forward for ever, so
deleting a suffix from the allowlist did not delete the reach it had granted —
and the read-then-swap that preserved them had a window in which an address
added between the read and the swap was lost. Two sets referenced by the same
accept rule have neither problem: the rebuild owns one and replaces it, dnsmasq
owns the other, and removing a suffix flushes it. The cost is one re-lookup for
the suffixes that remain, which is the cheaper mistake.

**The resolver's configuration is part of the allowlist, so it is verified.**
dnsmasq decides which addresses enter the set; a dropped `ipset=` line silently
stops a suffix working and an added one silently admits a subtree. So the file
is written by the rebuild, is the only configuration source dnsmasq reads
(`conf-file`, and the file is checked for `conf-dir` and friends), and
`verify()` compares a hash of its feed rules against one the rebuild recorded,
checks the daemon is actually reading that file, and runs `dnsmasq --test`.

### What the feed cannot protect against

`stop-dns-rebind` refuses an upstream answer that names a private or loopback
address, which closes the obvious version: an allowlisted suffix answering
`10.0.0.1` and thereby making the hypervisor gateway reachable.

What it does not close is a poisoned or hostile answer that names an ordinary
public address. The guest resolves through the host's resolver over a path with
no DNSSEC validation, so an answer that arrives is believed, and believing it
now writes a durable allowlist entry rather than only misdirecting one
connection. The blast radius is bounded and worth stating exactly: one address,
for one hour, reachable from a VM that has no credential on it but the token.
It is accepted rather than fixed because fixing it means validating DNSSEC in
the guest, which is a resolver project rather than a firewall one.

## Why `open` does not touch the FORWARD policy

`open` sets the OUTPUT policy to ACCEPT and makes `AGENTBOX-OUT` and the egress
leg of `AGENTBOX-FWD` accept. It leaves `FORWARD` at DROP, and the distinction
is not pedantry.

The first version set `FORWARD` to ACCEPT too, which reads like the same idea
and undoes a different one. `AGENTBOX-FWD` deliberately RETURNs anything not
leaving by the uplink, so that Docker's own chains — including the isolation
between its networks — remain the last word on container-to-container traffic.
With the policy at ACCEPT, a packet that falls off the end of those chains is
accepted by the policy instead of dropped, and that isolation stops being
enforced. Open means this box stops judging EGRESS. It does not mean the kernel
stops applying what Docker asked for.

## Why the failure path has to know the mode

`fail_closed` had one behaviour, and it was right for one mode out of three.

In `open`, a rebuild that failed — a GitHub meta fetch on a bad afternoon —
slammed the box shut to loopback and ssh. That is not a safer version of what
the operator asked for; it is a different box, silently, because something
unrelated to their choice went wrong. The open ruleset is now left as it is and
the failure is logged.

In `observe`, the check for a standing ruleset reads the OUTPUT policy, which
observe also sets to DROP — so the failure path took the "the previous deny
ruleset is left in place" branch and said *deny* about a box that logs and
permits everything. The ruleset was correct and the sentence was false, which
is worse than either, because the sentence is what somebody acts on. It now
names the observe ruleset for what it is.


## Why the healing loop lives in the guest, and stops where it does

The point of a self-healing run is a box that recovers with nobody at the host.
So the loop is guest-side: a failed run starts its own follow-up from its exit
path, through `run-ctl.sh heal`, with a brief rendered from a template in this
repository and the failed run's own record. The host CLI only sets the budget
(`run --heal N`) and reads the lineage back. A host-side retry loop would have
been simpler to write and would have died with the host session, which is the
one thing it must not do.

Three things bound it, each because the alternative was seen or obvious:

- **Follow-ups carry the original brief, never the previous follow-up's.** A
  chain that nested its prompts would grow one heal preamble per attempt and
  drift from what the operator asked. `origin` in `meta.json` names the run
  whose brief is the real one; every heal and every resume renders from that.
- **It never heals a stop, a question or a leak.** A stop was a person's
  choice. A question needs a person's answer. A leak (`exit:3`) needs a token
  rotated, and a retry with the same token is exactly wrong. Only `failed` and
  `lost` are healed, and `lost` only by the watchdog, because a lost run's own
  exit path never ran.
- **It never widens anything.** No allowlist change, no egress mode change, no
  cap raised, no push. The conventions header says so to the agent; the
  scripts give it no way to do otherwise. A heal that would need one of those
  is told to write a learning and stop, which is the honest outcome.

`waiting` is a marker beside the status, like `stopped`, for the same reason
`stopped` is: the status keeps the exit code, and the state is derived from
the two in exactly two places (`run-ctl.sh derived_state` and
`run-format.py Run.state`) that a test keeps in agreement. A stop outranks a
question; a leak outranks both.

The learnings file is under `/work` and not in the guest home because it is
the operator's record, not the run's: it should outlive the box and be read
on the host without a command. The rest of `.agent-box/` is already excluded
from git through `info/exclude`, so it travels with the mount and never with
the repository. The `framework` cause class exists so the entries about this
tool can be filtered from the entries about a repository, and worked through.

The watchdog is the one host-side piece, and it is deliberately dumb: start a
box that is stopped, heal a newest run that is lost, only for boxes an
operator marked, every five minutes, from launchd. It starts no new work. It
is also the least proven part of the design, having been exercised only by
hand at the time of writing.

## Why the host runs only four git verbs in a mounted repository

`/work` is the host's own directory, and everything in it is writable by the
guest — including `.git/config`, `.git/hooks` and `.gitattributes`. Several
ordinary git commands execute programs named in those files. `core.fsmonitor` is
a command git runs on `status` and `diff`; a clean or textconv filter is a
command git runs while reading a file; a pager is a command git runs when stdout
is a terminal; `core.hooksPath` points at scripts git runs on its own.

So a host-side `git status` in a mounted repository is the box choosing a program
for the host to execute, outside the VM, as the operator. Nothing about that is
exotic: it is the documented behaviour of configuration that lives in the
repository the agent is working in.

The rule is therefore mechanical rather than a matter of care. Every host git
command that touches a mounted repository goes through one helper —

```
git -c core.fsmonitor=false -c core.hooksPath=/dev/null --no-pager -C <repo> …
```

— and only as `rev-parse`, `rev-list`, `for-each-ref`, `symbolic-ref`, or as the
source of a `clone` or `fetch`. Those five read refs and objects and run nothing.
`--no-pager` is in the helper because a pager is the third program a config file
can name, and it is the one that fires only when a human is watching. Any git
command this tool *prints* for an operator to run inside a mounted repository
carries the same three flags, for the same reason.

What that costs is a real capability: the host cannot count the box's uncommitted
files, so a handoff's dirty claim is the box's own word, shown behind the bar,
and `triage`'s dirty count is computed inside the VM where running the
repository's own config is already the deal. Two features were removed rather
than guarded — a host-side dirty count in the bench output, and a "N uncommitted
files" note in `triage` — because a guarded version of a number nobody needs is
still a place for the next person to add a sixth verb.

The obvious alternative, `GIT_CONFIG_NOSYSTEM` plus a scrubbed environment, was
rejected because it protects against the wrong file. The dangerous configuration
is the repository's own, which git reads by design, and no environment variable
turns that off. Limiting the verbs does.

`git status` appears exactly once in the whole CLI, with `-C` pointing at the
bench — a directory whose config the host wrote — and a smoke assertion holds it
there rather than an eye.

## Why the two sessions talk through files on the mount, and nothing else

The working shape for this tool is two Claude Code sessions: one inside the box
doing the work, one on the host controlling it and preparing the pull request.
They have to exchange work. Everything about how they do it follows from the fact
that the mount is the only thing that crosses the VM boundary, and from the fact
that the box's credential is a setup token.

**Cross-session messaging is not available, and would be wrong here anyway.**
Claude Code's own session-to-session messaging is a Unix socket per session,
found through files under the user's home; a container or VM has its own
filesystem, so a session inside one cannot reach a session on the host. Across
machines it needs Remote Control, which needs a claude.ai sign-in as the
session's active authentication — and this project already measured that Remote
Control refuses a setup token, which is the only credential a box has. Even if it
worked, it would be a path out of the VM that no scrubber sits on: the box's
words would arrive in the host session having passed no boundary at all.

**A forwarded socket was rejected as a second widening.** `--forward` is the one
place this design gives something back, and its entry above spends a page on why
that is acceptable only because it is opt-in, per port and fixed at create time. A
socket the two sessions used constantly would be a standing hole with a
general-purpose protocol on it.

**Transport over `limactl shell` was rejected because it has no queue.** A
message is most useful when the box is busy, and most needed when the box is
stopped — a request written on the host while the box is off has to be waiting
when it starts. A command that reaches into a running VM cannot hold anything for
a stopped one.

Files on the mount have none of those problems and one property the others lack:
the box's words pass through the guest-side scrubber on the way out, so the
scrub precedes the boundary rather than following it.

That is why the channel is the stated exception to `guest/lib.sh`'s own rule that
the guest writes nothing onto the host mount. The rule exists so that
model-authored text does not land on the host's disk unchecked. Here it lands
checked: written by the guest through the same redaction the run summary uses,
capped, and read back by a host command that bars every line of it.

MEASUREMENT OWED (a real in-box session acting on a host request, end to end,
with `abx done` and both sides visible in `channel` and `status`): the smoke
suite proves this to the hook boundary only — the settings wiring, the exported
environment, and a guest poll seeing a request a host command wrote. The
model-level proof needs a box that holds a real token and is a manual step.

## Why each side believes only its own disk, and the sidecars are courtesy copies

The mailbox is under `/work`, so the guest can write anything in it: a `.read`
sidecar for a message nobody read, a `.done` for a request nobody answered, or
the removal of either. If the host displayed what it found there, the box could
tell the host that the host had read something.

So each side keeps its own record on a disk the other cannot touch. The host's
lives in `~/.config/agent-box/channel/<instance>/` — `read`, `done`, `sent`, and
its own `host` file holding what it last saw and what task it declared — and it
is that record, not the mount, that `channel` prints and `status --json` reports.
The guest's lives in the guest home at `sessions/claude/channel.seen` and
`runs-seen`, at mode 600, which is equally out of the host's reach.

The copies on the mount are not removed, because each is genuinely useful to the
*other* side's display: the box's card wants to know the host has read its
handoff, and the host's listing wants the box's own word for whether a request
was delivered. They are written second and read as decoration. The host's own
line and the JSON `host` object read the private copy first and only that; a
forged `host-status` on the mount changes nothing the host says about itself.

The failure direction is deliberate. Lose the host's record and every message
reads as unread again — the host re-announces things that were already dealt
with, which is noisy and safe. The opposite arrangement, trusting the mount,
fails toward silence: a box could make a handoff invisible by claiming it had
been read.

## Why guest receivers poll the mount

The box's side of the channel does not watch for changes. It looks, on an event
it already has.

Measured on this Mac on 2026-09-19: a host process writing into a repository's
`.agent-box/channel/to-box/` produced **no watcher events at all** inside the
guest across a virtiofs mount, while a 100 ms `stat` loop in the guest saw every
write immediately. That is the ordinary behaviour of a shared mount — inotify
reports the guest kernel's own writes, and a host write is not one of them — and
it disqualifies every design whose delivery depends on a filesystem watcher
noticing a host write.

There is a trap in testing this that is worth recording, because it produces a
false pass: a test that writes the file *from inside the guest* to simulate the
host will see the watcher fire, and will conclude the mechanism works. Every
host-to-box assertion in the smoke suite therefore makes its write with an
`agentbox` command **on the host** and guards that the file exists on the host
before the guest is asked anything.

What the box does instead is read the mailbox in hooks it is already being given:
at the start of every context, after each tool call, at each prompt, and at the
end of each turn. Those are cheap — a `find` over a directory of names and a read
of the files that are new — and they are events the CLI hands over anyway, so the
box pays nothing for a mailbox that stays empty.

## Why a request is delivered by a hook, shown before it is recorded, and never typed into the pane

Three ways to put a message in front of a session were considered. Two of them
lose messages or lie about them.

**`tmux send-keys` types at the agent.** The pane belongs to a model that is
mid-turn as often as not, and a session's own attach is already read-only for a
run for exactly this reason. Keystrokes are also unrecorded: nothing afterwards
can say whether the text arrived, arrived twice, or landed in the middle of a
tool call's output.

**A watcher that claims a message before showing it** is the natural shape and
the wrong one. If the record is written first and the injection then fails — the
hook is killed, times out, or the frame cannot be built — the message is marked
delivered and never shown. So the order is: build the text, emit it, and only
then write the two records, the sidecar on the mount and the line in the guest's
private seen-set. A hook that dies halfway shows the same message again, with the
same id, which is the failure this ordering chooses.

**A filesystem-watcher hook cannot do it at all**, for the reason in the entry
above, and a `FileChanged` hook in particular has no way to put text in the
model's context.

What is left is `additionalContext` from the hooks the CLI already fires, plus
one deliberate exception at the end of a turn: a `Stop` hook may return
`{"decision":"block","reason":…}`, which the CLI documents as "the conversation
continues so Claude can act on the feedback". That is the only blocking behaviour
in the whole channel, and it is bounded twice — a message is shown at most once
per session, so a `Stop` hook can block at most once per undelivered message, and
a hook invoked with `stop_hook_active` already true never blocks again.

**Every other channel hook exits 0, always.** This is not defensiveness; it is
the one rule that had to be stated as an invariant. Claude Code reads exit status
2 from a `UserPromptSubmit` hook as *block this prompt and erase it*. A channel
that could not read its own state — no directory, an unreadable mount, an unknown
event name, a hostile file in the mailbox — would then lock an operator out of
their own session for a reason having nothing to do with their prompt. So the
entry points of both hooks return 0 on every path, print nothing when they have
nothing to say, and never reach a `die` or a usage error. The host-side hook adds
a belt to that brace in the plugin wiring itself (`… || exit 0`), so a checkout
where the verb does not exist yet is silent rather than obstructive.

## Why there is no wake yet, and what a probe must show first

The delivery floor above has one honest limitation: an idle session is not
prompted by anything, so a request waits until somebody types. Claude Code does
document a mechanism that would close this — an `asyncRewake` hook, which "runs
in the background and wakes Claude on exit code 2" and "wakes Claude immediately
even when the session is idle". It is not shipped here, and the reason is that
nothing about it has been measured in this box.

The probe that would settle it was planned and did not run: every guest and mount
write it needed was refused by the permission classifier on the machine where it
was attempted, so all five of its questions came back unanswered. What it has to
show, before any of this becomes code:

- whether a long-poll hook inside the guest can hold for a useful interval at
  all, and what the largest honoured timeout is;
- what happens at that timeout — silently ending is fine, a visible error in the
  operator's session is not;
- whether the wake survives the events that a real session goes through: a
  `/clear`, a compaction, a resume, a fork;
- whether the woken turn can be made to carry the message without the message
  becoming a prompt the model treats as the operator's words;
- and what it costs when the mailbox is empty, which is almost always.

A dormant hook entry, shipped switched off, was rejected too. An untested entry
in the static settings file is loaded into every session in every box, and the
failure mode of a hook is not a missing feature: it is a session that behaves
oddly for a reason nobody is looking for. Shipping nothing is the honest state,
and the floor is not a bad state — a message is late, never lost, and every open
request is re-shown to every new context.

The documentation and the `request` command both say the consequence plainly,
which is the part that matters most. An operator who knows a request arrives at
the next prompt will type something. One who believes it arrives immediately will
wait, and then distrust the tool.

## Why the host is told that a handoff exists, and never what it says

A host session learns about a message through a hook. That hook prints ids,
states, counts, box names and paths — all of them either this machine's own words
or values that passed a shape test — and it prints no part of any message's
content, not even the subject.

The reason is what the printed line is *for*. It appears in a host session's
context automatically, and a line that appears automatically is the highest-value
place in the whole system to put a sentence that reads as an instruction. Message
bodies are written by a model working in an untrusted repository. Keeping them out
of the automatic path means the only way box-authored prose reaches the host
session is through a command the operator or the session deliberately ran, where
it arrives barred and labelled.

The same reasoning decides how the hook knows which box a session is about, and
it is worth recording because the obvious implementation is unsafe. Asking git —
`git rev-parse --git-common-dir` — looks like the natural way to map a working
directory to a repository. Measured with git 2.55.0 on 2026-09-19: a `commondir`
file planted in a guest-writable `.git` **redirects that answer**, and it does so
even with `core.fsmonitor=false` and `core.hooksPath=/dev/null`. A box could
therefore choose which box the host's hook thought it was looking at.

So the hook calls git not at all. It resolves the working directory physically
(`cd … && pwd -P`) and matches it by containment against each box's recorded
repository, itself physically resolved, and against each box's bench directory.
No match means no output and exit 0. One consequence of resolving paths rather
than asking git: a box created before this version has no repository recorded, so
it is invisible to the hook until its first `start`, `session`, `claude`,
`request` or `channel` on the new checkout backfills the record. That is stated in
the docs rather than papered over.

## Why the host bars every box line itself, and checks a handoff's claims with two git commands only

`## Why the formatter and the status script run in the guest` says the redaction
belongs in the guest, because that is where the token's fragments are known. That
is unchanged and is not what this entry is about.

The bar is a different boundary. The guest's renderer is not a trust anchor: the
guest user has passwordless sudo, and the smoke suite already demonstrates that a
file under `/opt/agent-box` can be bind-mounted over from inside the box. So a
host command that prints a handoff assumes the renderer may have been replaced,
and redoes host-side everything it can without parsing: a byte cap first, a
control-character strip, and then `  | ` in front of every line. The JSON path is
clamped to printable ASCII — `json.dumps` emits nothing else — and the guest's
object is nested under an `untrusted` key that comes **first**, so that every
host key follows it and a duplicate key emitted by the guest loses to the host's
own, both `jq` and Python taking the last of a repeated key.

Marking the text is not security theatre; it is the only mitigation available
against the actual threat, which is not exfiltration but prose read as
instructions. The host cannot verify a claim like "the suite passes". What it
*can* verify, it does: a handoff names a branch and a commit, and the host checks
those with two read-only commands through the four-verb helper — does that branch
still point at that commit, and how many commits has it gained since — and prints
its own answer beside the box's. So the two kinds of statement in a handoff are
visibly different kinds: one is checked and labelled, and one is barred.

## Why no host write onto the mount is a redirect or a plain mv

Every file the host writes into the mailbox is created with `noclobber` and moved
into place with a rename that refuses to follow a link. Neither is a style
preference. Measured on this Mac on 2026-09-19, with bash 3.2 and a planted
symlink in the target directory:

```
--- mv -f onto a planted symlink-to-directory (plain) vs mv -fh
plain:  outside/.tmp.1 created         <- the file left the mailbox
-h:     the target is a regular file; outside/ is empty
--- noclobber create through planted symlinks
symlink->regular rc=1   victim content: PRECIOUS
dangling symlink rc=1   outside/ holds only: victim
free name rc=0          second create rc=1
bare redirect rc=0      victim now: []              <- truncated through the link
```

Two distinct escapes, both from one line of ordinary shell. A bare `: > name`
truncates whatever the name points at, so a planted symlink lets the box empty a
file elsewhere on the host, in the host's own uid. A plain `mv -f` onto a name
that has become a symlink to a directory moves the file *out* of the mailbox
entirely, into a directory the box chose.

So: `set -o noclobber` for every creation, a random-named temporary file in the
same directory, a byte-count check after the write, and then `mv -fT` or `mv -fh`
— feature-detected, with the weaker check-then-move fallback documented as
weaker. Every failure path removes the temporary file and any still-empty
reservation and publishes nothing, so a crash mid-send leaves something a reader
skips, not a half-message.

The same measurement is why ids are reserved before they are used. Twenty
parallel noclobber reservations in a single UTC second produced twenty distinct
ids and no duplicate, which is what makes a second-granular id safe without a
lock across processes.

`.agent-box/.gitignore` holding `*` is the last piece, and it is a `.gitignore`
rather than a line in `.git/info/exclude` because the channel directory can now be
created before any run has happened and by either side. The exclude entry is still
written too; belt and braces, on a directory whose contents must never be
committed to somebody else's repository by accident.

## What a handoff can still do, and what the channel gives up

Stated plainly, because each of these is a thing an operator will otherwise
discover at the wrong moment.

**There is no exactly-once.** A hook that is killed after emitting a message and
before recording it shows that message again. The alternative loses messages
instead, which is worse; see the delivery entry above.

**Ids are UTC timestamps with a two-digit suffix**, so they order within one
direction and nothing else. No arithmetic is ever done on them, and no age column
exists anywhere in the channel, because an age would mean trusting either a
guest-set mtime or the guest's clock.

**Bodies cannot be read while the box is stopped.** The scrubber that knows the
token's fragments is in the guest, and a host-side reader would be the host
opening a guest-written file. Ids, states, counts, `--done` and `--wait` all work
stopped; `handoff <id>` refuses and says to start the box.

**A run receives nothing.** Delivery is to the standing interactive session only.
Mid-run mail makes a result irreproducible — the brief is no longer the whole
input — so `ask.md` and `agentbox resume` remain a run's way to ask a question,
and `abx handoff` is how work leaves the box. A run's automatic handoff is a
follow-up, not a feature of this version.

**One subscriber per box.** A second interactive session is untracked, told so on
stderr, and receives nothing. Two readers of one mailbox is a failure to detect,
not a capability to build.

**The retention sweep forgets things on purpose.** Once a UTC day, a message over
30 days old by the date in its name is removed, as is one that has been answered
and is over 7 days old. The `sent` line goes with the file, so a request the box
deleted still reads as `lost` rather than silently becoming unknown.

**The bench runs box-authored code on the host.** That is the subject of its own
entry below, and it is the one place the VM boundary is deliberately stepped
around. The skill and the documentation say to treat a handoff's `## Verify`
commands as a stranger's pull request, which is a mitigation and not a boundary.

## Why the toolchain is baseline and pinned, and what that supersedes

`## Why the Docker profile is opt-in per instance` is **partly superseded** by
this entry, and only partly. Its argument was that a profile costing a few
hundred megabytes and a doubled disk should not be paid for by a box that may
never need it. That still holds for Docker, which brings a daemon, a group that
is root-equivalent on the guest, and a second firewall surface.

It no longer holds for Node, Playwright and a browser. The cost was weighed
against a box that might not need them, and in practice every box needed them:
the flag was passed every time, and the boxes that were created without it were
recreated. A flag that is always passed is not a choice, it is a step to forget.
Per this file's convention the old entry is not edited — this one names it and
says which half survives.

So there is one baseline, installed by unconditional provisioning rather than by
a flag. That is not only tidiness: a create-time parameter is frozen for the life
of an instance, so a toolchain flag could never reach a box that already exists,
while provisioning code reaches every box at its next start. Twelve steps, in a
fixed order, each with its own marker under `/var/lib/agent-box/toolchain/`, so a
tool that is already at its pin is not touched.

Every version is pinned and every download is verified against a sha256 recorded
per architecture in `guest/toolchain.pins`. The only writer of that file is
`host/refresh-pins.sh`, which discovers each digest by downloading the asset and
hashing it locally rather than by copying a number out of a release page, and
writes nothing at all if any download failed — a half-updated pins file is a box
that installs a mixture of two versions. The three Python tools are pinned
through hash-locked, universal requirement files compiled by `uv`, so the whole
transitive set is fixed, not just the top-level name.

Two things in the baseline are nonetheless not pinned, one by choice and one by
upstream's arrangement. That is the next entry, and `guest/toolchain.pins` and
`host/refresh-pins.sh` both point a reader at it by name.

## Why Claude Code is the one version the box does not pin

One tool is deliberately unpinned: Claude Code. `CLAUDE_CODE_VERSION="latest"` is
written in the pins file as an explicit statement rather than an omission, because
the CLI's currency is a feature and not a hazard, background self-update is
already off in the guest, and `agentbox update` is the deliberate move. Pinning it
is a filed follow-up rather than a decision left implicit.

The browser's own build number is not pinned either, and that one is upstream's
fault rather than a choice: the revision is a function of the pinned Playwright
version, and upstream publishes no per-architecture digest for the build. The
Playwright version is pinned, the revision is read back from what was installed
and recorded, so a drift is visible even though it cannot be prevented.

## Why the toolchain installs after the firewall, not in the open window

Provisioning has a window near the start where the network is open, because
`apt` has to fetch the distribution's packages before the allowlist exists. The
tempting place to install a dozen downloads is that window.

It is the wrong place, for the same reason `## Why a probe that needs the internet
cannot decide whether the box is safe` gives: something that succeeds in the open
window proves nothing about the box the operator will actually use. Worse, it
hides a real failure until the first time an agent needs the tool, which is
mid-run, unattended.

So the installer runs **after** the firewall is up, under the standing `deny`
policy, and the create becomes the live test of the allowlist. That works without
widening anything because of one measured fact: GitHub's release-asset hosts
(`objects.githubusercontent.com`, `release-assets.githubusercontent.com`) resolve
inside the address ranges `api.github.com/meta` publishes, which the allowlist
already admits. Nothing was added to `guest/allowlist.base` for the toolchain, and
nothing was added to the distribution package list either — so no existing box
reopens its provisioning network window for this.

Two consequences are accepted rather than fixed. Installing under `deny` is
slower, and a CDN that rotates addresses between the firewall's rebuild and a
download can refuse one; that tool is then retried at the next start rather than
failing the boot. And a tool that needs to phone home before it will report its
own version cannot do so — which is not hypothetical. Measured in a guest on
2026-09-20, in cloud-init's own environment, which reads neither
`/etc/profile.d` nor `/etc/environment`:

```
env -i PATH=… HOME=/root  semgrep --version                     -> rc=124, no output
env -i PATH=… HOME=/root  SEMGREP_SEND_METRICS=off \
        SEMGREP_ENABLE_VERSION_CHECK=0  semgrep --version       -> rc=0, "1.177.0"
```

The blackholed version check was killed by its own timeout, read as "not at its
pin", and the tool was reinstalled on every single boot. The fix is to export both
switches in the installer and to probe with a guaranteed `PATH`; the lesson worth
keeping is that under default-deny a version probe is a network operation until
proven otherwise.

## Why a toolchain finding never blocks a run, and `toolcheck` still exits non-zero

These two audiences want opposite things, and the resolution is that they get
different channels rather than a compromise.

**Provisioning and the launch paths warn.** The isolation this project exists for
does not depend on a formatter. A box that will not open a shell because a
download failed is a worse box than one that opens a shell and says `dprint is
missing`. So the installer is fail-soft throughout: every tool failure is a
warning and a counted return, no marker is written for a failed tool so the next
start retries it, and the boot never fails. Below 4 GiB of free guest disk the
installer does nothing at all and says to resize, because filling a nearly-full
box is how a box that holds real work gets broken by an upgrade.

**A script gating on readiness needs a status code**, so `toolcheck` has four:
0 at baseline, 10 for a baseline tool missing or off its pin or unreadable, 11 for
a box that is clean where this repository pins something differently, and 1 for a
usage error or a sweep that could not read the box's pins file and therefore
compared nothing. The distinction between 10 and 11 matters because they are
addressed to different people: 10 is this tool's problem, 11 is the repository's.

One place takes a harder line than the rest, and it is the one where "ready" is a
claim rather than a status: `agentbox create` ends by running the check and exits
with its status, printing `NOT READY: <tool>` lines. The box exists and is usable
— nothing is rolled back — but a *new* box must not be reported ready with a tool
missing, because the operator's next action is to hand it work. `agentbox start`
on an existing box prints the same lines as a warning and exits 0, since the box
was already there and refusing to start it helps nobody.

A near-miss worth recording, because it shows how a lenient default hides a
detector's bug rather than a tool's. On 2026-09-20 the readiness check reported
`chromium is missing` on an arm64 box where the browser had in fact installed
correctly: the check looked for `chrome-linux/chrome` and the build unpacks to
`chrome-linux-arm64/chrome`. Before it was fixed, `toolcheck` would have exited
10 for ever and every `create` on Apple silicon would have ended with a false
`NOT READY`. The check now matches the executable by glob across layouts, and the
case is in `test/no-vm.sh`, which the old function fails.

## Why the project's pin wins, and why the box only reports it

A box carries one baseline. A repository may want something else — its CI pins
Node 20, or `ruff` 0.9, or a Playwright version whose browser build differs. Two
things follow, and they point in opposite directions.

The project's pin wins on the substance. A green result from the wrong version is
worse than no result, and CI is the authority on what the project's own commands
mean. So `toolcheck` reads the repository's own files — the mise TOML paths,
`.tool-versions`, `.python-version`, `.nvmrc`, `.node-version`,
`pyproject.toml`, `uv.lock`, `package.json`, `package-lock.json`, and the
versions given to a short list of known setup actions in workflow files — and
reports every mismatch with a `file:line` so the claim is checkable.

And the box does not act on it. Installing the version a repository asks for
would mean executing a version string chosen by whoever wrote that repository, as
part of starting a box, from the one directory this whole design treats as
untrusted input. The agent is the right actor: it can read the workflow, see what
the command actually is, decide, install in its own environment, and write down
what it did under the learnings convention. So the findings are printed above
every brief and injected into an interactive session's first context, and
convention 4 of `guest/conventions.md` tells the agent that the project wins.

Nothing in `/work` is executed to produce that report. The detector reads files
with anchored patterns and never runs a resolver, a package manager or a YAML
parser — one more dependency in the guest for advisory output was not worth it —
and every value it extracts is shape-tested before it is printed. A version
string that fails the shape test is reported as unreadable rather than as a
mismatch, so a repository cannot make itself exit 11 with a made-up token, and
`lts/*`-style aliases land there too rather than being guessed at.

Every bound is fixed: the number of files, the bytes per file, the number of
findings, the length of each. A repository that wants to make this report
enormous can only make it truncated.

## Why a run owns a process group, not a process tree

A run that starts a dev server and exits used to leave it running for ever. The
obvious fix — at run end, walk the descendants of the run's process and kill them
— does not work, and the way it fails is silent.

By the time the sweep runs, the CLI is dead and everything it started has been
reparented to pid 1. A descendant walk therefore finds nothing, kills nothing,
and reports success. That is the worst available outcome: a cleanup that is
believed and does not happen.

`set -m` in `agent-run.sh` already gives the CLI its own process group, and the
interrupt path already relies on that. So group membership is the primary
ownership proof, and a second, independent proof sits beside it: the run's own
events directory appears in a process's environment block, tested with
`grep -qzxF` and never read into a variable, because that block may also hold the
token. A deliberately `setsid`-escaped child satisfies the second proof and not
the first, which is why the smoke suite plants one.

Ownership is not enough on its own, because pid numbers are reused. Every
candidate's start time is compared against the run's own baseline — taken from
the box's uptime at the moment the run began, truncated to an integer before
comparison — and a process that predates the baseline is not this run's, whatever
group it is in. A process whose start time cannot be read at all is **neither
killed nor hidden**: it is reported as a survivor whose ownership could not be
verified. That is the only honest third answer, and having it is what lets the
other two be strict.

Three alternatives were rejected. A descendant walk, for the reason above.
`pkill -f <pattern>`, which matches on a command line the agent chose and would
happily match the operator's own processes on the same box. A cgroup or
`systemd-run` scope per run, which needs privilege the run does not have and
would be this project's second fight with systemd ordering — the first, over
masking the stub resolver, is elsewhere in this file.

MEASUREMENT OWED (a `pgrep -g` transcript from either side of a real sweep, with
the guest's Claude Code version and the date): the mechanism is proven by the
smoke suite's stand-in, which starts listeners in and out of the run's group. What
is not yet measured is whether the real CLI's own Bash tool puts a backgrounded
process in the run's group, carries the run's environment into it, or neither. If
it turns out to be neither, the sweep's process class covers less than this entry
claims, and the honest statement is that the port and tmux classes still hold.

MEASUREMENT OWED (the `/proc/net/tcp` hex field layout, and a process whose
`comm` in `/proc/PID/stat` contains a newline, read in a live guest): the port
enumerator parses both by hand rather than adding a package, and both are read
from documentation rather than from this box.

## Why the sweep runs before the summary and not in `finish()`

`finish()` looks like where cleanup belongs, and it is the wrong place for two
reasons that are both already commented in the script.

It is draining the console tee. Anything the sweep printed there would be lost or
interleaved, and a sweep whose report nobody can read is a sweep nobody will
trust the next time it says it killed something.

And it runs on precondition failures. A run that dies because there is no token,
or because the firewall unit is down, has started nothing — so a kill loop there
is a new failure surface on a run that is already failing, for no benefit.

So the sweep runs after the stop-requested check and before the summary is built,
which is also the point where its one-line `hygiene` report can be kept in
`summary.txt` and in the terminal output. The console output is passed through the
token scrubber on the way, because a sweep names paths the model chose; the raw
ledger stays in the guest home and is itself part of the run's leak check.

## Why a standing session is never swept

The threat is concrete and would be this tool's most embarrassing failure: the
operator starts a dev server in their interactive session, a run ends an hour
later, and the run's cleanup kills it.

Two independent mechanisms make that impossible, and the entry names both because
one would be a single point of failure. A standing session's processes are in no
run's process group and carry no run's events directory in their environment, so
they fail both ownership tests. And they predate any later run's baseline, so they
fail the start-time test as well. Either one alone would suffice; neither is
relied on alone.

The cost is stated rather than hidden: a session's leftovers are shown and never
cleaned. A long-lived box accumulates them, and the only cleaner is the operator.
That is the right trade — a session is the operator's hands, and a tool that
tidies up after somebody's hands is a tool that throws away their work — but it
does mean `leftovers` on an old box lists things nothing will ever remove.

For the same reason there is no session sweep and no per-session ledger. There is
also no safe trigger for one: `tmux new-session -A` means a session outlives every
attach, so "the session ended" is not an event anything observes. What a session
does get is visibility — its tmux existence and age, its own status file, its last
hook event, and its state in `status --json`.

## Why run records stay in the guest and nothing is journalled on the mount

An earlier design had a run append one line per ending to a journal on the mount,
so that a host-side reader could see what had happened across runs. It is not
built, and the reason is a rule rather than a difficulty: nothing host-side reads
it.

Every consumer that was going to — the host's notice about finished runs — is
better served by the thing that already exists. The box's own session hook reads
the run directories directly and keeps a private set of the run ids it has
already mentioned, in the guest home, where the box's other private state lives.
`status --json` exposes one number from that, `standing.runs_unseen`. A journal
would have been a second copy of facts the run directories already hold, on the
one filesystem both sides can write, for a reader that turned out not to exist.

Removing it removed two problems with it. The first was the mount: a journal is
model-adjacent text, and the fields that make it useful — what a run left running,
a branch name, a reason — are values the agent chose. The resource ledger has
exactly that problem, which is why `owned.jsonl` lives in the guest home at mode
600 and is part of the run's leak check rather than on the mount. The second was
the leak check's shape: checking the journal file after a run would make one
poisoned line fail every later run for ever, and checking each line before
appending it is a different mechanism that had to exist anyway.

What does reach the host from all of this is deliberately small and entirely
shape-validated: run ids matching the id pattern, a state word from a closed
vocabulary, a branch name that passes a branch shape or a literal `-`, and
counts. No model prose, so there is no scrub pass to get wrong. The collision
note a run prints at its start follows the same rule — "1 worktree, 1 tmux
session from run X; see `agentbox leftovers`" — counts and ids, never a path and
never a detail, because a path in that note is an earlier run's chosen text
appearing in this run's console.

## Why `create` refuses a forward the host cannot bind

Lima cannot bind a host port that something else already holds, and what it does
instead is nothing: the forward simply does not answer. That reads as a guest
problem. An operator spends the next twenty minutes inside the box, checking what
it is listening on, and the answer was on the Mac all along.

So each requested port is probed before anything else happens — before preflight,
before `limactl` is called at all — and `create` refuses, naming the port and the
process that holds it, or the other box whose forward it is. Recovery is cheap
(free the port, run create again), create is a one-time operation that takes
minutes anyway, and there is deliberately no `--force`: choosing a port that
cannot work is not a thing to make easy at the moment it is being chosen.

`start` runs the same probe, because a forward is a frozen create-time parameter
and a host port can be taken while a box is stopped. Here there *is* an escape —
`--ignore-port-conflict` — because refusing to start an existing box that holds
real work, over one dead forward, is the wrong trade. It prints a warning naming
the port and saying that forward will not answer.

Three probes are used in order, and the order is about what each can see: `lsof`
first, because it sees a socket bound to any local address, not only the loopback
one a forward uses; then bash's own `/dev/tcp` pseudo-device, which needs no tool
at all; then `nc`. Where none of them can answer, the refusal degrades to a note
and the box is created — the same tradition as the Time Machine exclusion, where a
missing local tool must not block a box.

A box's own Lima process holding its own forward is not a conflict, which is the
one case the check must not get wrong; it is identified by comparing the holding
pid against each instance's recorded hostagent pid, and walking a small number of
parents, because the process that binds the host end may be a child of the
hostagent rather than the hostagent itself.

MEASUREMENT OWED (`lsof -F pcn` for a real forward printed beside that instance's
`ha.pid`, and `ps -o pid,ppid,comm` for the holder): the identity of the
binding process is read from Lima's behaviour rather than measured here. Until it
is, a stale `ha.pid` whose pid has been recycled could misname the holder in a
message — it cannot cause a wrong action, because the refusal is the same either
way.

`agentbox ports` is the other half, and it is the part that was actually missing.
It reads the recorded forwards, asks the host what holds each port, asks the guest
what is listening on it, and renders both with its own verdict. The guest answers
in a three-word vocabulary — `loopback`, `any`, `other` — rather than with an
address, because the host has no business inventing an address it was not told;
`other` is the real trap, a working listener bound to the guest's own interface
address that no forward can reach. `reaches` is `false` with a reason for a
stopped or silent box, and `null` only when the host had no probe at all, because
"nobody looked" and "looked and no" are different answers.

## Why the host verifies in a clone of its own

The oldest friction in this project is one directory and two operating systems:
`/work` is a shared mount, so a `.venv` or `node_modules` the agent builds inside
the guest lands exactly where the Mac's own copy was, with Linux binaries in it.
The host's `pytest` then fails with `bad interpreter`, which is a confusing way to
be told that the mount worked.

Verifying a handoff makes that worse, because verifying means building. So the
host builds somewhere else: `agentbox bench` makes a clone of the repository under
`~/.config/agent-box/bench/<instance>/`, checks the box's branch out there, and
that is where the host's dependencies and test runs live. The box keeps building
where its CI builds — item 3 of this whole design is that the box runs the
project's own command, and a box whose environment sits somewhere CI does not is
less faithful, not safer.

**A clone, not a worktree**, and that is the part worth recording. `git worktree
add` is the cheaper mechanism and it fails twice here. It refuses outright when
the branch is already checked out somewhere: measured on 2026-09-19,
`fatal: 'agent/example' is already used by worktree at …`. And it registers
`.git/worktrees/<name>/gitdir` **inside the mounted repository**, which the guest
can read to learn a host path and can prune or corrupt.

A hardlinked local clone was rejected for the same class of reason and is the more
interesting rejection, because it looks free. `git clone` without `--no-local`
hardlinks the object store, so the bench's objects *are* the same inodes as files
the guest can rewrite — which contradicts the one sentence the bench exists to
make true. `--no-local` copies the objects instead and pays for the object store
twice.

MEASUREMENT OWED (`du -sh` of a bench's `.git` beside the repository's own, on a
real repository): the cost of copying the object store is the price of this
decision and it is not yet measured here.

Disposability is the rule that makes the bench safe to delete, and two guards
enforce it rather than trusting it. A refresh refuses if the bench has modified
tracked files, and refuses if the bench holds a commit the repository does not —
printing the exact line that moves those commits back rather than leaving the
operator to re-type the fix or do surgery: a `git cherry-pick` of the bench's
extra commits, oldest first, run **in the mounted repository** and carrying the
same three protections every printed git command carries. That line is a
convenience, not a guarantee, and the documentation is explicit about the half it
cannot make safe: a cherry-pick applies onto whatever branch the repository is
standing on when it is pasted, so the operator checks that branch first. The
tool does not choose the branch for them — it knows which commits are stranded,
not which branch they belong on. Untracked files are deliberately
**not** counted: untracked files in a bench are the build, and counting them would
refuse every refresh, which would defeat the purpose. The honest consequence is
that something written by hand in the bench and never committed is not protected
by `--remove`, and the documentation says so.

The bench is excluded from Time Machine for the same reason `~/.lima` is: it fills
with dependency trees that are rebuildable by definition, and it would otherwise
double the backup of every one of them.

And the thing this entry cannot make safe: the bench runs code the box wrote, on
the host, outside the VM boundary. That is what verifying a branch *is*, it is the
setup this whole tool is built for, and the mitigation is procedural — the host
skill and the documentation say to read the diff first and to treat a handoff's
`## Verify` commands as a stranger's pull request. It is a mitigation, not a
boundary, and it is named here so that nobody has to rediscover it.

## Why `triage` is its own command, and why the host does not judge the guest's numbers

The question `triage` answers — may I stop this box, may I delete it, what would I
lose — mixes two kinds of fact. Host facts: what the box costs on this disk, how
much space is left, how many commits on its `agent/` branches are on no remote.
Guest facts: how many run transcripts it holds, what is in the guest home, what
its standing session is doing, whether its tree is dirty.

The verdict needs both, and the host is not allowed to parse the guest's bytes.
That rule is not new — it is the reason the formatter runs in the guest, and the
reason nothing the guest writes reaches an arithmetic expression or a shell
without passing a shape test first. So the verdict cannot be assembled inside
`status`'s splice, where the host is stitching a guest object into a document
without reading it.

The shape that follows: the host passes its own facts **into** the guest call as
arguments, the guest builds one finished object, and the host prints it. There is
exactly one exception, and it is deliberately a rigid one — a stopped box has to
be describable, which means the host must remember the box-only number from when
the box was running. That number arrives on a second, separately shaped output
line, is matched into host literals by `case`, is checked to be digits, is never
executed and is never echoed if it fails. The same pattern the watchdog already
uses to read a run id back out of the guest.

There is no fleet total of guest numbers. Adding up integers a guest wrote is
arithmetic on untrusted input for a figure that drives no decision: the
actionable unit is the box, because the action — pause, remove — is taken per box.
Per-box numbers are printed; a sum is not.

The belief this command exists to correct is that unexported work on an `agent/`
branch is trapped inside the box. It is not: the branch is in the mounted
repository, on the host's own disk, and survives `destroy`. What genuinely only
exists inside a box is the rest of it — run transcripts and event streams, the
standing session's state, a repository the agent cloned into the guest home,
Docker volumes and images — and that is the inventory `triage` prints, by
category, beside the verdict.

Two scarcity lines, each printed with the numbers it came from so the operator can
disagree with the verdict: **disk**, when free space is less than the largest
configured disk already in use, so another box of that size could not be created;
and **compute**, when the running VMs' configured memory sums to at least the
Mac's own. The second is about *commitment* and says so: whether the hypervisor
takes that memory up front or grows into it is not measured here, and a line
about measured residency would be a different and unearned claim. There is
deliberately no tuned threshold table — this file's own rule is that numbers are
measured, not estimated, and a threshold would be neither.

`triage` writes while it reads: the box-only watermark goes into the host's
instance record so a stopped box can still be described. That is not a new
category of behaviour — `box-status.sh` already reconciles a run's state as part
of answering a status query — but it is worth naming, because a read command that
writes surprises people once.

And there is no `--watch`, for the reason `status --watch` needs a named box: one
pass over the fleet is cheap, a loop is a guest call per running box every few
seconds aimed at boxes nobody named. There is also no `triage` key in
`status --json`, which would have been the cheap hook for a UI: computing it
host-side means parsing the guest's status object, and computing it guest-side
means the guest deciding pause-versus-remove without the host numbers that make
the question answerable. A UI calls `triage --json` on demand instead.

## Why the run-state vocabulary is written down three times, and what keeps them in step

There are three vocabularies for what a run is doing, in three files, and they
legitimately differ.

The **status file** holds what the run itself wrote: `running`, then
`exit:<code>`, `exit:stopped`, `exit:waiting` or `exit:lost`. The **derived**
state combines that with the marker files beside it, because a stop, a question
and a leak are facts that no single word in the status file can carry — this is
why `stopped` is a marker rather than a status, which has its own entry above. And
the **host** keeps a third list, of the words it will accept from the guest at
all, because a state word that reaches the host is guest-authored input.

Nothing fails when those three drift, which is exactly the problem. A word the
guest can write and the host does not accept is silently dropped, and the symptom
is a run that looks `unknown` for no reason. That happened with `exit:lost`: the
guest wrote it, the host's accept list predated it, and the run vanished from the
host's view of its own state while looking perfectly healthy inside the box.

The fix is not a shared constant — the three lists are in bash, in Python and in
bash again, in files that do not import one another, and a fourth mechanism to
keep them in sync is a fourth thing to drift. It is a comment in each of the three
places naming the other two, plus the one missing word, plus a smoke assertion
that reads the state **through the host path** rather than in the guest. The
suite's old assertion read it guest-side and passed either way, which is how the
drift survived: a check that cannot fail is worse than no check, because it is
believed.

## Why a brief is the caller's file and not the repository's

`agentbox run <repo> tests.md` resolves `tests.md` against the directory the
operator is standing in, and nowhere else. If it is not there, the command says so
and names the path it looked for.

The rejected alternative was a second search path: fall back to the repository
root, so that a brief committed in the repository can be named without a prefix.
It is a real convenience and it makes one bad thing possible — the same command
line, typed in two directories, runs two different briefs. Worse, the failure is
invisible: both files exist, the command succeeds, and the run is against the
file the operator was not looking at.

One search path plus a good error message gets most of the convenience with none
of the ambiguity. The error names the repository candidate it did *not* search, so
an operator who meant that file is told the path to type rather than left
guessing.

This is recorded because the original request asked for the fallback, and the
shipped behaviour is deliberately different. The issue is closed with the
behaviour it has; the decision lives here, and the regression check that was
missing exists now.

## Why a stopped box reports nothing rather than zero

`status --json` has three ways to say "there is no value here", and they mean
different things: `null` is *nobody could answer*, an empty array or a zero is
*genuinely none*, and absence is reserved for exactly one key.

Getting this wrong is not cosmetic. The fallback object the host prints when the
guest did not answer used to claim `runs_total: 0` and `sessions: []` — that is, a
stopped box asserted it had never run anything and had no sessions. Both are
claims about the guest, and runs live in the guest, so a host that cannot reach
the guest cannot have counted them. A reader with no way to distinguish those from
a genuinely empty box will draw the wrong conclusion and, worse, will draw it
confidently.

So every guest-computed key in the fallback is `null`, including the new ones, and
`null` is what a reader must handle for all of them. The one key that is *absent*
rather than null is `firewall_detail`, which exists only when there is something
to say: the mode is unknown, or the recorded mode and the live ruleset disagree.
Making it null on a healthy box would read as a fourth kind of unknown; that
asymmetry is deliberate and is stated in one place so it is not rediscovered as a
bug.

The host's own keys are not affected, because the host knows them whatever the
box is doing — and since this version they are printed **after** the guest's
object rather than before it, so that a guest answer carrying a duplicate
`"state"` or `"name"` loses. Both `jq` and Python take the last of a repeated
key. Before that change the box's own answer won, which is the opposite of what
the splice was for.

## Why the smoke suite can be stopped early, and why a truncated run is not evidence

The suite builds three real VMs and takes an hour. That made it a thing people
ran once and then reasoned about, which is how a suite stops being a check.

Two environment knobs fix the loop without pretending to be a test runner.
`SMOKE_STOP_AFTER=<label>` stops at a named step's end, which turns the host-only
steps from an hour into a couple of minutes, and prints a `STOPPED AFTER` line so
the output says what it is. `SMOKE_KEEP=1` leaves the instances behind for
inspection. A real subset runner was rejected: genuinely running one step alone
means wrapping thousands of lines of straight-line script into functions, or
keeping a manifest of line ranges that goes stale at the first insertion.
`SMOKE_STOP_AFTER` is what the existing `step()` can implement honestly.

The rule that comes with them is the important half: **a truncated run is not
evidence.** The contract this project works to says test output is pasted, not
claimed, and a pasted `STOPPED AFTER 3h` proves the host-only steps and nothing
about the three VMs. So the process contract says the pasted evidence comes from
an unfiltered run, and the stop line exists so that a filtered one cannot be
mistaken for one.

Two more things were learned by the suite lying rather than failing. A missing
`jq` on the host turned 26 contract assertions into confident FAILs about the
product, so the prerequisites are now checked up front, by name, before any
counter moves. And the suite's fixed test ports collided with whatever else was
on the host that day, which presented as a firewall breach — ports are now
derived from the suite's own process id, and the port-dependent steps re-probe
immediately before they create anything, since `create` now refuses a port
somebody else took in the meantime.

## Why "the new version" is a commit, and not a tag

There are no tags in this repository, no `CHANGELOG`, and no CI. That is not an
oversight to be fixed in passing, and the version question has a real answer
without any of them.

The mechanism nobody had written down is the whole answer. The installed CLI is a
symlink into a checkout, `bin/agentbox` resolves that symlink to find its own
directory, and **the same checkout is mounted read-only at `/opt/agent-box` in
every box**, where provisioning re-runs at every start. So there is exactly one
version on a host — the checkout's current commit — and it is simultaneously the
version of the CLI, of the guest scripts, of the provisioner and of the pins
file. `agentbox version` prints that commit, its date, and whether the tree is
clean, because a dirty tree means the boxes are running something that is not any
commit at all.

The consequence is the one to internalise, and it is why several decisions in
this file are shaped as they are: the moment the checkout moves, every existing
box runs the new provisioner at its next start. An upgrade is therefore not a
thing that happens to new boxes; it is a thing that happens to boxes that hold
real work. That is why the toolchain installer is fail-soft and idempotent, why
it tolerates a create-time parameter that a frozen instance never received, and
why the channel's hooks are inert unless a session is the tracked standing one.

Tags are not added by hand here, because the rule this project works to is that
semver tags come from release automation and never from a person. That automation
needs a workflow, and adding CI to this repository is a change to the guard rails
rather than a change to the tool — it needs the owner's own decision, and it is
filed as one. Until then, "the new version" means: merged to the default branch,
installed on this machine, and proven here. Which is a weaker claim than a tag,
and is stated as the weaker claim rather than dressed up as one.
