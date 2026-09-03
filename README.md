# localTTS

Local, offline push-to-talk dictation for Linux (Pop!_OS + COSMIC on Wayland). Hold a key, speak, release: a cleaned-up transcript is pasted at the cursor about a second later. A replacement for Wispr Flow with no cloud, no account, no subscription — nothing leaves the machine.

**Status:** working daily driver as of 2026-09-02 — verified in COSMIC Text Editor, VS Code, Edge and the Claude desktop app. Known exception: COSMIC Terminal (see below).

## What it does

- Hold the dictation key (F13), speak, release → text appears where the cursor is.
- Cleanup on the way: fillers removed, spoken self-corrections applied ("ship Monday, actually delete that, ship Friday" → "Ship Friday."), punctuation and capitalization, your jargon spelled your way.
- Teach it in one line: `dictate fix "kuber netties" "Kubernetes"`. Corrections persist.
- Speech recognition, cleanup LLM, and text injection all run locally.

## How it works

```
hold F13 ──evdev──▶ Voxtype daemon ── records mic (PipeWire) ── release
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
git clone git@github.com:pitipatw/localTTS.git ~/dev/localTTS
cd ~/dev/localTTS
chmod +x install.sh polish.py dictate tests/latency_report.py
./install.sh                     # or: HOTKEY_MODE=toggle ./install.sh
# log out and back in when it says so, then ./install.sh again
```

The installer is idempotent, pins every version, verifies SHA256 (and GPG for Voxtype), and never pipes the network into a shell. `./install.sh --list` shows the steps; pass names to re-run a subset.

Before the first dictation, remap a spare physical key to **F13** in your keyboard's firmware tool (VIA/QMK). It must be a non-modifier key — INSTALL.md §5 explains why.

## Daily use

- Hold F13, speak, release.
- Misheard word: `dictate fix "what it heard" "What you meant"`. Spelling/capitalization the LLM should know: `dictate jargon "PipeWire"`. Snippet: `dictate snippet "my address" "123 Main St"`.
- See what happened: `dictate log tail 10` (shows `raw -> final` when they differ), `dictate log stats`, `journalctl --user -u voxtype -f`.
- Dry-run without the mic: `dictate test "send it monday actually delete that send it friday"`.
- Tune LLM behavior: add `Raw: … / Clean: …` pairs to `~/.config/dictate/prompt.md`; they are sent to the model as demonstrations.
- Privacy: the log holds every dictation in plaintext (mode 600). `dictate log purge` deletes it; `"log_text": false` in `~/.config/dictate/settings.json` keeps only metadata.
- **Not in COSMIC Terminal.** It pastes only on Ctrl+Shift+V and ignores Shift+Insert, and no single chord works in both terminals and GTK/Electron apps. Alacritty, kitty and foot honour Shift+Insert if you want terminal dictation.

## Repository layout

```
localTTS/
├── README.md                    this file
├── INSTALL.md                   installation guide, security model, troubleshooting
├── local-dictation-handoff.md   original design doc (Sept 2026)
├── install.sh                   idempotent installer, one step per section, each verified
├── polish.py                    Voxtype post-process hook
├── dictate                      CLI: fix / unfix / snippet / jargon / list / test / log / app
├── config/
│   ├── voxtype.config.toml      → ~/.config/voxtype/config.toml
│   ├── voxtype.config.toggle.toml  toggle-mode variant (no `input` group)
│   ├── prompt.md                → ~/.config/dictate/   system prompt + demonstrations
│   ├── corrections.json         → ~/.config/dictate/   "heard phrase" → "Spelling"
│   ├── snippets.json            → ~/.config/dictate/   spoken trigger → text
│   ├── jargon.txt               → ~/.config/dictate/   one term per line
│   └── settings.json            → ~/.config/dictate/   model, timeouts, guard thresholds, log privacy
├── systemd/ydotool.service      user unit for the built ydotoold
└── tests/
    ├── test_polish.py           22 unit tests, LLM mocked — `pytest -q tests/`
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
| Installs | latest release, `curl \| sh` | Pinned versions, SHA256 + GPG verified, Ollama bound to `127.0.0.1` under its own system user. |
| Hotkey privilege | `input` group | Default for push-to-talk; `HOTKEY_MODE=toggle` variant needs only a `uinput` group. INSTALL.md §1.2. |
| Dictation log | plaintext, forever | Mode 600, `log_text`/`log_enabled` settings, `dictate log purge`. |

## Verification

- Unit: `pytest -q tests/` — 22 tests, LLM mocked (U1–U10 from the handoff plus edge cases and log privacy).
- Integration (handoff §7.2): passed 2026-09-02 — paste in four apps, clipboard image restored, silent release pastes nothing, 30 s dictation intact.
- Latency (§7.3): after ~20 dictations, `dictate log stats`. Early numbers: Parakeet 0.13–0.21 s, LLM path 55–700 ms. If over budget: `qwen3:4b` in `settings.json`, shorter `prompt.md`.
- Accuracy (§7.4) and safety (§7.5): as in the handoff; re-run `dictate test` cases after prompt or dictionary changes.

## Open items

1. GPU inference: optional. Needs CUDA 13 runtime + cuDNN 9 on the system, then `VOXTYPE_VARIANT=auto ./install.sh voxtype`.
2. App-context helper (C9): something that writes the focused `app_id` to `~/.config/dictate/app_id`; the read side exists.
3. Hands-free toggle (C2), Command Mode (C12), learning from edits (C13/C16), wake word (C17): not started — see the handoff §4.
