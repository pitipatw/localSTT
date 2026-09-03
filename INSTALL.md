# Installation Guide — local dictation on Pop!_OS COSMIC

This guide walks through installing the stack in `~/dev/localSTT` and, alongside each step, explains what it changes on your system and what the security implications are. Read §1 before running anything; it contains the one decision you need to make.

Everything runs locally. No audio, text, or telemetry leaves the machine at any point after installation. The installation itself downloads four things from the internet: Voxtype, Ollama, the Parakeet speech model, and the Qwen3 language model.

---

## 1. Security model — read this first

### 1.1 What this does and does not change about microphone access

On a Linux desktop there is no per-application microphone permission for native programs. Any process running under your user account can already open the microphone through PipeWire. Installing Voxtype adds one more process with that ability; it does not open a door that was previously closed. In push-to-talk mode Voxtype should only hold a capture stream while the hotkey is down. Verify this yourself after installation with `pw-top`: a `voxtype` capture stream should appear only while you are recording (step 11 below). Voxtype does not keep recordings; audio is transcribed in memory and discarded.

The realistic microphone threat is a compromised user account, and that threat exists with or without this project. The mitigations for it are the usual ones: full-disk encryption, not running untrusted software as your user, keeping the system updated.

### 1.2 The `input` group — the one real trade-off

Wayland's security model keeps applications from seeing each other's keystrokes. Voxtype's hold-to-talk needs to see the dictation key's press *and release* no matter which window is focused, and the only way to do that on COSMIC is to read the keyboard at the evdev level, which requires your user to be in the `input` group.

Being in `input` means **every process running as you can read every keystroke** from `/dev/input/event*` — a user-level keylogger no longer needs root and can capture passwords typed into terminals, browsers, or sudo prompts. It also grants write access to `/dev/uinput` (needed for pasting), which lets any user process inject keystrokes.

You have two choices:

| | Push-to-talk (default) | Toggle mode (`HOTKEY_MODE=toggle`) |
|---|---|---|
| Feel | Hold the F13 key, speak, release | Press shortcut, speak, press again |
| Group added | `input` (read all keyboards + uinput) | `uinput` only (inject, cannot read keyboard) |
| Hotkey mechanism | Voxtype evdev listener | COSMIC custom shortcut → `voxtype record toggle` |
| Keylogger exposure | any user process can read keystrokes | unchanged from stock Wayland |
| Keystroke injection | any user process | any user process (unavoidable — pasting needs it) |

The push-to-talk trade is what most people running evdev dictation on Wayland accept, and on a single-user machine with disk encryption it is defensible. Toggle mode is the safer default if you are unsure, at the cost of the hold-and-release feel. You can switch later by re-running the installer with the other mode and removing yourself from the group you no longer need (`sudo gpasswd -d $USER input`).

### 1.3 Supply chain — what you are trusting

| Download | Source | Verification the installer does | Residual trust |
|---|---|---|---|
| Voxtype 1.0.1 binary + 2–3 ONNX Runtime `.so` files | GitHub release, pinned version | SHA256 against the release's `SHA256SUMS.txt`, which is GPG-verified against key `9CCF7915B750CAE8B095ED1AA3FC9F33FD209279` (fetched from keys.openpgp.org) | The author's signing key and GitHub. The GPG step is skipped with a warning if the key cannot be fetched; you can verify by hand (§4). |
| Ollama 0.33.2 tarball | GitHub release, pinned version | SHA256 against the release's `sha256sum.txt` | GitHub and the Ollama project. **No `curl \| sh`**: the tarball is extracted to `/usr/local` and a systemd unit is written by this repo, bound to `127.0.0.1` only, running as a dedicated `ollama` system user. |
| Parakeet TDT 0.6B v3 (ONNX) | Hugging Face, `istupakov/parakeet-tdt-0.6b-v3-onnx` | None (no checksums published) | ONNX is a protobuf data format; it cannot execute code when loaded. Worst case is a bad model, not a compromised machine. |
| `qwen3:8b` | Ollama registry | Ollama verifies its own manifests by digest | GGUF is a data format; same reasoning. |
| apt packages (`ydotool ydotoold wl-clipboard jq zstd gnupg python3-pytest`) | Pop!_OS repos | apt signature checking | Same trust as the rest of your system. |
| ydotool 1.0.4 source (only if no `ydotoold` package is available) | GitHub, `ReimuNotMoe/ydotool`, pinned tag `v1.0.4` | git tag; the commit hash is printed at build time | Small C project you compile yourself; you can read it in `~/.cache/localstt-downloads/ydotool-1.0.4`. |

Versions are pinned at the top of `install.sh`. To upgrade, change the version, and the checksum step will verify the new release.

### 1.4 Your dictations are logged in plaintext

`~/.local/share/dictate/log.jsonl` stores every raw and cleaned transcript. That is what lets you tune the dictionary and prompt, and later fine-tune, but it means anything you ever dictate — a password, an address, a private message — sits in that file. Controls:

- The file and its directory are created mode `600`/`700` (owner only).
- `dictate log purge` deletes it.
- In `~/.config/dictate/settings.json`, `"log_text": false` keeps only metadata (timestamp, app, latency, word count); `"log_enabled": false` disables logging entirely. Once the prompt is tuned, turning `log_text` off is a sensible default.
- Voxtype's own `VOXTYPE_CONTEXT` variable carries the previous dictation for up to 60 s, in process memory only.

### 1.5 Things that are fine as designed

The ydotool socket is created mode `0600`, so only your user can inject through it. Ollama listens on `127.0.0.1:11434` only; the installer checks this. The cleanup LLM has no tools, so a prompt injection in something you dictate can at worst produce odd text. The post-process hook path is fixed in a config file that is mode `600` under your home, so only something already running as you could change it — and something running as you could do worse things more directly.

---

## 2. Before you start

- Pop!_OS with the COSMIC desktop on a Wayland session, NVIDIA driver installed (`nvidia-smi` works).
- About 10 GB free: Parakeet ~2.5 GB, Qwen3-8B ~5 GB, Voxtype ~0.5 GB.
- ~12 GB VRAM is comfortable; both models stay resident (~7 GB).
- Decide push-to-talk vs toggle (§1.2).
- **Pick a non-modifier dictation key.** The config uses `F13`. Remap a spare physical key to F13 in your keyboard's firmware tool (VIA/QMK: Configure → layer 0 → click the key → choose F13), then confirm with `evtest` that Linux reports `KEY_F13` (code 183). Do not use Ctrl/Alt/Shift/Super: a bare modifier press-and-release leaves Electron apps (Claude, VS Code, Slack, Discord) with stale modifier state, and the paste keystroke that follows is silently ignored there. If your keyboard cannot be remapped, `PAUSE` or `SCROLLLOCK` are the next best choices.

---

## 3. Steps

Run in a terminal, in order. `install.sh` is idempotent: re-running it skips what is done and re-verifies.

**Step 1 — make scripts executable, start a repo**

```bash
cd ~/dev/localSTT
chmod +x install.sh polish.py dictate tests/latency_report.py
git init && git add -A && git commit -m "initial dictation stack"
```

**Step 2 — run the installer**

```bash
./install.sh                       # push-to-talk (adds you to `input`)
# or
HOTKEY_MODE=toggle ./install.sh    # toggle mode (adds you to `uinput` only)
```

It asks for your sudo password for: apt installs, the `/dev/uinput` udev rule, the group change, extracting Ollama to `/usr/local`, and creating the `ollama` user and system service. Everything else is under your home directory. Each `==` section ends with green ✔ lines; a yellow `!` is informational; a red ✘ stops the run and says why.

The slow parts are the Parakeet download (~2.5 GB) and `ollama pull qwen3:8b` (~5 GB). Downloads are cached in `~/.cache/localstt-downloads` so a re-run does not fetch them again.

**Step 3 — log out and back in**

The first run adds you to a group; that only takes effect for a new login session (a new terminal is not enough). The summary at the end says whether this is needed. After logging back in:

```bash
cd ~/dev/localSTT && ./install.sh
```

This time the ydotool step should print `✔ ydotoold running`.

**Step 4 — verify the downloads yourself (optional, recommended once)**

```bash
cd ~/.cache/localstt-downloads
gpg --verify voxtype-1.0.1.SHA256SUMS.txt.asc voxtype-1.0.1.SHA256SUMS.txt
sha256sum -c --ignore-missing voxtype-1.0.1.SHA256SUMS.txt
sha256sum -c --ignore-missing ollama-0.33.2.sha256sum.txt
```

Compare the GPG key fingerprint with the one published in the Voxtype release notes on GitHub. If you prefer not to trust keys.openpgp.org, import the key from the release page instead.

**Step 5 — toggle mode only: create the shortcut**

COSMIC Settings → Keyboard → Custom shortcuts → add: command `/home/<you>/.local/bin/voxtype record toggle`, key of your choice (e.g. Super+Space). Press once to start, again to stop and paste.

**Step 6 — paste path probe (no microphone yet)**

```bash
echo "hello from ydotool" | wl-copy
# click into COSMIC Text Editor, then within 3 s:
sleep 3 && ydotool key shift+insert
```

Text must appear. If not: `systemctl --user status ydotool`, `ls -l /dev/uinput` (group should match your mode, mode 660), `echo $YDOTOOL_SOCKET`.

**Step 7 — LLM probe (no microphone yet)**

```bash
dictate test "send it monday actually delete that send it friday"
```

Expect `[llm]` and something like `final: Send it Friday.` If you see `[llm_error …]`: `systemctl status ollama`, `ollama list`, `ss -ltn | grep 11434`.

**Step 8 — first dictation**

Click into the text editor. Push-to-talk: hold the F13 key, say "testing one two three", release. Toggle: press your shortcut, speak, press again. Text should appear in about a second. If nothing happens, run `journalctl --user -u voxtype -f` in another terminal and try again. Common causes: the daemon is not running (`systemctl --user status voxtype`), the hotkey is not seen (group membership not yet active — did you log out?), or the paste landed in another window (an overlay stole focus — keep any OSD disabled).

**Step 9 — GPU check**

`journalctl --user -u voxtype | grep -i -E "cuda|provider|cpu"` should show the CUDA execution provider loading. If it says it fell back to CPU, the ONNX Runtime CUDA provider could not find cuDNN 9 / the CUDA 12 runtime libraries on the system. Voxtype still works on CPU (slower, ~1 s per utterance instead of ~0.2 s). To enable the GPU, install cuDNN 9 for CUDA 12 — on Pop!_OS the `system76-cudnn-12.x` packages, or NVIDIA's `libcudnn9-cuda-12` — then `systemctl --user restart voxtype`. The exact package names change; `apt search cudnn` lists what is available. **[verify]** — this is the one part of the stack whose runtime requirements are not documented by Voxtype.

**Step 10 — integration checks**

Repeat step 8 in Firefox/Edge, VS Code, and the Claude app (all accept `shift+insert`, so no per-app configuration). Copy an image, dictate, confirm the image is still on the clipboard afterwards. Hold and release without speaking: nothing should paste. Dictate for 30 s: no truncation.

**Known exception: COSMIC Terminal.** It pastes only on Ctrl+Shift+V and ignores Shift+Insert, and there is no single chord that works in terminals *and* GTK/Electron apps. Dictation into COSMIC Terminal is therefore not supported; the text is still copied to the clipboard for ~300 ms, but not long enough to paste by hand. If terminal dictation matters to you, Alacritty, kitty and foot all honour Shift+Insert.

**Step 11 — microphone-in-use check**

Run `pw-top` in a terminal. While idle, there should be no `voxtype` capture stream; while recording, one should appear; when you release, it should go away. Expect two rows while recording: the microphone *device* (e.g. a webcam's audio node, woken up because something is reading from it) and the `voxtype` *stream* consuming it — that pairing is normal. A `voxtype` row that persists while idle, or the device staying active with no stream under it, would be worth investigating. If a stream stays open permanently, that is worth knowing (and worth reporting upstream); it does not mean audio is being sent anywhere, but it is the behaviour §1.1 assumes.

**Step 12 — tune over the first week**

- `dictate fix "what it heard" "What you meant"` for every misspelling.
- `dictate jargon "Term"` for words the LLM should know how to spell.
- After ~20 dictations, `dictate log stats`. If LLM-path hook latency median is over ~1100 ms, set `"model": "qwen3:4b"` in `~/.config/dictate/settings.json`.
- Copy 5–10 good raw→final pairs from `dictate log tail 50` into `~/.config/dictate/prompt.md` as extra examples.
- When you are happy with accuracy, set `"log_text": false` (§1.4) and `dictate log purge`.

---

## 4. What the installer writes, and how to remove it

| Location | What | Remove with |
|---|---|---|
| `/etc/udev/rules.d/80-uinput.rules`, `/etc/modules-load.d/uinput.conf` | uinput device group/mode | `sudo rm` both, `sudo udevadm control --reload-rules` |
| group membership `input` or `uinput` | evdev / uinput access | `sudo gpasswd -d $USER input` (or `uinput`) |
| `/usr/local/bin/ollama`, `/usr/local/lib/ollama/`, `/etc/systemd/system/ollama.service`, user `ollama`, `/usr/share/ollama/` (models) | Ollama | `sudo systemctl disable --now ollama; sudo rm -rf /usr/local/bin/ollama /usr/local/lib/ollama /etc/systemd/system/ollama.service; sudo userdel -r ollama` |
| `~/.local/lib/voxtype/`, `~/.local/bin/voxtype` (wrapper), `~/.local/bin/polish.py`, `~/.local/bin/dictate` | Voxtype + hooks | `rm -rf` those paths |
| `~/.local/share/voxtype/models/` | Parakeet | `rm -rf` |
| `~/.config/voxtype/config.toml`, `~/.config/dictate/`, `~/.config/systemd/user/{ydotool,voxtype}.service*`, `~/.config/environment.d/ydotool.conf`, `~/.profile` (one `export YDOTOOL_SOCKET` line) | config | `systemctl --user disable --now voxtype ydotool`, then delete |
| `~/.local/share/dictate/log.jsonl` | dictation log | `dictate log purge` |
| `~/.cache/localstt-downloads/` | verified downloads | `rm -rf` |

---

## 5. Hotkey: why F13, and the modifier-key trap

The dictation key must be a **non-modifier** key. The first choice, Right Ctrl, worked in COSMIC Text Editor but not in Electron apps (the Claude desktop app, and by extension VS Code, Slack, Discord). What happens: holding and releasing a bare modifier — with no other key — leaves Chromium's internal modifier state stale on Wayland. When Voxtype then sends the paste chord about a second later, Electron reads `shift+insert` as `Ctrl+Shift+Insert` and ignores it. Reproduced by hand: press and release Right Ctrl in the Claude box, then fire `ydotool key -d 60 42:1 110:1 110:0 42:0` — nothing pastes; without the Ctrl press, it pastes.

Symptoms that point at this:

- Dictation pastes in GTK apps but not in Electron apps, while the journal says `Text pasted via clipboard + shift+insert`.
- With `paste_keys = "ctrl+v"`, a lone `v` appears instead of the text.
- A `.` (or another character) appears when you hold the key: the keyboard firmware has it as a tap-hold key.

Fix: remap a spare physical key to **F13** in the keyboard's firmware tool (VIA/QMK: Configure → layer 0 → click the key → F13), verify with `evtest` (`KEY_F13`, code 183), set `key = "F13"` under `[hotkey]`, `systemctl --user restart voxtype`. F13–F24 are real keycodes that no application binds, so there are no side effects in any app. Keyboards that cannot be remapped: `PAUSE` or `SCROLLLOCK`.

Related, found on the same path: Electron also needs more than ydotool's default 12 ms between the modifier and the key of the paste chord, hence `type_delay_ms = 60` in `[output]` (Voxtype passes it as `ydotool key -d 60`). And Voxtype requires ydotool **1.0.x** on both client and daemon — it drives the client with numeric `code:state` arguments, which a pre-1.0 client types literally (you see `4114`), and a 1.0 client cannot talk to a pre-1.0 daemon. On this Pop!_OS the packaged pair did not qualify, so the installer builds 1.0.4 into `~/.local/bin` and runs that daemon from a user unit.

---

## 6. Troubleshooting quick reference

| Symptom | Check |
|---|---|
| `ydotoold not running` on first run | Expected before re-login. Log out/in, re-run. |
| `status=203/EXEC` or `ydotoold binary not found` | Debian/Ubuntu split the daemon into a separate `ydotoold` package; the `ydotool` package is only the client. The installer installs `ydotoold` via apt, or builds ydotool 1.0.4 from source into `~/.local/bin` if the package is unavailable. |
| `ydotool key` does nothing | `ls -l /dev/uinput` group matches your mode; `id -nG` includes it; `echo $YDOTOOL_SOCKET` matches `systemctl --user show ydotool -p ExecStart` |
| Text comes out as digits | A `wtype`/`eitype` driver got used. `driver_order` must start with `ydotool`. |
| Paste lands in the wrong window | Disable any Voxtype OSD/overlay. |
| `[llm_error]` in `dictate test` | `systemctl status ollama`, `ss -ltn \| grep 11434`, `ollama list` |
| Transcription slow (~1 s+) | GPU fallback to CPU; see step 9. |
| Checksum mismatch | Delete `~/.cache/localstt-downloads/*` and re-run. If it persists, do not install — the release may have been re-uploaded or tampered with; compare against the GitHub release page. |
| Hotkey ignored in push-to-talk | `id -nG \| grep input`; `journalctl --user -u voxtype` for "permission denied" on `/dev/input`; `evtest` to confirm the key's evdev name matches `key = …` |
| Pastes in GTK apps but not Electron (Claude, VS Code) | Hotkey is a modifier key → §5. Also check `type_delay_ms = 60`. |
| `4114` (or other digits) typed instead of a paste | ydotool client is pre-1.0 → §5; `./install.sh ydotool` builds 1.0.4. |
| Daemon logs `Loading Parakeet … model` and nothing after; 0 % CPU | CUDA build hung in its CPU fallback (no CUDA runtime installed). `VOXTYPE_VARIANT=cpu ./install.sh voxtype` for the avx2 build, or install CUDA 13 runtime + cuDNN 9. |
