"""Unit tests for polish.py — LLM mocked, no network. Run: pytest -q tests/"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import polish  # noqa: E402


@pytest.fixture
def cfgdir(tmp_path):
    d = tmp_path / "dictate"
    d.mkdir()
    for f in ("prompt.md", "corrections.json", "snippets.json", "jargon.txt", "settings.json"):
        (d / f).write_bytes((ROOT / "config" / f).read_bytes())
    return d


@pytest.fixture
def cfg(cfgdir):
    return polish.Config.load(cfgdir)


class FakeLLM:
    """Records what it was asked and returns a canned answer."""

    def __init__(self, reply=None, error=None):
        self.reply, self.error, self.calls = reply, error, []

    def __call__(self, system_prompt, text, previous, cfg):
        self.calls.append({"system": system_prompt, "text": text, "previous": previous})
        if self.error:
            raise polish.LLMError(self.error)
        return self.reply if self.reply is not None else text


# U1 ------------------------------------------------------------------------
def test_u1_fillers_reach_llm_and_are_gone(cfg):
    llm = FakeLLM(reply="Hello there, how are you doing today?")
    r = polish.polish("um so uh hello there how are you doing today", cfg, llm=llm)
    assert llm.calls and "um" in llm.calls[0]["text"]
    assert r.llm_used and "um" not in r.final.split() and "uh" not in r.final.split()


# U2 ------------------------------------------------------------------------
def test_u2_self_correction(cfg):
    llm = FakeLLM(reply="Send it Friday.")
    r = polish.polish("send it monday actually delete that send it friday", cfg, llm=llm)
    assert "Friday" in r.final and "Monday" not in r.final


# U3 ------------------------------------------------------------------------
def test_u3_dictionary_before_llm(cfg):
    llm = FakeLLM()
    r = polish.polish("the kuber netties cluster is down again right now", cfg, llm=llm)
    assert "Kubernetes" in llm.calls[0]["text"]
    assert "Kubernetes" in r.corrected


def test_u3b_corrections_are_whole_word_and_case_insensitive():
    c = {"kuber netties": "Kubernetes", "pop os": "Pop!_OS"}
    assert polish.apply_corrections("KUBER   NETTIES rocks", c) == "Kubernetes rocks"
    assert polish.apply_corrections("popos is not pop os", c) == "popos is not Pop!_OS"


# U4 ------------------------------------------------------------------------
def test_u4_snippet_skips_llm(cfg):
    llm = FakeLLM()
    r = polish.polish("My email address.", cfg, llm=llm)
    assert r.final == cfg.snippets["my email address"]
    assert not llm.calls and r.reason == "snippet"


# U5 ------------------------------------------------------------------------
def test_u5_short_input_skips_llm(cfg):
    llm = FakeLLM()
    r = polish.polish("just four words here", cfg, llm=llm)
    assert not llm.calls and not r.llm_used and r.reason == "short"
    assert r.final == "just four words here"


# U6 ------------------------------------------------------------------------
def test_u6_length_guard_rejects_growth(cfg):
    src = "please deploy the new build to staging tonight"
    llm = FakeLLM(reply=src + " " + "and here is a lot of invented text that should never appear")
    r = polish.polish(src, cfg, llm=llm)
    assert r.final == r.corrected and not r.llm_used and r.reason == "length_guard"


def test_u6b_length_guard_rejects_summary_but_allows_self_correction():
    assert not polish.within_length_budget("a" * 100, "a" * 10, 0.3, 0.75)   # 90% gone: summary
    assert polish.within_length_budget("a" * 100, "a" * 30, 0.3, 0.75)       # 70% gone: correction
    assert polish.within_length_budget("a" * 100, "a" * 125, 0.3, 0.75)
    assert not polish.within_length_budget("a" * 100, "a" * 140, 0.3, 0.75)


# U7 ------------------------------------------------------------------------
def test_u7_think_block_and_quotes_stripped(cfg):
    llm = FakeLLM(reply='<think>reasoning…</think>\n"Please deploy the new build to staging tonight."')
    r = polish.polish("please deploy the new build to staging tonight", cfg, llm=llm)
    assert r.final == "Please deploy the new build to staging tonight."


def test_u7b_clean_llm_output_edge_cases():
    assert polish.clean_llm_output("<think>a") == ""
    assert polish.clean_llm_output("“x”") == "x"
    assert polish.clean_llm_output("  y  ") == "y"


# U8 ------------------------------------------------------------------------
def test_u8_llm_unreachable_falls_back(cfg):
    llm = FakeLLM(error="connection refused")
    r = polish.polish("please deploy the new build to staging tonight", cfg, llm=llm)
    assert r.final == r.corrected and not r.llm_used and r.reason.startswith("llm_error")


def test_u8b_real_call_against_closed_port_times_out_quickly(cfg):
    cfg.settings["ollama_url"] = "http://127.0.0.1:9/api/chat"
    cfg.settings["llm_timeout_s"] = 1.0
    with pytest.raises(polish.LLMError):
        polish.call_llm("sys", "text", "", cfg)


# U9 ------------------------------------------------------------------------
def test_u9_terminal_style_in_prompt(cfg):
    llm = FakeLLM()
    polish.polish("list all the files in the current directory please", cfg,
                  app_id="com.system76.CosmicTerm", llm=llm)
    assert "terminal:" in llm.calls[0]["system"]
    assert polish.style_for("com.system76.CosmicTerm") == "terminal"
    assert polish.style_for("org.mozilla.firefox") == "unknown"


def test_u9b_app_id_file_freshness(cfg, cfgdir):
    p = cfgdir / "app_id"
    p.write_text("Alacritty\n")
    assert polish.current_app_id(cfg, cfgdir) == "Alacritty"
    old = os.path.getmtime(p) - 60
    os.utime(p, (old, old))
    assert polish.current_app_id(cfg, cfgdir) == "unknown"


# U10 -----------------------------------------------------------------------
def test_u10_end_to_end_logs_one_line(cfgdir, tmp_path):
    log = tmp_path / "log.jsonl"
    env = dict(os.environ, DICTATE_CONFIG_DIR=str(cfgdir), DICTATE_LOG=str(log),
               VOXTYPE_CONTEXT="")
    # settings point at a closed port so the real script exercises the fallback path
    s = json.loads((cfgdir / "settings.json").read_text())
    s.update({"ollama_url": "http://127.0.0.1:9/api/chat", "llm_timeout_s": 0.5})
    (cfgdir / "settings.json").write_text(json.dumps(s))

    out = subprocess.run([sys.executable, str(ROOT / "polish.py")],
                         input="send it monday actually delete that send it friday",
                         capture_output=True, text=True, env=env, timeout=10)
    assert out.returncode == 0
    assert out.stdout == "send it monday actually delete that send it friday"
    lines = log.read_text().splitlines()
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert set(entry) == {"ts", "app_id", "raw", "corrected", "final", "llm_used", "reason", "latency_ms"}
    assert entry["llm_used"] is False and entry["reason"].startswith("llm_error")


def test_empty_input_prints_nothing(cfgdir, tmp_path):
    env = dict(os.environ, DICTATE_CONFIG_DIR=str(cfgdir), DICTATE_LOG=str(tmp_path / "l.jsonl"))
    out = subprocess.run([sys.executable, str(ROOT / "polish.py")], input="  \n",
                         capture_output=True, text=True, env=env, timeout=10)
    assert out.returncode == 0 and out.stdout == ""


def test_previous_context_is_forwarded(cfg):
    llm = FakeLLM()
    polish.polish("and then we can merge it after the tests pass", cfg, previous="Open the PR.", llm=llm)
    assert llm.calls[0]["previous"] == "Open the PR."


def test_prompt_has_no_unfilled_slots(cfg):
    p = polish.build_prompt(cfg, "unknown")
    assert "{APP_CONTEXT}" not in p and "{JARGON_LIST}" not in p
    assert "Kubernetes" in p
