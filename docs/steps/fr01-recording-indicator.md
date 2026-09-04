# Feature request 01 — screen-edge recording indicator

**Roadmap row:** none (feature request, merged ahead of the 1.x cycle — see the note under the
steps table) · **Branch:** feature/recording-indicator · **PR:** #4 · **Merge commit:** c054fa1

## What changed
`indicator.py` (new, 384 lines) draws a coloured border on every monitor while the microphone is
open and nothing otherwise, as a layer-shell surface on the OVERLAY layer with keyboard
interactivity NONE and an empty input region. State comes from two independent sources OR'd
together: Voxtype's state file (`state_file = "auto"`) and a 500 ms `pw-dump` poll for a running
`voxtype` capture stream. The border pulses amber for the last 10 s before
`[audio] max_duration_secs` (60 s, now explicit in the configs). New installer step `indicator`
(`INDICATOR=0` opts out), `systemd/dictate-indicator.service` (restricted to AF_UNIX, no
network), INSTALL.md Step 5a, SECURITY_REVIEW H2 follow-up, 18 unit tests.

## Why
Toggle mode is the default and its failure mode is forgetting the second press: the mic stays
open and the room is transcribed and pasted. "No glow" is a fail-visible signal that the mic is
closed — or that the indicator itself is down, which the docs turn into "check `pw-top`".

## How it was verified
- cloud: `pytest -q tests/` → 60 passed; `bash -n install.sh` clean;
  `shellcheck -S warning install.sh` clean. CI green on the merge preview (PR #4).
- pop-os (Pop!_OS 24.04, COSMIC, two monitors): border drawn on both monitors while recording and
  nothing when idle; `dictate-indicator --check` passes in a plain shell; dictation into the
  Claude desktop app (Electron) pastes with the glow up; `ydotool key -d 60 42:1 110:1 110:0 42:0`
  pastes into COSMIC Text Editor; `pw-top` shows the voxtype capture stream exactly while the
  border is up and clear afterwards.
- Not verified: Alacritty paste-through, and the amber pulse at the 60 s cap.

## Defects found while verifying, fixed on the branch (`3f81a90`)
1. `_load_layer_shell_library()` searched only `$GTK4_LAYER_SHELL_LIB`, the distro package and
   the bare loader names. Pop!_OS 24.04 has no gtk4-layer-shell package, so install.sh
   source-builds into `~/.local/lib` and passes the paths to the unit as `Environment=` — which
   meant the documented `dictate-indicator --check` and `--demo` commands worked only from
   systemd and failed in a terminal. It now searches `~/.local/lib`, and adds the matching
   typelib path only when the shared object came from there, so a distro `.so` is never paired
   with a source-built typelib. Five tests (I6) cover ordering, append-once, an existing
   `GI_TYPELIB_PATH` keeping priority, and the absent-directory no-op.
2. The paste probes in INSTALL.md Step 5a and Step 6, and install.sh's closing hint, used ydotool
   0.x key names. ydotool 1.x takes `keycode:state` pairs and **exits 0 without injecting
   anything** when given a name, so a broken probe reads as a silent install failure. Step 6's
   probe predates both feature branches; fixed here rather than shipped broken a second time.
   INSTALL.md already documented the correct numeric form under Troubleshooting — only the
   probes were stale.

## How to revert
`git revert -m 1 c054fa1`, then on the machine: `systemctl --user disable --now dictate-indicator`
and delete `~/.local/bin/dictate-indicator`, `~/.config/systemd/user/dictate-indicator.service`,
and the `~/.local/lib/libgtk4-layer-shell*` / `girepository-1.0/Gtk4LayerShell-1.0.typelib` build
products.

## Follow-ups noticed
- A verification command that exits 0 while doing nothing is the failure this feature exists to
  prevent, in miniature. Roadmap row 2 (`./install.sh --check`) should assert that pasted text
  actually arrived rather than trusting ydotool's exit code.
- `local-dictation-handoff.md` carries the same 0.x key names; left alone deliberately as a
  historical record of an earlier ctrl+v design.
- Alacritty paste-through and the amber cap pulse remain unverified.
