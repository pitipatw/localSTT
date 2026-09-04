"""Unit tests for hotkeyd/hotkeyd.py and hotkeyd/hotkey-relay — synthetic input_event bytes, no devices.
Run: pytest -q tests/"""

import importlib.machinery
import importlib.util
import struct
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load(path, name):
    """Import a script by path (hotkey-relay has no .py suffix, so name the loader explicitly)."""
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


hotkeyd = load(ROOT / "hotkeyd" / "hotkeyd.py", "hotkeyd")
relay = load(ROOT / "hotkeyd" / "hotkey-relay", "hotkey_relay")

KEY_A = 30
EV_SYN = 0


def ev(etype, code, value):
    """One struct input_event as the kernel writes it (timestamp irrelevant to the daemon)."""
    return struct.pack(hotkeyd.EVENT_FMT, 0, 0, etype, code, value)


def f13(value):
    return ev(hotkeyd.EV_KEY, hotkeyd.KEY_F13, value)


# ---- event decoding ---------------------------------------------------------
def test_event_size_matches_kernel_layout():
    assert hotkeyd.EVENT_SIZE == 24 and len(f13(1)) == 24


def test_press_then_release_emits_start_stop():
    t = hotkeyd.HoldTracker()
    assert t.feed(f13(hotkeyd.PRESS), now=10.0) == ["start"]
    assert t.feed(f13(hotkeyd.RELEASE), now=10.5) == ["stop"]


def test_several_events_in_one_read_are_all_decoded():
    t = hotkeyd.HoldTracker()
    buf = f13(1) + ev(EV_SYN, 0, 0) + f13(0) + ev(EV_SYN, 0, 0)
    assert t.feed(buf, now=1.0) == ["start", "stop"]


# ---- filtering: nothing but F13 is ever acted on ---------------------------
@pytest.mark.parametrize(
    "buf",
    [
        ev(hotkeyd.EV_KEY, KEY_A, 1) + ev(hotkeyd.EV_KEY, KEY_A, 0),   # another key
        ev(2, hotkeyd.KEY_F13, 1),                                     # F13 code but not EV_KEY (EV_REL)
        ev(EV_SYN, 0, 0),                                              # sync marker
        b"",                                                           # timer tick
    ],
)
def test_other_events_are_ignored(buf):
    t = hotkeyd.HoldTracker()
    assert t.feed(buf, now=1.0) == [] and t.down_since is None


def test_autorepeat_is_ignored():
    t = hotkeyd.HoldTracker()
    assert t.feed(f13(1), now=1.0) == ["start"]
    assert t.feed(f13(2) * 5, now=1.5) == []                          # value 2 = repeat while held
    assert t.feed(f13(0), now=2.0) == ["stop"]


def test_release_without_press_and_double_press_do_nothing():
    t = hotkeyd.HoldTracker()
    assert t.feed(f13(0), now=1.0) == []                              # e.g. daemon started mid-hold
    assert t.feed(f13(1), now=2.0) == ["start"]
    assert t.feed(f13(1), now=2.1) == []                              # duplicate press from a 2nd keyboard


# ---- hold cap ---------------------------------------------------------------
def test_hold_cap_stops_on_timer_and_ignores_the_late_release():
    t = hotkeyd.HoldTracker(max_hold_s=60)
    assert t.feed(f13(1), now=0.0) == ["start"]
    assert t.feed(b"", now=59.9) == []
    assert t.feed(b"", now=60.0) == ["stop"]
    assert t.feed(b"", now=61.0) == []                                # stop is emitted once
    assert t.feed(f13(0), now=70.0) == []                             # the eventual release is not a 2nd stop
    assert t.feed(f13(1), now=71.0) == ["start"]                      # and the next press works again


def test_hold_cap_can_fire_in_the_same_read_as_a_new_press():
    t = hotkeyd.HoldTracker(max_hold_s=1)
    t.feed(f13(1), now=0.0)
    assert t.feed(f13(0) + f13(1), now=5.0) == ["stop", "start"]     # cap first, release dropped, press counts


# ---- relay allow-list -------------------------------------------------------
@pytest.mark.parametrize("line,expected", [
    (b"start\n", "start"), (b"stop\n", "stop"), (b"  stop \r\n", "stop"),
    (b"start; rm -rf ~\n", None), (b"START\n", None), (b"\n", None), (b"\xff\xfe\n", None),
])
def test_relay_accepts_only_start_and_stop(line, expected):
    assert relay.command_for(line) == expected


# H6 runtime-directory wiring ------------------------------------------------
# Regression guard for a bug found on pop-os: the unit used RuntimeDirectory= plus an
# ExecStartPre chgrp/chmod to give /run/hotkeyd the user's group and the setgid bit. systemd
# rebuilds a runtime directory's owner and mode for every Exec* invocation, so the ExecStartPre
# was undone before ExecStart ran; the socket came out hotkeyd:hotkeyd inside a 0750
# hotkeyd:hotkeyd directory, unreachable by the relay.
UNIT = (ROOT / "systemd" / "hotkeyd.service").read_text()
TMPFILES = (ROOT / "systemd" / "hotkeyd.tmpfiles.conf").read_text()
# directives only: the comments in both files describe the bug and name the directives involved
UNIT_DIRECTIVES = "\n".join(l for l in UNIT.splitlines() if l and not l.startswith("#"))


def test_h6_unit_does_not_manage_the_runtime_directory():
    assert "RuntimeDirectory=" not in UNIT_DIRECTIVES, \
        "systemd re-applies RuntimeDirectory owner/mode per Exec*, undoing any ExecStartPre chgrp"
    assert "chgrp" not in UNIT_DIRECTIVES, "the group is set by the tmpfiles rule, not an ExecStartPre"


def test_h6_unit_can_still_write_the_runtime_directory_and_clears_a_stale_socket():
    assert "ProtectSystem=strict" in UNIT
    assert "ReadWritePaths=/run/hotkeyd" in UNIT, "ProtectSystem=strict makes /run read-only"
    assert "ExecStartPre=+/bin/rm -f /run/hotkeyd/hotkey.sock" in UNIT, \
        "nothing cleans the socket on stop now; bind() fails on a stale one"


def test_h6_tmpfiles_rule_is_setgid_and_owned_by_the_user_group():
    rules = [l for l in TMPFILES.splitlines() if l and not l.startswith("#")]
    assert rules == ["d /run/hotkeyd 2750 hotkeyd @USER@ -"]


def test_h6_installer_renders_and_applies_the_tmpfiles_rule():
    sh = (ROOT / "install.sh").read_text()
    assert 'render_unit "$REPO/systemd/hotkeyd.tmpfiles.conf"' in sh
    assert "systemd-tmpfiles --create" in sh
    assert '"2750 hotkeyd $ME"' in sh, "the installer must verify the directory it just created"
