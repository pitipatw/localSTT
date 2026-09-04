# Feature request: make it obvious when the mic is live (toggle mode)

**Why.** Toggle mode is now the default (`install.sh`, SECURITY_REVIEW.md H2). Its one failure mode is
forgetting to press the shortcut a second time: the mic stays open, and everything the room says is
transcribed and pasted when it is finally stopped. The output sanitizer makes that harmless in a
terminal, but not embarrassing in a chat window. The user needs an always-visible, can't-miss signal
that recording is on — and *nothing* when it is off.

**Constraints (non-negotiable).**
- Must work on COSMIC (Wayland). No X11-only tricks, no `input` group, no extra privileges.
- Must not steal focus or change which window receives the paste (`[osd] enabled = false` exists for
  exactly this reason — see `config/voxtype.config.toml`).
- Must fail *visible*: if the indicator process dies while recording, the user should still be able
  to tell (e.g. the indicator disappearing is itself a "check the mic" signal — document this).
- Must not add a dependency to `polish.py` (stdlib only) — the indicator is a separate component.
- Should not leak content: the indicator shows *state*, never the transcript.

**Trigger source.** Voxtype's daemon knows the state. Options, in order of preference:
1. `voxtype` hooks / events if 1.0.x exposes a "recording started/stopped" hook (check
   `voxtype.io/docs/CONFIGURATION`; a `[hooks]`-style `on_record_start` / `on_record_stop` command
   would be ideal).
2. Wrap the shortcut: the COSMIC custom shortcut runs a tiny `dictate-toggle` script that calls
   `voxtype record toggle`, then queries state (`voxtype status`, if it exists) and starts/stops the
   indicator. Simple, no daemon polling; the indicator is only as accurate as the toggle script.
3. Poll `pw-top`/`pw-dump` for a `voxtype` capture stream (ground truth: the mic is actually open).
   Robust and independent of Voxtype, costs a ~250 ms poll. Good fallback and good *verification*
   for options 1–2 (an indicator driven by the real PipeWire stream can never lie).

**Indicator options to explore (pick one, or combine a primary and a secondary).**

| Option | How | Pros | Cons / risks |
|---|---|---|---|
| A. Screen-edge glow ("edges turn green") | A layer-shell overlay: a transparent full-screen surface with a 4–6 px coloured border, `layer = overlay`, `keyboard_interactivity = none`, `exclusive_zone = -1` so it never takes focus or space. Implement with `gtk4-layer-shell` (Python `gi` bindings) or a ~40-line `wlr-layer-shell` client. Colour: green while recording, red pulse for the last N s of a max-record cap, nothing when off. | Visible in every app and at every screen position; impossible to miss; zero focus impact when configured correctly | Needs a Wayland layer-shell library (new dependency, though only for the indicator). Verify COSMIC's compositor accepts `wlr-layer-shell` overlays (it does for panels/notifications). Must be tested with the paste chord to prove it does not intercept Shift+Insert. Multi-monitor: one surface per output. |
| B. Panel/tray item | COSMIC applet or StatusNotifierItem showing a red dot / mic icon while recording | Small, conventional, no full-screen surface | Easy to miss in a corner; COSMIC applet API is Rust/iced, heavier to build; tray support varies |
| C. Cursor change | Change the pointer cursor theme/shape while recording | Follows the eye | Hard on Wayland without compositor cooperation; not reliable |
| D. Audible cue | Short tone on start, different tone on stop, optional soft tick every 30 s while recording | No graphics stack at all; works with eyes off screen | Annoying in meetings; the "still recording" tick is the useful part and the annoying part |
| E. Keyboard backlight / LED | Set a keyboard LED (e.g. Scroll Lock) or QMK RGB via `ledctl`/raw HID while recording | Physical, glanceable | Needs write access to the LED device (udev rule) — do NOT solve this with the `input` group; hardware-specific |
| F. Hard cap + auto-stop | Not an indicator: daemon stops recording after N s (default 60–90) and pastes what it has | Bounds the damage of *every* other option failing | Interrupts legitimately long dictation; make N configurable |

**Recommendation to try first.** A (edge glow) as the primary signal, driven by option 3 (PipeWire
stream presence) or 1 (hook) as the source of truth, plus F as a backstop. B is a reasonable
secondary if A proves flaky on COSMIC.

**Definition of done.**
- With the mic on, the indicator is visible on every monitor in every app; with it off, nothing is
  drawn and no process is holding a surface.
- `pw-top` shows the capture stream only while the indicator is shown (and vice versa).
- Paste still lands in the focused window while the overlay is up (test in a GTK app, an Electron
  app, and Alacritty).
- The indicator process runs as the user, is not in `input`, and has no network.
- Installer step `indicator` is idempotent and documented in INSTALL.md; `HOTKEY_MODE=toggle`
  installs it by default with an opt-out.
- SECURITY_REVIEW.md gets a one-paragraph note under H2.
