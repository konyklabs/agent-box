# Contributing

Issues are welcome, for bugs, unclear docs, or a limitation worth tracking.

For a pull request:

- Run `shellcheck` on every changed script and paste clean output.
- Run `test/smoke.sh` and paste its output. `SMOKE_STOP_AFTER=<step label>` and
  `SMOKE_KEEP=1` are development aids only: a run stopped early prints
  `STOPPED AFTER <label>` above its RESULT line, and the output pasted for a
  pull request has to come from a run with neither set.
- A new host-side command gets a host-only smoke step, so the cheap half of the
  suite keeps growing with the tool. `LIMACTL=test/fake-limactl` and a throwaway
  `AGENT_BOX_CONFIG_DIR` run the host half without building a VM.
- Add nothing site-specific to the repo — hostnames, terms, or credentials
  belong in `~/.config/agent-box/`, never in a tracked file.
