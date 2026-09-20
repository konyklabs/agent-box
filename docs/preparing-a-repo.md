# Preparing a repository for the box

What to do to a repository, before the first `agentbox create`, so that it
mounts cleanly and an unattended run against it is worth reading. Written for
the common hard case: a monorepo with several services, one of which is the
web application under test, that can run against mocked services or against
live ones, and whose test suite grew ad hoc.

The box mounts one directory, read-write, at `/work`. That is the whole
loading mechanism. Everything below follows from it.

## 1. Mount a clone, not your working copy

```
git clone <your working copy or its remote> ~/dev/<repo>
cd ~/dev/<repo> && git checkout <branch the agent should start from>
```

Three reasons, each of which has cost an hour:

- **Environments.** A `.venv`, `node_modules` or `.tox` built on the Mac is
  macOS binaries. The guest is Linux. `uv`, `pip` and `npm` inside the guest
  rebuild it in place, and your host copy is now broken. A clone starts empty.
- **Preflight.** `agentbox create` and `agentbox start` scan the mount for
  secrets and for your blocklist terms and refuse on a finding. A working copy
  carries `.env` files, editor state, and whatever else accumulated. A clone
  carries only what is committed, which is what preflight is meant to judge.
- **Branch noise.** A run starts from the checkout's HEAD and works on a new
  `agent/` branch. A clone holds one branch you chose, not forty.

Keep the mount and your day-to-day working copy separate for as long as the
box exists. Pull the agent's branch across with `git fetch ~/dev/<repo>
agent/<branch>` when you want it.

**The host side of the same rule is the bench.** When you need to build and run
the agent's branch yourself — which is what checking a handoff means —
`agentbox bench ~/dev/<repo>` makes a clone outside the mount and checks that
branch out there. Build in it, run the project's own CI command in it, and
`~/dev/<repo>` never acquires a Linux `.venv` or a `node_modules` that the next
run overwrites. It is disposable by design: it refuses to refresh over modified
tracked files or over a commit the repository does not have, and it sees
committed work only. See [daily-use.md](daily-use.md), "The bench".

## 2. Credentials live in the guest, not in the mount

The box holds one credential by design, the model token. An application
that needs more, an OAuth client secret for a live identity provider, a
payment provider's test key, a gateway URL, gets them the same way: typed
into the guest, stored under the guest user's home, never in `/work`.

```
agentbox shell ~/dev/<repo>
# inside:
umask 077
cat > ~/app.env <<'ENV'
KEY=value
ENV
```

or, from the host, in one line with the file never printed:

```
limactl shell agent-box-<repo basename> -- sh -c 'umask 077; cat > ~/app.env' < /path/on/the/mac/.env
```

The brief then tells the agent `set -a; . ~/app.env; set +a` before commands
that need them. That line is shell, not dotenv: a value with a space or a `#`
must be quoted (`KEY='123 Main St #4'`), or the shell runs the second word as
a command and stops exporting there. A `.env` written for `python-dotenv`
tolerates unquoted spaces; `sh` does not. Quote every value when you write the
file and the same file serves both. This works with any app whose config reads the process
environment first and a `.env` file second, which is what `python-dotenv`
(`load_dotenv` does not override existing variables), `pydantic-settings`,
and `dotenv` for Node all do by default. If yours only reads a file, point it
at `~/app.env` with whatever option it has; do not write `/work/.env`.

Use test credentials only. The box's guarantees are a boundary against
carelessness, not against a hostile tool with root in its own VM.

## 3. The two modes: mocked and live

A suite that can run against mocked services and against live ones needs to
say which it is running in, and the box needs to allow the right hosts.

- **Mocked** needs no allowlist entry at all. Mocks running in the guest, as
  processes or as containers on a compose network, are reachable without a
  rule because that traffic never leaves the machine.
- **Live** needs an entry for every external host the app or the browser
  talks to: the identity provider's token and authorize endpoints, the
  payment provider's API and script hosts, your staging gateway, a CDN the
  page loads fonts from. They go in `~/.config/agent-box/guest/allowlist.local`,
  one per line, `#` for comments; a `.suffix` line covers every host under a
  domain and a CIDR covers a VPN range.

The honest first step when you do not know the list is a box in `observe`
mode: run the live suite once, read `agentbox egress-log --as-allowlist`,
keep what belongs, then `agentbox egress <repo> deny`. See
[first-run.md](first-run.md), "Recipe: observe for a week".

Make the mode switch explicit and cheap. One environment variable
(`APP_MODE=mock|live`, or whatever the repo already has) that every service
and the test configuration read, so the brief can name it in one line.

## 4. Make the suite runnable from one command per tier

Before an agent can refactor a suite, it has to be able to run it, all of
it, from the repository root, without you in the loop. Aim for:

```
<one command>   # unit: offline, seconds
<one command>   # integration: mocked services, offline, a minute
<one command>   # e2e: live, credentials, browser
```

If today the tests are scattered across services with different runners,
write those three commands down in a `tests/README.md` (or a `Makefile` /
`justfile`) even if each is a shell loop over services. The agent reads that
file first; the brief points at it. The first refactor slice can be "make
these commands true".

**Make it the command CI runs, not an equivalent of it.** The box tells the agent
this as a convention — run `mise run test`, `just check`, `make lint`, the npm
script, exactly as the workflow invokes it — because a task runner usually wraps
setup, environment and flags around the raw tool, so `ruff check .` can pass while
`mise run lint` fails. The repository's part of that bargain is that the command
exists and the workflow is readable: `actionlint` is in every box, and the agent is
told to read the workflow file rather than reconstruct the command from it.

**Pin your tools where the box can see it.** Every box carries the same baseline —
`uv`, `ruff`, Node, `mise`, `trufflehog`, `actionlint`, `dprint`, `basedpyright`,
`semgrep`, Playwright and Chromium — and `agentbox toolcheck <repo>` compares that
baseline against what the repository itself asks for: `mise.toml` and its siblings,
`.tool-versions`, `.python-version`, `.nvmrc`, `.node-version`, `pyproject.toml`,
`uv.lock`, `package.json`, `package-lock.json`, and the setup actions in the
workflow files. Exit 11 means the two differ, with `file:line` for each. The
project wins, and the findings are printed above every brief — so a repository that
pins its versions in one of those files gets a box that knows about it, and one that
pins them only in prose does not.

Two more rules that matter more in a box than on a laptop:

- **Environments outside the tree.** `UV_PROJECT_ENVIRONMENT`, a venv under
  `~/.venvs`, `npm ci` inside the service directory only. The brief should
  say so.
- **A live tier that costs something per run says so at the top of its
  README**, with the number: a real order, a real email, a rate limit that
  bites for two minutes. The agent will loop a failing test otherwise.

## 5. Ports and the browser

Playwright inside the guest drives the app inside the guest over
`127.0.0.1`; nothing needs forwarding for that. `--forward PORT` at create
time is only for you to open the app in a browser on the Mac, and it is fixed
for the box's life, so decide before `create`.

A server that must accept the Playwright browser but nothing else should bind
`127.0.0.1`. If a service checks that its clients are loopback, keep that
check; it is doing its job.

Two consequences of that being fixed at create time. `create` **refuses** a host
port something on the Mac already holds, naming the port and the process, because
a forward Lima cannot bind is a forward that silently does not answer; the same
check runs at `start`, since a port can be taken while a box is stopped. And when
a forwarded page will not load, `agentbox ports <repo>` says which side is quiet —
including the one real trap, a guest service bound to the guest's own interface
address rather than to `127.0.0.1` or `0.0.0.0`, which is a working listener that
no forward can reach.

Chromium is in every box already, shared at `$PLAYWRIGHT_BROWSERS_PATH`, so the
first test run downloads nothing. A repository that pins its own Playwright version
still installs that version in its own environment; it only needs a download if it
pins a version whose build is not the one the box has, which `toolcheck` tells you
before a test run does.

## 6. Size the box for the monorepo

A handful of services, a compose stack and a browser is not the default
profile. Start at:

```
agentbox create ~/dev/<repo> --docker --egress observe \
    --cpus 6 --memory 12GiB --disk 80GiB
```

`resize` can change all three later; the disk only grows. Without `--docker` the
defaults are 4 CPUs, 6GiB and 40GiB — the disk default allows for the toolchain,
which costs about 2.6 GiB of guest disk (measured on one Mac, 2026-09-20).

## 7. Write the brief before the run

`templates/brief.md` is the shape. For a suite refactor the definition of
done is behavioural: the same tests pass before and after, the tier commands
are unchanged or improved, no assertion weakened, output pasted. Name the
directories in scope, the ones out of scope, the commands, the cost of the
live tier, and the stop conditions. A vague brief is guesswork in the VM.

## Checklist

- [ ] Clone at `~/dev/<repo>` on the starting branch, no `.env`, no `.venv`.
- [ ] `agentbox preflight ~/dev/<repo>` exits 0, or every finding is one you
      have judged.
- [ ] Blocklist holds only terms that must never reach a model. A public
      product name in a public repository is not one.
- [ ] Credentials staged for `~/app.env` in the guest, test-tier only.
- [ ] Live hosts listed in `allowlist.local`, or the box is `observe` for the
      first run.
- [ ] One command per tier written down in the repository, and it is the command
      CI runs rather than an equivalent of it.
- [ ] Tool versions pinned in a file the box can read (`mise.toml`,
      `.tool-versions`, `pyproject.toml`, `package.json`), not only in prose;
      `agentbox toolcheck <repo>` then reports where they differ from the box's.
- [ ] The brief names the mode, the tier commands, the cost of live, and the
      stop conditions.
