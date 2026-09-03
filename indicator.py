#!/usr/bin/env python3
"""dictate-indicator — a screen-edge glow while the microphone is live.

Toggle mode has one failure mode: forgetting the second key press. This process
paints a coloured border around every monitor while Voxtype is recording and
draws NOTHING otherwise, so "no glow" always means "the mic is closed" — and if
this process dies mid-recording the glow disappearing is itself the signal to
check the mic (`pw-top`). It shows state only; it never sees the transcript.

Sources of truth, combined with OR (either one lights the glow):
  1. Voxtype's state file ($XDG_RUNTIME_DIR/voxtype/state, written by the daemon
     with state_file = "auto"): "recording" / "streaming" mean the mic is open.
  2. PipeWire: `pw-dump` lists a running Stream/Input/Audio node owned by the
     `voxtype` binary. This is ground truth independent of Voxtype's bookkeeping
     and costs one short subprocess per poll (off with --pipewire-poll-ms 0).

The border turns from green to a pulsing amber for the last --warn-secs before
Voxtype's own hard cap ([audio] max_duration_secs) stops the recording.

Wayland/COSMIC constraints honoured: the overlay is a layer-shell surface on the
OVERLAY layer with keyboard interactivity NONE, an empty input region and
exclusive zone -1, so it never takes focus, never eats the paste chord and never
reserves screen space. Needs python3-gi, GTK 4 and gtk4-layer-shell; polish.py
stays stdlib-only because this is a separate process.

    dictate-indicator            run (normally via the dictate-indicator user unit)
    dictate-indicator --check    verify the graphics stack is usable, exit 0/1
    dictate-indicator --demo 8   force the glow on for 8 s to test paste-through
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

RECORDING_STATES = frozenset({"recording", "streaming"})
DEFAULT_MAX_SECS = 60           # Voxtype's [audio] max_duration_secs default
DEFAULT_WARN_SECS = 10
DEFAULT_BORDER_PX = 6
STATE_POLL_MS = 100
PIPEWIRE_POLL_MS = 500
PW_DUMP_TIMEOUT_S = 2.0


# ---- pure logic (unit-tested, no GTK) -------------------------------------
class Phase(enum.Enum):
    OFF = "off"        # nothing drawn, no mapped surface
    ON = "on"          # green border: mic is open
    WARN = "warn"      # amber pulse: recording is about to hit the hard cap


def voxtype_runtime_dir() -> Path:
    """Mirror of Voxtype's Config::runtime_dir(): $XDG_RUNTIME_DIR/voxtype, else /tmp/voxtype."""
    return Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "voxtype"


def read_state(state_file: Path) -> str:
    """Current daemon state, or "stopped" when the file is absent (daemon down or never wrote)."""
    try:
        return state_file.read_text(encoding="utf-8").strip() or "stopped"
    except OSError:
        return "stopped"


def is_recording_state(state: str) -> bool:
    return state.strip() in RECORDING_STATES


def pipewire_capture_active(pw_dump: object, binary: str = "voxtype") -> bool:
    """True when the parsed `pw-dump` graph holds a running audio capture stream owned by
    `binary`. cpal opens the mic through the PipeWire ALSA plug-in, so the node carries
    application.process.binary = "voxtype"; application.name / node.name are checked as
    a fallback for other audio backends."""
    if not isinstance(pw_dump, list):
        return False
    for node in pw_dump:
        if not isinstance(node, dict) or node.get("type") != "PipeWire:Interface:Node":
            continue
        info = node.get("info") or {}
        props = info.get("props") or {}
        if not str(props.get("media.class", "")).startswith("Stream/Input/Audio"):
            continue
        owner = " ".join(str(props.get(k, "")) for k in
                         ("application.process.binary", "application.name", "node.name"))
        if binary in owner and info.get("state") == "running":
            return True
    return False


def read_max_duration(voxtype_config: Path, default: int = DEFAULT_MAX_SECS) -> int:
    """[audio] max_duration_secs from Voxtype's config.toml, or `default` when unset/unreadable."""
    try:
        import tomllib
        with voxtype_config.open("rb") as f:
            value = tomllib.load(f).get("audio", {}).get("max_duration_secs", default)
        return int(value) if int(value) > 0 else default
    except Exception:  # missing file, TOML error, wrong type: a broken config must not kill the indicator
        return default


def decide_phase(recording: bool, elapsed_s: float, max_secs: int, warn_secs: int) -> Phase:
    """Which border to draw given whether the mic is open and for how long."""
    if not recording:
        return Phase.OFF
    if warn_secs > 0 and elapsed_s >= max(max_secs - warn_secs, 0):
        return Phase.WARN
    return Phase.ON


class Tracker:
    """Folds the two sources into a Phase and remembers when recording started.
    Time is injected so the transitions are testable."""

    def __init__(self, max_secs: int, warn_secs: int, clock=time.monotonic):
        self.max_secs, self.warn_secs, self._clock = max_secs, warn_secs, clock
        self._started_at: float | None = None
        self.phase = Phase.OFF

    def update(self, state: str, pw_active: bool) -> Phase:
        recording = is_recording_state(state) or pw_active
        now = self._clock()
        if recording and self._started_at is None:
            self._started_at = now
        elif not recording:
            self._started_at = None
        elapsed = now - self._started_at if self._started_at is not None else 0.0
        self.phase = decide_phase(recording, elapsed, self.max_secs, self.warn_secs)
        return self.phase


# ---- PipeWire poller (background thread, no GTK) ---------------------------
class PipeWireWatcher:
    """Polls `pw-dump` on a thread and exposes the last answer. A missing pw-dump or a
    timeout reads as "not active" so the state file remains the only source."""

    def __init__(self, interval_ms: int, binary: str = "voxtype"):
        self.interval_s = interval_ms / 1000.0
        self.binary = binary
        self._active = False
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="pw-dump", daemon=True)

    @property
    def active(self) -> bool:
        return self._active

    def start(self) -> None:
        if self.interval_s > 0:
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._active = self.query()
            self._stop.wait(self.interval_s)

    def query(self) -> bool:
        try:
            out = subprocess.run(["pw-dump"], capture_output=True, text=True,
                                 timeout=PW_DUMP_TIMEOUT_S, check=False).stdout
            return pipewire_capture_active(json.loads(out), self.binary)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return False


# ---- GTK / layer-shell overlay ----------------------------------------------
def _load_layer_shell_library() -> None:
    """gtk4-layer-shell must be loaded before GTK touches libwayland-client (see its README).
    GTK4_LAYER_SHELL_LIB points at a source build under ~/.local; otherwise use the system copy."""
    from ctypes import CDLL
    from ctypes.util import find_library
    candidates = [os.environ.get("GTK4_LAYER_SHELL_LIB"), find_library("gtk4-layer-shell"),
                  "libgtk4-layer-shell.so.0", "libgtk4-layer-shell.so"]
    errors = []
    for c in filter(None, candidates):
        try:
            CDLL(c)
            return
        except OSError as e:
            errors.append(f"{c}: {e}")
    raise RuntimeError("libgtk4-layer-shell not found — run ./install.sh indicator\n  " + "\n  ".join(errors))


def _import_gtk():
    _load_layer_shell_library()
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell  # noqa: E402
    import cairo  # noqa: E402
    return Gdk, GLib, Gtk, Gtk4LayerShell, cairo


COLOURS = {  # r, g, b, a — chosen to read on light and dark wallpapers
    Phase.ON: (0.18, 0.80, 0.25, 0.92),
    Phase.WARN: (0.98, 0.62, 0.05, 0.95),
}
CSS = "window.dictate-indicator { background-color: transparent; }"


def _log(msg: str) -> None:
    print(f"dictate-indicator: {msg}", file=sys.stderr, flush=True)


def run_overlay(args) -> int:
    Gdk, GLib, Gtk, LayerShell, cairo = _import_gtk()
    if not LayerShell.is_supported():
        _log("compositor does not support wlr-layer-shell; nothing to draw")
        return 1

    class GlowWindow(Gtk.Window):
        """One transparent full-monitor surface that draws only a border."""

        def __init__(self, app, monitor, get_phase, get_pulse):
            super().__init__(application=app, title="dictate-indicator", decorated=False)
            self.add_css_class("dictate-indicator")
            self._get_phase, self._get_pulse = get_phase, get_pulse
            LayerShell.init_for_window(self)
            LayerShell.set_namespace(self, "dictate-indicator")
            LayerShell.set_layer(self, LayerShell.Layer.OVERLAY)
            LayerShell.set_monitor(self, monitor)
            for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM,
                         LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
                LayerShell.set_anchor(self, edge, True)
            LayerShell.set_exclusive_zone(self, -1)                       # reserve no space
            LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.NONE)  # never take keys
            self.area = Gtk.DrawingArea()
            self.area.set_draw_func(self._draw)
            self.set_child(self.area)
            self.connect("realize", self._make_click_through)

        def _make_click_through(self, *_):
            # Empty input region: pointer events go to whatever is underneath.
            self.get_surface().set_input_region(cairo.Region())

        def _draw(self, _area, cr, width, height):
            phase = self._get_phase()
            if phase is Phase.OFF:
                return
            r, g, b, a = COLOURS[phase]
            if phase is Phase.WARN and not self._get_pulse():
                a *= 0.35
            cr.set_source_rgba(r, g, b, a)
            cr.set_line_width(args.width * 2)   # half of the stroke falls outside the surface
            cr.rectangle(0, 0, width, height)
            cr.stroke()

    class Indicator:
        def __init__(self, app):
            self.app = app
            css = Gtk.CssProvider()
            css.load_from_data(CSS)   # otherwise the theme paints an opaque window background
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            self.tracker = Tracker(args.max_secs, args.warn_secs)
            self.pw = PipeWireWatcher(args.pipewire_poll_ms)
            self.windows: dict[object, GlowWindow] = {}
            self.pulse = True
            self.demo_until = time.monotonic() + args.demo if args.demo else None
            self.last_logged = Phase.OFF
            display = Gdk.Display.get_default()
            self.monitors = display.get_monitors()
            self.monitors.connect("items-changed", lambda *_: self._sync_monitors())
            self._sync_monitors()
            self.pw.start()
            GLib.timeout_add(args.poll_ms, self._tick)
            GLib.timeout_add(400, self._pulse_tick)

        def _sync_monitors(self):
            current = [self.monitors.get_item(i) for i in range(self.monitors.get_n_items())]
            for gone in [m for m in self.windows if m not in current]:
                self.windows.pop(gone).destroy()
            for m in current:
                if m not in self.windows:
                    self.windows[m] = GlowWindow(self.app, m, lambda: self.tracker.phase,
                                                 lambda: self.pulse)
            self._apply()

        def _tick(self):
            state = read_state(args.state_file)
            if self.demo_until is not None:
                if time.monotonic() < self.demo_until:
                    state = "recording"
                else:
                    self.demo_until = None
                    _log("demo over")
            before = self.tracker.phase
            after = self.tracker.update(state, self.pw.active)
            if after is not before:
                _log(f"{before.value} -> {after.value} (state={state!r}, pipewire={self.pw.active})")
                self._apply()
            return True

        def _pulse_tick(self):
            if self.tracker.phase is Phase.WARN:
                self.pulse = not self.pulse
                for w in self.windows.values():
                    w.area.queue_draw()
            return True

        def _apply(self):
            """Map surfaces only while there is something to show, so an idle indicator
            holds no layer surface at all (checkable with the compositor's surface list)."""
            visible = self.tracker.phase is not Phase.OFF
            for w in self.windows.values():
                if visible:
                    w.present()
                    w.area.queue_draw()
                else:
                    w.set_visible(False)

    holder = {}

    def on_activate(app):
        app.hold()   # no visible window at idle: keep the main loop alive anyway
        holder["indicator"] = Indicator(app)

    app = Gtk.Application(application_id="io.github.localstt.indicator")
    app.connect("activate", on_activate)
    _log(f"watching {args.state_file} (max {args.max_secs}s, warn {args.warn_secs}s, "
         f"pipewire poll {args.pipewire_poll_ms}ms)")
    return app.run([])


def run_check() -> int:
    """Installer verification: can the graphics stack be loaded and does the compositor speak layer-shell?"""
    try:
        _, _, _, LayerShell, _ = _import_gtk()
    except Exception as e:  # ImportError, ValueError (gi version), RuntimeError
        print(f"FAIL: {e}")
        return 1
    if not os.environ.get("WAYLAND_DISPLAY"):
        print("ok: GTK4 + gtk4-layer-shell importable (no WAYLAND_DISPLAY here, compositor check skipped)")
        return 0
    if not LayerShell.is_supported():
        print("FAIL: compositor does not advertise wlr-layer-shell")
        return 1
    print(f"ok: GTK4 + gtk4-layer-shell {LayerShell.get_major_version()}.{LayerShell.get_minor_version()}"
          f".{LayerShell.get_micro_version()}, compositor supports layer-shell")
    return 0


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], add_help=True)
    p.add_argument("--state-file", type=Path, default=voxtype_runtime_dir() / "state",
                   help="Voxtype state file (default: $XDG_RUNTIME_DIR/voxtype/state)")
    p.add_argument("--voxtype-config", type=Path,
                   default=Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "voxtype" / "config.toml")
    p.add_argument("--max-secs", type=int, default=None,
                   help="recording hard cap; default: [audio] max_duration_secs from the Voxtype config")
    p.add_argument("--warn-secs", type=int, default=DEFAULT_WARN_SECS,
                   help="amber pulse for the last N seconds before the cap (0 = never)")
    p.add_argument("--width", type=int, default=DEFAULT_BORDER_PX, help="border width in px")
    p.add_argument("--poll-ms", type=int, default=STATE_POLL_MS, help="state file poll interval")
    p.add_argument("--pipewire-poll-ms", type=int, default=PIPEWIRE_POLL_MS,
                   help="pw-dump poll interval; 0 disables the PipeWire cross-check")
    p.add_argument("--demo", type=float, default=0, metavar="SECS",
                   help="show the glow for SECS seconds regardless of state (paste-through test)")
    p.add_argument("--check", action="store_true", help="verify the graphics stack and exit")
    args = p.parse_args(argv)
    if args.max_secs is None:
        args.max_secs = read_max_duration(args.voxtype_config)
    return args


def main(argv) -> int:
    args = parse_args(argv)
    if args.check:
        return run_check()
    return run_overlay(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
