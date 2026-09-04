"""Unit tests for indicator.py — the state logic only; no GTK, no Wayland, no pw-dump.
Run: pytest -q tests/"""

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import indicator  # noqa: E402
from indicator import Phase  # noqa: E402


def pw_node(media_class="Stream/Input/Audio", binary="voxtype", state="running", name=None):
    props = {"media.class": media_class, "application.process.binary": binary}
    if name:
        props["application.name"] = name
    return {"type": "PipeWire:Interface:Node", "info": {"state": state, "props": props}}


# I1 state file -------------------------------------------------------------
def test_i1_state_file_absent_means_stopped(tmp_path):
    assert indicator.read_state(tmp_path / "missing") == "stopped"
    f = tmp_path / "state"
    f.write_text("recording\n")
    assert indicator.read_state(f) == "recording"
    f.write_text("")
    assert indicator.read_state(f) == "stopped"


@pytest.mark.parametrize("state,expected", [
    ("recording", True), ("streaming", True), ("recording\n", True),
    ("idle", False), ("transcribing", False), ("stopped", False), ("", False),
])
def test_i1_recording_states(state, expected):
    assert indicator.is_recording_state(state) is expected


# I2 PipeWire ground truth --------------------------------------------------
def test_i2_pipewire_running_voxtype_capture_is_active():
    assert indicator.pipewire_capture_active([pw_node()]) is True


def test_i2_pipewire_ignores_other_streams_and_states():
    assert indicator.pipewire_capture_active([pw_node(binary="firefox")]) is False
    assert indicator.pipewire_capture_active([pw_node(media_class="Stream/Output/Audio")]) is False
    assert indicator.pipewire_capture_active([pw_node(state="suspended")]) is False
    assert indicator.pipewire_capture_active([pw_node(state="idle")]) is False


def test_i2_pipewire_matches_alsa_plugin_name_when_binary_missing():
    node = pw_node(binary="", name="ALSA plug-in [voxtype]")
    assert indicator.pipewire_capture_active([node]) is True


def test_i2_pipewire_tolerates_garbage():
    assert indicator.pipewire_capture_active(None) is False
    assert indicator.pipewire_capture_active({}) is False
    assert indicator.pipewire_capture_active([1, "x", {"type": "PipeWire:Interface:Node"}]) is False
    assert indicator.pipewire_capture_active(json.loads("[]")) is False


# I3 hard-cap warning --------------------------------------------------------
def test_i3_phase_transitions():
    assert indicator.decide_phase(False, 100, 60, 10) is Phase.OFF
    assert indicator.decide_phase(True, 0, 60, 10) is Phase.ON
    assert indicator.decide_phase(True, 49.9, 60, 10) is Phase.ON
    assert indicator.decide_phase(True, 50, 60, 10) is Phase.WARN
    assert indicator.decide_phase(True, 500, 60, 0) is Phase.ON      # warn disabled


def test_i3_max_duration_from_config(tmp_path):
    cfg = tmp_path / "config.toml"
    assert indicator.read_max_duration(cfg) == indicator.DEFAULT_MAX_SECS   # missing file
    cfg.write_text('engine = "parakeet"\n[audio]\nmax_duration_secs = 90\n')
    assert indicator.read_max_duration(cfg) == 90
    cfg.write_text("[audio\nbroken")
    assert indicator.read_max_duration(cfg) == indicator.DEFAULT_MAX_SECS   # broken TOML
    cfg.write_text("[audio]\nmax_duration_secs = 0\n")
    assert indicator.read_max_duration(cfg) == indicator.DEFAULT_MAX_SECS   # nonsense value


# I4 tracker: OR of both sources, timer resets -------------------------------
def test_i4_tracker_lights_from_either_source_and_resets_timer():
    clock = {"t": 0.0}
    tr = indicator.Tracker(max_secs=60, warn_secs=10, clock=lambda: clock["t"])
    assert tr.update("idle", False) is Phase.OFF
    assert tr.update("idle", True) is Phase.ON            # PipeWire says the mic is open: believe it
    assert tr.update("recording", False) is Phase.ON
    clock["t"] = 55
    assert tr.update("recording", False) is Phase.WARN
    assert tr.update("idle", False) is Phase.OFF
    clock["t"] = 56
    assert tr.update("recording", False) is Phase.ON      # new recording: timer restarted


def test_i4_tracker_state_file_vanishing_turns_off():
    tr = indicator.Tracker(60, 10, clock=lambda: 0.0)
    tr.update("recording", False)
    assert tr.update("stopped", False) is Phase.OFF       # daemon died: fail visible


# I5 CLI --------------------------------------------------------------------
def test_i5_defaults_and_overrides(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    args = indicator.parse_args(["--voxtype-config", str(tmp_path / "none.toml")])
    assert args.state_file == tmp_path / "voxtype" / "state"
    assert args.max_secs == indicator.DEFAULT_MAX_SECS
    assert args.pipewire_poll_ms == indicator.PIPEWIRE_POLL_MS
    args = indicator.parse_args(["--max-secs", "30", "--pipewire-poll-ms", "0"])
    assert args.max_secs == 30 and args.pipewire_poll_ms == 0


def test_i5_pipewire_watcher_without_pw_dump_is_inactive(monkeypatch):
    monkeypatch.setenv("PATH", "")
    w = indicator.PipeWireWatcher(interval_ms=0)
    assert w.query() is False
    w.start()   # interval 0: no thread, no crash
    w.stop()


# I6 library / typelib discovery --------------------------------------------
def test_i6_explicit_override_is_tried_first():
    os.environ["GTK4_LAYER_SHELL_LIB"] = "/explicit/libgtk4-layer-shell.so.0"
    try:
        assert indicator.layer_shell_candidates()[0] == "/explicit/libgtk4-layer-shell.so.0"
    finally:
        del os.environ["GTK4_LAYER_SHELL_LIB"]


def test_i6_user_build_is_a_candidate_without_any_env(monkeypatch):
    monkeypatch.delenv("GTK4_LAYER_SHELL_LIB", raising=False)
    c = indicator.layer_shell_candidates()
    assert all(c), "no None entries may reach CDLL"
    assert os.path.join(indicator.USER_LIB, "libgtk4-layer-shell.so.0") in c
    assert c[-1] == "libgtk4-layer-shell.so", "bare loader names stay last"


def test_i6_user_typelib_appended_once(monkeypatch, tmp_path):
    typelib = tmp_path / "girepository-1.0"
    typelib.mkdir()
    monkeypatch.setattr(indicator, "USER_TYPELIB", str(typelib))
    monkeypatch.delenv("GI_TYPELIB_PATH", raising=False)
    indicator._add_user_typelib_path()
    assert os.environ["GI_TYPELIB_PATH"] == str(typelib)
    indicator._add_user_typelib_path()
    assert os.environ["GI_TYPELIB_PATH"] == str(typelib), "must not duplicate"


def test_i6_existing_typelib_path_keeps_priority(monkeypatch, tmp_path):
    typelib = tmp_path / "girepository-1.0"
    typelib.mkdir()
    monkeypatch.setattr(indicator, "USER_TYPELIB", str(typelib))
    monkeypatch.setenv("GI_TYPELIB_PATH", "/distro/typelibs")
    indicator._add_user_typelib_path()
    assert os.environ["GI_TYPELIB_PATH"] == "/distro/typelibs" + os.pathsep + str(typelib)


def test_i6_absent_user_typelib_is_a_noop(monkeypatch, tmp_path):
    monkeypatch.setattr(indicator, "USER_TYPELIB", str(tmp_path / "nope"))
    monkeypatch.delenv("GI_TYPELIB_PATH", raising=False)
    indicator._add_user_typelib_path()
    assert "GI_TYPELIB_PATH" not in os.environ
