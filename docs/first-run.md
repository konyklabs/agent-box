# First run

Follow this once, in order. Steps 1 and 2 do not need the host at all.

---

## 1. Before you point it at code you do not own

Get permission first, in writing, from whoever owns the repository and the
data in it. This tool cannot do that for you. Send something like this and
keep the reply.

> I would like to run an AI coding agent, under my own Claude subscription,
> against `<repository>`, a generic end-to-end test repository that contains
> no customer data, no production configuration and no credentials.
>
> It runs inside a disposable Linux virtual machine on my machine. The VM can
> see that one repository and nothing else — not my home directory, not other
> projects. Its outbound network is deny-by-default with a short allowlist.
>
> The agent never pushes: I review every change and push it myself under my
> own identity.
>
> Please confirm this is acceptable, or tell me what would make it acceptable.

If the answer is no, stop. Nothing below makes it a yes.

## 2. Turn off training on this account, then mint the token

Any Claude subscription works — Pro, Max, Team or Enterprise — via
`claude setup-token`. Do this on any machine where you are logged in to
Claude; it does not need to be the host that will run the VM.

1. Go to claude.ai → Settings → Privacy and turn **"Help improve Claude"**
   **off**. Do this *before* minting the token. It governs whether your
   conversations may be used for model training, and you are about to point
   this account at a repository that is not your own.

2. Mint the token:

   ```
   claude setup-token
   ```

   It prints a one-year OAuth token **once**. Copy it. There is no way to
   display it again; if you lose it, mint another and revoke the first.

Keep it in your password manager, not in a file, not in a note, not in a chat.

## 3. On the host: set up the box

```
brew install lima gitleaks
git clone <this repo> ~/dev/agent-box
```

Create the host-side configuration directory. Nothing in it is ever committed —
it is where everything site-specific lives, precisely so that none of it ends
up in a repository.

```
mkdir -p ~/.config/agent-box
```

Two of these files are mounted into the VM and one deliberately is not.

**`~/.config/agent-box/guest/allowlist.local`** — extra domains the VM may
reach, one per line, `#` for comments. The base allowlist in `guest/allowlist.base` covers
Claude Code, GitHub, npm and PyPI. This file is where the app under test and its
staging hosts go.

```
# hosts the test suite talks to
staging.example.internal
api-staging.example.internal
```

**`~/.config/agent-box/blocklist.txt`** — literal terms that must never leave,
one per line: names, hostnames or codenames you never want a model to see.
Note the path: this one lives in the **parent** directory, not in `guest/`,
and it is never mounted into the VM. It is the list of the very terms you are
trying to keep out of a model's context, so it is read on this machine only.
`agentbox create` refuses to start if it finds this file inside `guest/`.
`agentbox preflight` scans every repository for these before it is mounted and
reports **paths only**, never the term itself.

**`~/.config/agent-box/guest/plugins.txt`** — optional. Marketplaces to register
and plugins to install inside the VM, one directive per line, `#` for comments.

```
marketplace konyklabs/claude-plugins
install supervisor@konyklabs-plugins
```

The marketplace **name** comes from the marketplace's own manifest and is not
always the repository name: `konyklabs/claude-plugins` registers as
`konyklabs-plugins`. If you are unsure, add it once inside the VM and read the
name back with `claude plugin marketplace list`. The file is applied on first
boot and on demand with `agentbox plugins <repo>`.

**`~/.config/agent-box/guest/plugin-dir/<name>/`** — optional. A plugin root you
are still writing, `.claude-plugin/plugin.json` and all. Nothing is installed:
each such directory is passed to the CLI as `--plugin-dir` for that session
only, straight from the read-only mount.

**`~/.config/agent-box/guest/claude/`** — optional. The pieces of your own
Claude Code setup you want in the VM: `CLAUDE.md`, `settings.json`,
`supervisor.json` (and the pre-2.0 `governor.json`) and `rules/*.md`. Those
names and nothing else — the copy is an allowlist, and a `.credentials.json`
or a `*.token` left in there is refused with a message rather than skipped in
silence. What crosses and what does not is listed in
[daily-use.md](daily-use.md).

**`~/.config/agent-box/guest/ca.pem`** — only if your network intercepts TLS. If
`curl https://api.anthropic.com` on the host fails with a certificate error,
you are behind such a proxy; export its root certificate and put it here. It is
installed into the guest trust store and `NODE_EXTRA_CA_CERTS` is set. Skip
this file entirely if you are not.

The `guest/` subdirectory — and only that subdirectory — is mounted **read-only
into the VM**, at `/opt/agent-box-config`. Nothing is copied into the agent-box
checkout, so none of these strings ever enters a git repository. It may be
empty, and `agentbox create` creates it if it is missing.

The commands write four more things into the **parent** directory as they go, and
none of them is mounted or is yours to edit: `instances/<instance>` (what this
host recorded about a box — its egress mode, its repository, its forwards),
`channel/<instance>/` (this host's own record of the messages it read and sent),
`bench/<instance>/` (a host-side clone of the repository, once you ask for one)
and `watchers/` (a pid file per `run --notify`). The full tree is in
[daily-use.md](daily-use.md) under "Host configuration layout".

### Choosing an egress mode

`create` will not run without `--egress`, and the refusal prints the three
choices. That is deliberate: how far a box can reach is the single most
consequential thing about it, and a default nobody chose is the one people
forget they have.

- **`deny`** — refuses anything not on the allowlist. Start here.
- **`observe`** — allows everything and logs what was not on the allowlist.
- **`open`** — no egress filtering.

If you always want the same one, put it in `~/.config/agent-box/config`:

```
egress: deny
```

Create will then take it and say so, naming the file it came from.

Then create the VM and give it the token:

```
cd ~/dev/agent-box
./bin/agentbox create ~/dev/my-e2e-tests --egress deny
./bin/agentbox token  ~/dev/my-e2e-tests    # paste it; it is not echoed
```

### Recipe: internal network open, internet curated

The common shape for testing against a staging environment. The VPN ranges and
the staging domain go in `~/.config/agent-box/guest/allowlist.local`, and the
mode stays `deny`, so everything internal works and the internet is still the
short list the box ships with:

```
# ~/.config/agent-box/guest/allowlist.local
10.0.0.0/8            # the corporate range, reachable over the host's VPN
100.64.0.0/10         # the VPN's own carrier-grade NAT range
.staging.example      # the staging environment and every host under it
```

A suffix line needs no list of subdomains: the guest's resolver adds each
address to the allowed set as it looks the name up. A CIDR needs no resolution
at all. Then:

```
./bin/agentbox create ~/dev/my-e2e-tests --egress deny
./bin/agentbox firewall-check ~/dev/my-e2e-tests   # rebuild and see it take
```

### Recipe: observe for a week, then write the allowlist

When you do not yet know what a repository's tests reach for:

```
./bin/agentbox create ~/dev/unfamiliar --egress observe
# ... let it run for a few days ...
./bin/agentbox egress-log ~/dev/unfamiliar --since 7d
./bin/agentbox egress-log ~/dev/unfamiliar --since 7d --as-allowlist \
    >> ~/.config/agent-box/guest/allowlist.local
$EDITOR ~/.config/agent-box/guest/allowlist.local   # read it before you keep it
./bin/agentbox egress ~/dev/unfamiliar deny
```

`--as-allowlist` emits names where the guest resolved one and comments out bare
addresses, because an address with no name is a judgement call and it is yours.
Read the file before you keep it: observe mode records what the code DID reach,
which is not the same as what it SHOULD.

`create` takes a few minutes the first time, mostly downloading the Ubuntu
image. Subsequent instances reuse the cached image.

The first boot also installs the box's toolchain — `uv`, `ruff`, Node, `mise`,
`trufflehog`, `actionlint`, `dprint`, `basedpyright`, `semgrep`, Playwright and a
shared Chromium — **under the firewall it just built**, not in an open window, so
the create is itself the proof that the allowlist admits what the box needs. That
adds a minute or two. `create` then ends by checking every tool by name and exits
with that check's status: 0 at baseline, 10 with `NOT READY: <tool> …` lines if
something is missing or off its pin. The box exists and is usable either way; the
exit status and the last lines are what say it is not at baseline. Later starts
install nothing and print `All toolchain pins already satisfied`.

The token goes straight from your terminal into the VM. It is never written to
a file on the host, never passed as a command-line argument, and never put in
the environment.

## 4. Confirm it actually works

```
./bin/agentbox verify-auth ~/dev/my-e2e-tests
```

This is the real test, and it is the only thing that proves the token
authenticates. Everything before this point succeeds just as happily with a
token that does not work. It exports the credential and makes one small model
call inside a single guest shell, then prints pass or fail and the reply.

Do not try to do this by hand with `agentbox shell` followed by `claude -p`.
Nothing exports the token into an interactive shell, so the CLI finds no
credential and asks you to log in through a browser the VM does not have.

If it fails, in this order:

1. `./bin/agentbox shell ~/dev/my-e2e-tests` then `echo $ANTHROPIC_API_KEY` —
   it must be empty. An API key silently outranks the OAuth token.
2. `./bin/agentbox firewall-check ~/dev/my-e2e-tests` — every line must say
   PASS. A failing `anthropic-allowed` line means the egress rules, not the
   token.
3. Check whether a managed Claude Code configuration on this device restricts
   which accounts may sign in.

Then the readiness check, which is about the box's tools rather than its
credential:

```
./bin/agentbox toolcheck ~/dev/my-e2e-tests
```

Exit 0 means every baseline tool is at its pin and this repository pins nothing
differently. Exit 10 names the tools that are missing or off their pin — a
warning, not a broken box, and the next `agentbox start` retries the install.
Exit 11 means the box is at baseline and **this repository asks for a different
version** of something, with `file:line` for each; the project wins, and the
agent is told to install its version before trusting a result.

To look around inside the VM for any other reason:

```
./bin/agentbox shell ~/dev/my-e2e-tests
```

## 5. The daily loop

Two modes, and the friction to expect from each, are in
**[daily-use.md](daily-use.md)**. The short version: `agentbox claude <repo>`
for an interactive session, and the brief-driven loop below for anything you
mean to review as a diff.

1. Copy `templates/brief.md`, fill it in. The whole file becomes the prompt, so
   vagueness in it becomes guesswork in the VM.
2. `./bin/agentbox run ~/dev/my-e2e-tests briefs/my-task.md --model sonnet`
3. The agent works on a new `agent/<slug>-<timestamp>` branch and stops. It
   does not push, and has no credential to push with.
4. Review the diff **on the host**, in your normal tools.
5. Push it yourself, under your own identity, if you are happy with it.

The full JSON transcript of each run stays **inside the VM**, under
`~/.agent-box/runs/`. What crosses to the host is a short scrubbed summary, at
`<repo>/.agent-box/last-run.txt`, and — if you use the two-session loop — the
mailbox at `<repo>/.agent-box/channel/`, whose messages are scrubbed in the guest
the same way. Both are excluded from git: the directory carries its own
`.gitignore` of `*`, and the repository's `.git/info/exclude` covers it too,
rather than its tracked `.gitignore`, because the work repository belongs to
someone else. That split is deliberate: the transcript is the model's own output,
and the model's input is the repository, so it does not belong on the host's disk.
See `docs/decisions.md`.

There is a third, interactive mode alongside those two: `agentbox claude <repo>`
becomes the box's **standing session**, hands work out with `abx handoff`, and
receives work through `agentbox request`. It is worth reading
[daily-use.md](daily-use.md), "Two sessions, one mount", before you rely on it —
in particular that a request reaches an idle session only at its next prompt.

After every run the transcript, `git status` and both diffs are checked for
fragments of the token. If one turns up, the run exits 3 with a loud warning and
you should rotate the token immediately.

## 6. Quota

The token draws on the **same** five-hour and weekly limits as any other device
signed in to your account. A long unattended run in the VM is a run you cannot
do elsewhere that evening. Default to `sonnet`, which is what `agentbox run`
uses unless told otherwise, and reach for a larger model deliberately.

## 7. Decommissioning and rotation

Before you delete anything, ask what only that box holds:

```
./bin/agentbox triage ~/dev/my-e2e-tests
```

It answers `keep`, `pause`, `remove` or `ask`, and it prints what is only inside
the box beside the verdict: run transcripts, the standing session's state,
repositories in the guest home, Docker volumes. `ask` means something there needs
a person's judgement — an unread handoff, a queued request, commits on an `agent/`
branch that are on no remote. `pause` is `agentbox stop`; `remove` is the command
below.

```
./bin/agentbox destroy ~/dev/my-e2e-tests
```

That deletes the VM and its disk image, and with it the token file, the box's
host-side record (`instances/<instance>`) and its bench if it had one. Two things
stay, both deliberately: the mailbox under `<repo>/.agent-box/channel/`, because
it is in the repository directory and that is yours, and this host's matching
channel record under `~/.config/agent-box/channel/<instance>/`, so that a box you
recreate under the same name does not re-announce every message the old one sent.
Delete both by hand if you want a clean slate. Then revoke the token itself at
**claude.ai → Settings → Claude Code**. Both halves matter: deleting the VM
removes the copy, revoking removes the credential.

Rotating is the same two steps in reverse: revoke the old token, mint a new one
with `claude setup-token`, run `agentbox token` again.

If this was your last instance, `rm -rf ~/.lima` reclaims the per-instance disk
images. The downloaded base images are cached separately, under
`~/Library/Caches/lima/download`, and survive that; `limactl prune` clears them,
or delete the directory. Expect a couple of gigabytes there.

One thing to be aware of: **"log out of all devices" is reported not to revoke
tokens minted with `claude setup-token`.** I have not verified this myself —
treat the explicit revoke in Settings → Claude Code as the only action you can
rely on.

## 8. Known unknowns

These are unresolved. None of them is a reason not to start; all of them are
reasons to try the setup before you depend on it.

- **MDM may block virtualization.** Some device-management profiles restrict
  Virtualization.framework. There is no evidence either way for this machine.
  If `agentbox create` fails at boot rather than at download, this is the first
  thing to check.
- **A TLS-intercepting proxy** will break the VM's HTTPS until you supply
  `ca.pem` (step 3). The symptom is certificate errors from `curl` and from
  `claude` inside the guest.
- **A managed Claude Code configuration** can restrict which accounts may sign
  in on a device. If it applies to the whole machine rather than to an
  installed copy of the CLI, it may reach into the VM too.
- **Telemetry hosts are not on the allowlist.** `DISABLE_TELEMETRY=1` and
  `DISABLE_ERROR_REPORTING=1` are set in the guest, so nothing should try to
  reach them. If a future version of the CLI needs a host that is blocked, the
  symptom will be a hang or a slow start, and
  `journalctl -u agent-box-firewall` plus a `curl` from inside the guest will
  identify it.
