#!/usr/bin/env python3
"""Voxtype post-processing hook: raw transcript on stdin -> cleaned text on stdout.

Pipeline (each stage is independently testable):

    snippets -> dictionary corrections -> [skip if short] -> LLM cleanup
             -> length guard -> log

Invariants the rest of the system relies on:
  * Always exits 0 and always prints *something* (worst case: the raw text).
    A crash here would make Voxtype paste nothing.
  * Never blocks longer than settings["llm_timeout_s"] on the LLM.
  * Uses only the Python standard library.

Data files live in $DICTATE_CONFIG_DIR (default ~/.config/dictate):
  corrections.json  {"heard phrase": "Intended Spelling"}  case-insensitive, whole-word
  snippets.json     {"spoken trigger": "expanded text"}      whole-utterance match
  jargon.txt        one term per line, injected into the prompt
  prompt.md         system prompt with {APP_CONTEXT} and {JARGON_LIST} slots
  settings.json     optional overrides of DEFAULT_SETTINGS (see README "Settings")
                    - allow_newlines (default false): keep newlines from "new line"/"new
                      paragraph" in the output. Off by default so a transcript can never
                      press Enter in a terminal; the terminal style always forces it off.
                    - ollama_url must point at loopback (localhost / 127.0.0.1 / ::1).
                      Anything else is rejected at load time.
  app_id            optional, written by an external helper; read if < 5 s old

Log: $DICTATE_LOG (default ~/.local/share/dictate/log.jsonl), one JSON object per call.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

DEFAULT_SETTINGS = {
    "ollama_url": "http://localhost:11434/api/chat",
    "model": "qwen3:8b",
    "temperature": 0.1,
    "llm_timeout_s": 4.0,
    "min_words_for_llm": 6,
    # Length guard is asymmetric: self-corrections legitimately shrink text a lot
    # ("ship monday actually delete that ship friday" -> "Ship Friday."), while
    # growth almost always means the model invented or answered something.
    "max_growth": 0.30,   # final may be at most 30% longer than input
    "max_shrink": 0.75,   # final may lose at most 75% of the input's characters
    "app_id_max_age_s": 5.0,
    # Privacy: the log stores every dictation in plaintext so you can tune the
    # dictionary and prompt. Set log_text=false to keep only metadata, or
    # log_enabled=false for no log at all. `dictate log purge` deletes it.
    "log_enabled": True,
    "log_text": False,
    # Output safety: control characters are always stripped. Newlines are dropped
    # too unless allow_newlines is true (never for the terminal style).
    "allow_newlines": False,
}

# app_id substring (lower-cased) -> style key used in prompt.md
APP_STYLES = {
    "terminal": ("cosmicterm", "cosmic-term", "alacritty", "kitty", "foot", "wezterm",
                 "gnome-terminal", "konsole", "tilix", "ghostty"),
    "code": ("code", "codium", "cursor", "zed", "jetbrains", "idea", "pycharm", "neovide"),
    "email": ("thunderbird", "evolution", "geary", "mail"),
    "chat": ("slack", "discord", "telegram", "signal", "element", "whatsapp", "line"),
}

STYLE_TEXT = {
    "terminal": "terminal: terse, no trailing period, keep code tokens and paths verbatim",
    "code": "code editor: terse, keep identifiers verbatim, no trailing period unless a full sentence",
    "email": "email: full sentences and paragraphs, polite register",
    "chat": "chat: casual, single paragraph unless 'new paragraph' is spoken",
    "unknown": "unknown app: neutral, full sentences",
}


def config_dir() -> Path:
    return Path(os.environ.get("DICTATE_CONFIG_DIR", "~/.config/dictate")).expanduser()


def log_path() -> Path:
    return Path(os.environ.get("DICTATE_LOG", "~/.local/share/dictate/log.jsonl")).expanduser()


_LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}


def validate_ollama_url(url: str) -> str:
    """Only a plain-http loopback URL is accepted: every dictation is POSTed
    here, so this setting must never be able to point off-machine."""
    u = urlparse(url)
    if u.scheme != "http" or u.hostname not in _LOOPBACK_HOSTS:
        raise ValueError(f"ollama_url must be http://localhost|127.0.0.1|[::1]:port/..., got {url!r}")
    return url


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _read_json(path: Path, default):
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


_EXAMPLE = re.compile(r"^Raw:\s*\"?(.*?)\"?\s*\n\s*Clean:\s*\"?(.*?)\"?\s*$", re.MULTILINE)


def split_examples(prompt: str) -> tuple[str, list[tuple[str, str]]]:
    """Pull 'Raw: … / Clean: …' pairs out of prompt.md.

    They are sent as real user/assistant turns rather than as prose in the
    system prompt: small models imitate demonstrations far more reliably than
    they follow descriptions of them. Returns (system prompt without the
    examples block, [(raw, clean), ...])."""
    examples = [(r.strip(), c.strip()) for r, c in _EXAMPLE.findall(prompt)]
    system = _EXAMPLE.sub("", prompt)
    system = re.sub(r"\n\s*Examples?:\s*\n(\s*\n)*", "\n", system)
    return system.strip(), examples


@dataclass
class Config:
    settings: dict
    corrections: dict
    snippets: dict
    jargon: list
    prompt_template: str          # system prompt with the examples removed
    examples: list                # [(raw, clean), ...] from prompt.md

    @classmethod
    def load(cls, directory: Path | None = None) -> "Config":
        d = directory or config_dir()
        settings = dict(DEFAULT_SETTINGS)
        settings.update(_read_json(d / "settings.json", {}))
        settings["ollama_url"] = validate_ollama_url(settings["ollama_url"])
        jargon_file = d / "jargon.txt"
        jargon = []
        if jargon_file.exists():
            jargon = [ln.strip() for ln in jargon_file.read_text(encoding="utf-8").splitlines()
                      if ln.strip() and not ln.startswith("#")]
        prompt_file = d / "prompt.md"
        template = prompt_file.read_text(encoding="utf-8") if prompt_file.exists() else FALLBACK_PROMPT
        system, examples = split_examples(template)
        return cls(
            settings=settings,
            corrections=_read_json(d / "corrections.json", {}),
            snippets=_read_json(d / "snippets.json", {}),
            jargon=jargon,
            prompt_template=system,
            examples=examples,
        )


FALLBACK_PROMPT = (
    "You are a dictation post-processor. Return only the cleaned text the speaker "
    "intended to write. Apply self-corrections, add punctuation and capitalization, "
    "preserve meaning. Target app: {APP_CONTEXT}. Vocabulary: {JARGON_LIST}"
)

# --------------------------------------------------------------------------- #
# Text stages
# --------------------------------------------------------------------------- #

_WS = re.compile(r"\s+")


def normalize(text: str) -> str:
    return _WS.sub(" ", text).strip()


def expand_snippet(text: str, snippets: dict) -> str | None:
    """If the whole utterance is a snippet trigger, return its expansion, else None."""
    key = normalize(text).lower().rstrip(".!?,")
    for trigger, expansion in snippets.items():
        if key == normalize(trigger).lower():
            return expansion
    return None


def apply_corrections(text: str, corrections: dict) -> str:
    """Whole-word, case-insensitive replacement. Longer triggers first so that
    'kuber netties cluster' wins over 'kuber netties'."""
    for heard in sorted(corrections, key=len, reverse=True):
        words = heard.split()
        if not words:
            continue                      # an empty key would match between every character
        pattern = r"\b" + r"\s+".join(re.escape(w) for w in words) + r"\b"
        # callable replacement: the value is pasted literally, so "\1" or "\\" in a
        # correction can neither crash re.sub nor be interpreted as a group reference
        text = re.sub(pattern, lambda _m, r=corrections[heard]: r, text, flags=re.IGNORECASE)
    return text


def word_count(text: str) -> int:
    return len(text.split())


def current_app_id(cfg: Config, directory: Path | None = None) -> str:
    """Focused-window app_id, if an external helper has written it recently."""
    p = (directory or config_dir()) / "app_id"
    try:
        if time.time() - p.stat().st_mtime > cfg.settings["app_id_max_age_s"]:
            return "unknown"
        return p.read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def style_for(app_id: str) -> str:
    a = app_id.lower()
    for style, needles in APP_STYLES.items():
        if any(n in a for n in needles):
            return style
    return "unknown"


def build_prompt(cfg: Config, app_id: str) -> str:
    jargon = ", ".join(cfg.jargon) if cfg.jargon else "(none)"
    return (cfg.prompt_template
            .replace("{APP_CONTEXT}", STYLE_TEXT[style_for(app_id)])
            .replace("{JARGON_LIST}", jargon))


# --------------------------------------------------------------------------- #
# LLM
# --------------------------------------------------------------------------- #

class LLMError(Exception):
    pass


def build_messages(system_prompt: str, text: str, previous: str, cfg: Config) -> list[dict]:
    """system → few-shot demonstrations as real turns → the transcript to clean."""
    messages = [{"role": "system", "content": system_prompt}]
    for raw, clean in cfg.examples:
        messages.append({"role": "user", "content": raw})
        messages.append({"role": "assistant", "content": clean})
    user = text if not previous else f"(previous dictation, for context only: {previous})\n\n{text}"
    messages.append({"role": "user", "content": user})
    return messages


def call_llm(system_prompt: str, text: str, previous: str, cfg: Config) -> str:
    """One Ollama /api/chat round-trip. Raises LLMError on any failure."""
    body = json.dumps({
        "model": cfg.settings["model"],
        "think": bool(cfg.settings.get("think", False)),
        "stream": False,
        "options": {"temperature": cfg.settings["temperature"]},
        "messages": build_messages(system_prompt, text, previous, cfg),
    }).encode("utf-8")
    req = urllib.request.Request(cfg.settings["ollama_url"], data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with _OPENER.open(req, timeout=cfg.settings["llm_timeout_s"]) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        raise LLMError(str(e)) from e
    try:
        return payload["message"]["content"]
    except (KeyError, TypeError) as e:
        raise LLMError(f"unexpected response shape: {payload!r}") from e


_THINK = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
_QUOTES = ('"', "'", "“", "”", "‘", "’", "`")


def clean_llm_output(text: str) -> str:
    text = _THINK.sub("", text)
    text = re.sub(r"<think>.*$", "", text, flags=re.DOTALL | re.IGNORECASE)  # unterminated block
    text = text.strip()
    while len(text) >= 2 and text[0] in _QUOTES and text[-1] in _QUOTES:
        text = text[1:-1].strip()
    return text


# Everything in C0/C1 and DEL except TAB and LF. ESC (0x1b) is the important one:
# it starts every ANSI/OSC sequence a terminal would act on when the text is pasted.
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def sanitize_output(text: str, allow_newlines: bool) -> str:
    """Last stage before the text is handed to the paste driver. Strips control
    characters unconditionally; keeps newlines only when the caller allows it."""
    text = _CTRL.sub("", text)
    if allow_newlines:
        return "\n".join(normalize(line) for line in text.split("\n")).strip()
    return normalize(text.replace("\n", " ").replace("\t", " "))


def newlines_allowed(cfg: "Config", app_id: str) -> bool:
    """User setting, except that a terminal never receives a newline (= Enter)."""
    return bool(cfg.settings.get("allow_newlines", False)) and style_for(app_id) != "terminal"


def within_length_budget(before: str, after: str, max_growth: float, max_shrink: float) -> bool:
    if not before:
        return False
    ratio = (len(after) - len(before)) / len(before)
    return -max_shrink <= ratio <= max_growth


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #

@dataclass
class Result:
    raw: str
    corrected: str
    final: str
    app_id: str
    llm_used: bool
    reason: str          # why the LLM was or wasn't used / why its output was rejected


def polish(raw: str, cfg: Config, previous: str = "", app_id: str = "unknown",
           llm=call_llm) -> Result:
    """Run the pipeline and sanitize the result. Every path — snippet, short,
    LLM, guard rejection — goes through sanitize_output() before it is returned."""
    r = _polish_stages(raw, cfg, previous, app_id, llm)
    r.final = sanitize_output(r.final, newlines_allowed(cfg, app_id))
    return r


def _polish_stages(raw: str, cfg: Config, previous: str, app_id: str, llm) -> Result:
    text = normalize(raw)
    if not text:
        return Result(raw, "", "", app_id, False, "empty")

    snippet = expand_snippet(text, cfg.snippets)
    if snippet is not None:
        return Result(raw, snippet, snippet, app_id, False, "snippet")

    corrected = apply_corrections(text, cfg.corrections)

    if word_count(corrected) < cfg.settings["min_words_for_llm"]:
        return Result(raw, corrected, corrected, app_id, False, "short")

    try:
        out = clean_llm_output(llm(build_prompt(cfg, app_id), corrected, previous, cfg))
    except LLMError as e:
        return Result(raw, corrected, corrected, app_id, False, f"llm_error: {e}")

    if not out:
        return Result(raw, corrected, corrected, app_id, False, "llm_empty")
    if not within_length_budget(corrected, out, cfg.settings["max_growth"], cfg.settings["max_shrink"]):
        return Result(raw, corrected, corrected, app_id, False, "length_guard")
    return Result(raw, corrected, out, app_id, True, "llm")


def append_log(result: Result, latency_ms: int, settings: dict, path: Path | None = None) -> None:
    """One JSON line per dictation, owner-readable only. Text fields are included
    only when settings["log_text"] is true."""
    if not settings.get("log_enabled", True):
        return
    p = path or log_path()
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "app_id": result.app_id,
        "llm_used": result.llm_used,
        "reason": result.reason,
        "latency_ms": latency_ms,
        "words": word_count(result.raw),
    }
    if settings.get("log_text", True):
        entry.update(raw=result.raw, corrected=result.corrected, final=result.final)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass  # logging must never break dictation


def main() -> int:
    t0 = time.monotonic()
    raw = sys.stdin.read()
    settings = dict(DEFAULT_SETTINGS)
    try:
        cfg = Config.load()
        settings = cfg.settings
        app_id = current_app_id(cfg)
        result = polish(raw, cfg, previous=os.environ.get("VOXTYPE_CONTEXT", ""), app_id=app_id)
        final = result.final
    except Exception as e:  # noqa: BLE001 - last line of defence, see module docstring
        result = Result(raw, raw, raw, "unknown", False, f"crash: {e!r}")
        final = sanitize_output(raw, allow_newlines=False)
    sys.stdout.write(final)
    sys.stdout.flush()
    append_log(result, int((time.monotonic() - t0) * 1000), settings)
    return 0


if __name__ == "__main__":
    sys.exit(main())
