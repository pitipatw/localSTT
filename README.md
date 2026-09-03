# localSTT

Local, offline push-to-talk dictation for Linux (Pop!_OS + COSMIC on Wayland). Hold a key, speak, release: a cleaned-up transcript is pasted at the cursor about a second later. A replacement for Wispr Flow with no cloud, no account, no subscription — nothing leaves the machine.

**Status:** working daily driver as of 2026-09-02 — verified in COSMIC Text Editor, VS Code, Edge and the Claude desktop app. Known exception: COSMIC Terminal (see below).

## What it does

- Hold the dictation key (F13), speak, release → text appears where the cursor is.
- Cleanup on the way: fillers removed, spoken self-corrections applied ("ship Monday, actually delete that, ship Friday" → "Ship Friday."), punctuation and capitalization, your jargon spelled your way.
- Teach it in one line: `dictate fix "kuber netties" "Kubernetes"`. Corrections persist.
- Speech recognition, cleanup LLM, and text injection all run locally.

## How it works

```
hold F13 ──evdev──▶ hotkeyd (sandboxed) ──socket──▶ hotkey-relay ──▶ Voxtype daemon ── records mic (PipeWire) ── release
   (or: COSMIC shortcut ──▶ voxtype record toggle ──▶ Voxtype daemon)
                          │
              Parakeet TDT 0.6B v3 (ONNX, ~0.2 s on CPU)
                          │  raw text
                    polish.py  (Voxtype post-process hook, stdin → stdout)
                      snippets → dictionary → [skip if < 6 words] → Qwen3-8B via Ollama → length guard
                          │  final text
              wl-copy → ydotool shift+insert → clipboard restored
```

| Layer | Component |
|---|---|
| Daemon, hotkey, audio, ASR host | [Voxtype](https://github.com/peteonrails/voxtype) 1.0.1 |
| Speech recognition | NVIDIA Parakeet TDT 0.6B v3 (ONNX) |
| Cleanup LLM | Qwen3-8B via Ollama 0.33.2, bound to localhost, kept resident in VRAM |
| Post-processing | `polish.py` — Python, standard library only |
| Text injection | `wl-copy` + ydotool 1.0.4 (built from source; see below) |
| Teaching / inspection | `dictate` CLI |

## Install

Read **[INSTALL.md](INSTALL.md)** first — its §1 covers the security trade-offs (the `input` group, supply chain, the plaintext dictation log) and the one decision you have to make. Short version:

```bash
git clone git@github.com:pitipatw/localSTT.git ~/dev/localSTT
cd ~/dev/localSTT
chmod +x install.sh polish.py dictate tests/latency_report.py
./install.sh                     # toggle mode (default): press the shortcut to start, again to stop
# hold-to-talk instead (F13 read by a tiny sandboxed system service — you are NOT added to the `input` group):
#   HOTKEY_MODE=push_to_talk ./install.sh
# log out and back in when it says so, then ./install.sh again
```

The installer is idempotent, pins every version **and digest**, requires a valid GPG signature for Voxtype, and never pipes the network into a shell. `./install.sh --list` shows the steps; pass names to re-run a subset. The mode you chose is remembered in `~/.config/dictate/hotkey_mode`, so plain `./install.sh` re-runs keep it. `SECURITY_REVIEW.md` documents the threat model and the reasoning behind these choices.

Before the first dictation: in toggle mode (default), add a COSMIC custom shortcut — Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts — running `/home/<you>/.local/bin/voxtype record toggle`, bound to a modifier combo such as Super+Space (COSMIC's picker usually refuses a bare key like F13; INSTALL.md Step 5 has the file-based workaround). For push-to-talk, remap a spare physical key to **F13** in the keyboard firmware (VIA/QMK); it must be a non-modifier key — INSTALL.md §5 explains why.

## Daily use

- Toggle mode (default): press your COSMIC shortcut, speak, press it again. Push-to-talk: hold F13, speak, release. Press Esc while holding to cancel without pasting.
- Turn it off / on: `systemctl --user stop voxtype` / `start`; `disable --now` keeps it off across logins, `enable --now` restores it. Nothing else is running in the foreground — the daemon is a systemd user service. Ollama is a separate system service (`sudo systemctl stop ollama`) that idles at zero CPU.
- Spoken "new line" / "new paragraph" are flattened to spaces unless `"allow_newlines": true` is set (see Settings). Terminals never receive newlines, whatever the setting.
- Misheard word: `dictate fix "what it heard" "What you meant"`. Spelling/capitalization the LLM should know: `dictate jargon "PipeWire"`. Snippet: `dictate snippet "my address" "123 Main St"`.
- See what happened: `dictate log tail 10` (shows `raw -> final` when they differ), `dictate log stats`, `journalctl --user -u voxtype -f`.
- Dry-run without the mic: `dictate test "send it monday actually delete that send it friday"`.
- Tune LLM behavior: add `Raw: … / Clean: …` pairs to `~/.config/dictate/prompt.md`; they are sent to the model as demonstrations.
- Privacy: the log is metadata-only by default. `"log_text": true` in `~/.config/dictate/settings.json` records every dictation in plaintext (mode 600) so you can tune the dictionary and prompt; `dictate log purge` deletes it. Note that every dictation also passes through the Wayland clipboard, so a clipboard-history tool keeps its own copy.
- **Not in COSMIC Terminal.** It pastes only on Ctrl+Shift+V and ignores Shift+Insert, and no single chord works in both terminals and GTK/Electron apps. Alacritty, kitty and foot honour Shift+Insert if you want terminal dictation.

## The `dictate` command

`dictate` is a small Python CLI (installed as a copy in `~/.local/bin/dictate`; re-run `./install.sh config` after editing it, or use `DEV_SYMLINK=1` while developing) that edits the data files `polish.py` reads and inspects what it did. Nothing it changes needs a restart: `polish.py` re-reads the files on every dictation, so a fix takes effect on the very next one.

| Command | What it does | Writes to |
|---|---|---|
| `dictate fix "<heard>" "<intended>"` | Adds a dictionary rule: whenever the transcript contains `<heard>` as whole words (case-insensitive, any spacing), replace it with `<intended>`. Multi-word phrases are fine and safer than single words. | `corrections.json` |
| `dictate unfix "<heard>"` | Removes that rule. | `corrections.json` |
| `dictate snippet "<trigger>" "<text>"` | When an *entire* dictation equals `<trigger>` (ignoring case and trailing punctuation), paste `<text>` instead — the LLM is skipped. For addresses, sign-offs, boilerplate. | `snippets.json` |
| `dictate jargon "<term>" [...]` | Adds terms to the "spell exactly like this" list in the LLM prompt. For words the ASR hears right but the LLM might "correct" or mis-capitalize (PipeWire, Qwen3, git commit). | `jargon.txt` |
| `dictate list` | Shows every correction, snippet and jargon term, and which model is configured. | — |
| `dictate test "<raw text>"` | Runs the full pipeline on the text as if it had been dictated, using Ollama if it is up, and prints which stage decided (`snippet`, `short`, `llm`, `length_guard`, `llm_error`), the dictionary-corrected text, and the final text. Use it to confirm a fix before relying on it. | log |
| `dictate log tail [N]` | Last N log entries (default 10): timestamp, hook latency, stage, and the text — shown as `'raw' -> 'final'` when the pipeline changed something, plain otherwise. This is how you tell whether a mistake came from the ASR (raw already wrong → `dictate fix`) or from the LLM (raw right, final wrong → jargon or a prompt example). | — |
| `dictate log stats` | Median / p95 / max hook latency split by LLM vs non-LLM path, counts per stage, and how often the LLM changed the text. Run after ~20 dictations. | — |
| `dictate log purge` | Deletes the log file entirely. See Privacy below. | — |
| `dictate app "<app_id>"` | Writes an app-id hint that `polish.py` reads for up to 5 s to pick a formatting style (terminal / code / email / chat). Meant for a future focus-tracking helper, not for daily use. | `app_id` |

Which fix for which mistake:

- The ASR **misheard** ("kuber netties", "i get committed") → `dictate fix`. Deterministic, applies before the LLM, and is the *only* fix for dictations under six words, which skip the LLM entirely.
- The ASR heard it, the LLM **respelled** it ("pipewire", "Committee" for "git commit" in a longer sentence) → `dictate jargon`, and if it persists, a `Raw: … / Clean: …` pair in `~/.config/dictate/prompt.md`.
- The LLM handled a **pattern** wrong (missed a self-correction, added a period in a terse context) → a prompt example; they are sent to the model as demonstrations, which small models follow much better than rules.

Files, all under `~/.config/dictate/` (installed once from `config/`, then yours):

| File | Format |
|---|---|
| `corrections.json` | `{"heard phrase": "Intended Spelling"}` |
| `snippets.json` | `{"spoken trigger": "expanded text"}` — `\n` for line breaks |
| `jargon.txt` | one term per line; `#` comments |
| `prompt.md` | system prompt; `{APP_CONTEXT}` and `{JARGON_LIST}` are filled in; `Raw:`/`Clean:` pairs become chat turns |
| `settings.json` | `model`, `ollama_url`, `temperature`, `think`, `llm_timeout_s`, `min_words_for_llm`, `max_growth`, `max_shrink`, `log_enabled`, `log_text` |

The log lives at `~/.local/share/dictate/log.jsonl`, one JSON object per dictation, created mode 600. With `"log_text": true` (default) each entry holds `raw`, `corrected` and `final` — i.e. every word you dictate, in plaintext, until you purge. Keep it while tuning; then `dictate log purge` and consider `"log_text": false`, which keeps only timestamp, stage, latency and word count. `"log_enabled": false` turns logging off entirely. Purging never touches corrections, snippets or jargon.

## Repository layout

```
localSTT/
├── README.md                    this file
├── INSTALL.md                   installation guide, security model, troubleshooting
├── local-dictation-handoff.md   original design doc (Sept 2026)
├── install.sh                   idempotent installer, one step per section, each verified
├── polish.py                    Voxtype post-process hook
├── dictate                      CLI: fix / unfix / snippet / jargon / list / test / log / app
├── config/
│   ├── voxtype.config.toml      → ~/.config/voxtype/config.toml  (Voxtype's own hotkey listener off in both modes)
│   ├── prompt.md                → ~/.config/dictate/   system prompt + demonstrations
│   ├── corrections.json         → ~/.config/dictate/   "heard phrase" → "Spelling"
│   ├── snippets.json            → ~/.config/dictate/   spoken trigger → text
│   ├── jargon.txt               → ~/.config/dictate/   one term per line
│   └── settings.json            → ~/.config/dictate/   model, timeouts, guard thresholds, log privacy
├── hotkeyd/
│   ├── hotkeyd.py               → /usr/local/lib/hotkeyd/  80-line evdev reader, runs as system user `hotkeyd`
│   └── hotkey-relay             → ~/.local/bin/  socket → `voxtype record start|stop`, runs as you
├── systemd/
│   ├── ydotool.service          user unit for the built ydotoold
│   ├── hotkeyd.service          sandboxed system unit for hotkeyd (push-to-talk only)
│   └── hotkey-relay.service     user unit for the relay (push-to-talk only)
└── tests/
    ├── test_polish.py           unit tests for polish.py, LLM mocked — `pytest -q tests/`
    ├── test_hotkeyd.py          event decoder, hold-cap state machine, relay allow-list
    └── latency_report.py        `dictate log stats`
```

Data files under `~/.config/dictate/` are installed once and never overwritten; the repo copies are templates.

## Things that were not obvious

Three findings from getting this working on COSMIC, each documented in INSTALL.md §5:

- **The hotkey must not be a modifier key.** Right Ctrl worked in GTK apps but not in Electron apps: a bare modifier press/release leaves Chromium's modifier state stale and the following paste chord is silently ignored. Hence F13.
- **Electron needs `type_delay_ms = 60`** between the modifier and the key of the paste chord; ydotool's 12 ms default drops the modifier there.
- **Voxtype needs ydotool 1.0.x on both ends.** It drives the client with numeric `code:state` arguments; a pre-1.0 client types them literally. Pop!_OS ships 0.1.8, so the installer builds 1.0.4 into `~/.local/bin`.

## Decisions that differ from the original design

| Topic | Handoff said | What we do, and why |
|---|---|---|
| Output | `mode = "type"`, ydotool first | `mode = "paste"`, `paste_keys = "shift+insert"`. "type" would synthesize every character via US keycodes; "paste" is the clipboard + keystroke path. |
| Terminal paste (C10) | hook picks `ctrl+shift+v` | Not possible — Voxtype pastes *after* the hook returns. `shift+insert` covers GTK, Qt, Firefox, Electron and most terminals; COSMIC Terminal is the exception and is not supported. |
| App context (C9) | hook gets `app_id` | Voxtype passes no window info. `polish.py` reads an optional `~/.config/dictate/app_id` file (< 5 s old) if a helper writes it; otherwise "unknown". Deferred. |
| Previous-dictation context | custom | Voxtype's own `VOXTYPE_CONTEXT` env var. |
| Filler removal | LLM only | Voxtype strips um/uh/er itself; the LLM rule is a second pass. |
| ASR engine | Parakeet on CUDA, Whisper fallback | Parakeet on **CPU** (~0.2 s per utterance — fast enough). Voxtype's CUDA build hangs in its CPU fallback when the CUDA 13 runtime is absent, so the installer keeps the CPU build unless told otherwise. Whisper is a config switch, not a runtime fallback. |
| Length guard | ±40 % | Asymmetric: growth > 30 % or shrink > 75 % rejected. Self-corrections legitimately shrink text ~50–70 %. |
| Few-shot examples | prose in the system prompt | Sent as real user/assistant turns; an 8B model imitates demonstrations far better than it follows descriptions. |
| Hotkey | TBD | F13 (see above). |
| Installs | latest release, `curl \| sh` | Pinned versions **and digests** (tarball sha256, git commit, model blob, every Parakeet file), GPG signature required for Voxtype, Ollama bound to `127.0.0.1` under its own sandboxed system user. |
| Hotkey privilege | `input` group | Your user is never in `input`. Toggle mode (default) uses a COSMIC shortcut; hold-to-talk runs an 80-line sandboxed `hotkeyd` system service that reports F13 press/release on a socket. INSTALL.md §1.2. |
| Dictation log | plaintext, forever | Metadata-only by default; `log_text`/`log_enabled` settings, mode 600, `dictate log purge`. |
| Pasted text | whatever the LLM returned | Control characters stripped; newlines off unless `allow_newlines`, never in terminals. |

## Settings

`~/.config/dictate/settings.json` overrides the defaults in `polish.py`. All keys are optional.

| Key | Default | Meaning |
|---|---|---|
| `allow_newlines` | `false` | Keep newlines that the LLM produces from "new line" / "new paragraph". Off by default so a transcript — yours, or a video playing while the mic is on — can never press Enter for you. A terminal-style target never receives newlines, even when this is `true`. |
| `log_enabled` / `log_text` | `true` / `false` | Write a log line per dictation / include the raw and final text in it. |
| `ollama_url` | `http://localhost:11434/api/chat` | Must be a loopback address (`localhost`, `127.0.0.1`, `::1`) over plain `http`; anything else is rejected and dictation falls back to the uncleaned text. Every dictation is POSTed here, so this setting must never be able to point off-machine. |
| `model`, `temperature`, `think`, `llm_timeout_s` | `qwen3:8b`, `0.1`, `false`, `4.0` | LLM call parameters. |
| `min_words_for_llm` | `6` | Shorter dictations skip the LLM (dictionary only). |
| `max_growth` / `max_shrink` | `0.30` / `0.75` | Length guard: LLM output longer by more than 30 % or shorter by more than 75 % is discarded. |
| `app_id_max_age_s` | `5.0` | How fresh `~/.config/dictate/app_id` must be to count. |

Control characters (ESC, BEL, NUL, …) are always stripped from the output before it is pasted, on every path including the crash fallback.

## Verification

- Unit: `pytest -q tests/` — 37 tests, LLM mocked (U1–U10 from the handoff, edge cases, log privacy, and the S-series from `SECURITY_REVIEW.md`: output sanitization, loopback-only `ollama_url`, literal correction values).
- Integration (handoff §7.2): passed 2026-09-02 — paste in four apps, clipboard image restored, silent release pastes nothing, 30 s dictation intact.
- Latency (§7.3): after ~20 dictations, `dictate log stats`. Early numbers: Parakeet 0.13–0.21 s, LLM path 55–700 ms. If over budget: `qwen3:4b` in `settings.json`, shorter `prompt.md`.
- Accuracy (§7.4) and safety (§7.5): as in the handoff; re-run `dictate test` cases after prompt or dictionary changes.

## Open items

1. GPU inference: optional. Needs CUDA 13 runtime + cuDNN 9 on the system, then `VOXTYPE_VARIANT=auto ./install.sh voxtype`.
2. App-context helper (C9): something that writes the focused `app_id` to `~/.config/dictate/app_id`; the read side exists.
3. Hands-free toggle (C2), Command Mode (C12), learning from edits (C13/C16), wake word (C17): not started — see the handoff §4.
