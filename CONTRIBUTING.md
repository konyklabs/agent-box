# Contributing

Issues are welcome, for bugs, unclear docs, or a limitation worth tracking.

For a pull request:

- `shellcheck` is clean at its default severity over every script in the tree, so
  run it on every changed script and paste clean output. A finding is fixed, or it
  carries a `# shellcheck disable=SCxxxx` directive with a one-line reason on the
  line above it. "Clean" is a countable claim: it means zero findings, not zero
  new ones.
- Run `test/no-vm.sh` and paste its output. It needs no VM, no limactl and no
  network, runs in seconds, and is the cheapest thing that can catch a regression
  in a host helper or in the guest's text handling — so it is what a change to one
  of those is checked with while it is being written.
- Run `test/smoke.sh` and paste its output. `SMOKE_STOP_AFTER=<step label>` and
  `SMOKE_KEEP=1` are development aids only: a run stopped early prints
  `STOPPED AFTER <label>` above its RESULT line, and the output pasted for a
  pull request has to come from a run with neither set.
- A new host-side command gets a host-only smoke step, so the cheap half of the
  suite keeps growing with the tool. `LIMACTL=test/fake-limactl` and a throwaway
  `AGENT_BOX_CONFIG_DIR` run the host half without building a VM.
- Add nothing site-specific to the repo — hostnames, terms, or credentials
  belong in `~/.config/agent-box/`, never in a tracked file.
