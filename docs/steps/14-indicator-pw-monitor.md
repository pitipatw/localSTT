# Step 14 — Indicator: stop idle `pw-dump` polling

**Roadmap row:** 14 · **Branch:** improve/14-indicator-pw-monitor · **Issue:** #6 · **PR:** pending · **Merge commit:** pending

## What changed
`dictate-indicator` no longer runs `pw-dump` every 500 ms. `PipeWireWatcher` now runs one
long-lived `pw-dump --monitor --no-colors` and folds its change stream into a live node table
(`GraphMonitor`, pure and unit-tested). The PipeWire source still lights the glow on its own,
even when the state file says idle, as before. If the monitor exits (for example when PipeWire
restarts), the source reads "not active" and the monitor is restarted after 5 s.
`--pipewire-poll-ms` keeps its name and its `0 = off` meaning. Any other value just turns
the PipeWire source on. Files: `indicator.py`, `tests/test_indicator.py`, this report,
`docs/ROADMAP.md`, `CHANGELOG.md`.

## Why
Issue #6. Each poll created a new PipeWire client *and* a new session D-Bus connection.
That is ~1.9 of each per second, all day, and every one is broadcast to the whole desktop
(`NameOwnerChanged`, registry add/remove). Measured on pop-os: the indicator alone used ~2.3 %
of one core while idle. The session-bus connection counter grew at exactly the poll rate.
On 2026-10-26, 10-27 and 10-28 `cosmic-applet-audio` froze in an eventfd busy-loop, each time
alongside a D-Bus "does not have the resources" disconnect wave.
**Not verified:** that the churn triggers that freeze. This step removes the churn; whether
the freezes stop is the pop-os observation below.

A design note: the issue also offered "poll only while the state file says recording". That
would have dropped the independent ground-truth check (`tests/test_indicator.py` I4: "PipeWire
says the mic is open: believe it"). The monitor keeps it and is cheaper still.

## How it was verified
- cloud: `python3 -m pytest -q tests/` → `87 passed` (82 before; 5 new I7 tests). Among them,
  `test_i7_watcher_starts_one_monitor_not_a_poll` uses a fake `pw-dump` to assert exactly one
  invocation over 1.2 s; the old watcher would have made three.
  `python3 -m py_compile indicator.py` ok; `bash -n install.sh` ok; `shellcheck -S warning install.sh` ok.
- pop-os, watcher only (no GTK), against the live PipeWire graph, using `pw-record` as the
  capture app: capture seen 0.12 s after start, end seen at once, a single
  `pw-dump --monitor` child, clean stop (thread joined, child exit 0). Idle over 30 s: watcher
  0.03 % CPU, its `pw-dump` 0.00 %. The old installed indicator measured 5.1 % including children.
- pop-os, still to do (Pitipat):
  ```bash
  git pull && ./install.sh indicator && systemctl --user restart dictate-indicator
  ```
  Good looks like:
  - `pgrep -a pw-dump` shows exactly one `pw-dump --monitor --no-colors` that stays the same PID.
  - `journalctl --user -u dictate-indicator -n 3` says `pipewire monitor on`.
  - A dictation still lights the glow and clears it at the end.
  - After 10 idle minutes, `ps -o time= -C python3` for the indicator has barely moved.
  - The PipeWire client `object.serial` no longer climbs ~7 000 an hour.
  - Over the following days, `cosmic-applet-audio` stays flat in `~/.local/state/audio-cpu-monitor.log`.

## Numbers
Idle indicator CPU: ~2.3 % of a core (15 h hourly log, 2026-10-24) → 0.03 % (30 s watcher-only sample).
New PipeWire clients + session-bus connections from the indicator: ~1.9/s each → 1 each per run.

## How to revert
`git revert -m 1 <merge-sha>`, then `./install.sh indicator` and
`systemctl --user restart dictate-indicator`. No settings or data files changed.

## Follow-ups noticed
- `docs/feature-requests/01-recording-indicator.md` still describes "pw-dump, 500 ms" polling.
  It's left as the historical spec; the module docstring is updated.
- `cosmic-applet-audio` eventfd busy-loop (cosmic-applets 1.0.15): an upstream report for
  `pop-os/cosmic-applets`. Evidence is in `~/.local/state/cosmic-applet-audio-spin-*.txt`.
