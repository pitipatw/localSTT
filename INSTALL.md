# Installation Guide — local dictation on Pop!_OS COSMIC

This guide walks through installing the stack in `~/dev/localSTT` and, alongside each step, explains what it changes on your system and what the security implications are. Read §1 before running anything; it contains the one decision you need to make.

Everything runs locally. No audio, text, or telemetry leaves the machine at any point after installation. The installation itself downloads four things from the internet: Voxtype, Ollama, the Parakeet speech model, and the Qwen3 language model.

---

## 1. Security model — read this first

### 1.1 What this does and does not change about microphone access

On a Linux desktop there is no per-application microphone permission for native programs. Any process running under your user account can already open the microphone through PipeWire. Installing Voxtype adds one more process with that ability; it does not open a door that was previously closed. In push-to-talk mode Voxtype should only hold a capture stream while the hotkey is down. Verify this yourself after installation with `pw-top`: a `voxtype` capture stream should appear only while you are recording (step 11 below). Voxtype does not keep recordings; audio is transcribed in memory and discarded.

The realistic microphone threat is a compromised user account, and that threat exists with or without this project. The mitigations for it are the usual ones: full-disk encryption, not running untrusted software as your user, keeping the system updated.

### 1.2 Hold-to-talk without the `input` group

Wayland's security model keeps applications from seeing each other's keystrokes. Hold-to-talk needs to see the dictation key's press *and release* no matter which window is focused, and the only way to do that on COSMIC is to read the keyboard at the evdev level — which requires membership in the `input` group.

Being in `input` means **every process running as that account can read every keystroke** from `/dev/input/event*` — a user-level keylogger no longer needs root and can capture passwords typed into terminals, browsers, or sudo prompts. Earlier versions of this project put *your* user in `input` for push-to-talk. That path is gone. Instead, the keyboard is read by a dedicated system user whose only process is small enough to audit in a minute:

```
/dev/input/event*  ──read──▶  hotkeyd   (system user `hotkeyd`, group `input`, sandboxed, 80 lines)
                                 │  one line per transition: "start" / "stop" — nothing else, no key codes
                                 ▼
                    /run/hotkeyd/hotkey.sock   (0660, hotkeyd:<you>; hotkeyd never reads from it)
                                 │
                                 ▼
                    hotkey-relay  (user service, runs as you, NOT in `input`)
                                 │  voxtype record start | voxtype record stop
                                 ▼
                    voxtype daemon (user service; its own hotkey listener is disabled)
```

| | Push-to-talk (`HOTKEY_MODE=push_to_talk`) | Toggle mode (default) |
|---|---|---|
| Feel | Hold the F13 key, speak, release | Press shortcut, speak, press again |
| Group added to *your* user | `uinput` only | `uinput` only |
| Who reads the keyboard | `hotkeyd` system user (`/usr/local/lib/hotkeyd/hotkeyd.py`, root-owned) | nobody — COSMIC delivers the shortcut |
| Hotkey mechanism | hotkeyd → socket → hotkey-relay → `voxtype record start\|stop` | COSMIC custom shortcut → `voxtype record toggle` |
| Keylogger exposure for your processes | unchanged from stock Wayland | unchanged from stock Wayland |
| Keystroke injection | any user process (unavoidable — pasting needs it) | same |
| What a compromise of your account learns | *when* you dictate (start/stop on the socket) | nothing new |

What you are trusting in push-to-talk mode is `hotkeyd.py`: 80 lines of standard-library Python, capped by the installer, with a unit test for the event decoder and the press/release/hold-cap state machine (`tests/test_hotkeyd.py`). It opens only `/dev/input/event*` devices that advertise `KEY_F13`, drops every other key code before looking at it, never logs, and emits `stop` on its own if the key has been down for 60 s. Its systemd unit has no network namespace, no home, no writable filesystem beyond `/run/hotkeyd`, an empty capability set, and read-only access to input devices (`DevicePolicy=closed` + `DeviceAllow=char-input r`); `systemd-analyze security hotkeyd` should score under 3 and the installer prints the score. Any pull request that adds a feature to `hotkeyd.py` (more keys, chords, logging, config) erodes this story and should be rejected.

Toggle mode is still the default because it adds no process at all. Its failure mode — forgetting to stop the recording — is something you notice, and the output sanitizer (§1.6) makes it harmless in a terminal. The chosen mode is remembered in `~/.config/dictate/hotkey_mode`, so a plain re-run keeps it. To switch, re-run with the other `HOTKEY_MODE`; switching to toggle disables hotkeyd and the relay. If an older install put you in `input`, the installer tells you so — remove it with `sudo gpasswd -d $USER input` and log out.

### 1.3 Supply chain — what you are trusting

| Download | Source | Verification the installer does | Residual trust |
|---|---|---|---|
| Voxtype 1.0.1 binary + 2–3 ONNX Runtime `.so` files | GitHub release, pinned version | SHA256 against the release's `SHA256SUMS.txt`, whose signature **must** verify against key `9CCF7915B750CAE8B095ED1AA3FC9F33FD209279` in a dedicated keyring (the signing fingerprint is checked, not just "some key signed it"). `REQUIRE_GPG=0` downgrades to sha256-only with a warning. | The author's signing key and keys.openpgp.org (cached after first fetch in `~/.cache/localstt-downloads/voxtype-signing-key.gpg`). Confirm the fingerprint against the Voxtype release notes once. |
| Ollama 0.33.2 tarball | GitHub release, pinned version | SHA256 against the release's `sha256sum.txt` **and** against `OLLAMA_SHA256` in `install.sh` once you pin it (the installer prints the hash and nags until you do) | GitHub and the Ollama project. **No `curl \| sh`**: the tarball is extracted to `/usr/local` and a sandboxed systemd unit (`ProtectSystem=strict`, `ProtectHome`, `NoNewPrivileges`, …) is written by this repo, bound to `127.0.0.1` only, running as a dedicated `ollama` system user. |
| Parakeet TDT 0.6B v3 (ONNX) | Hugging Face, `istupakov/parakeet-tdt-0.6b-v3-onnx`, **pinned commit** `8f23f0c0` | Each LFS file against a sha256 in `install.sh`; the two small text files against their git blob ids. A mismatching file is deleted. | ONNX is data, but it is parsed and executed by ONNX Runtime inside the process that owns the microphone, so it is treated like a binary. |
| `qwen3:8b` | Ollama registry | After the pull, the weights blob the server loaded is compared with `OLLAMA_MODEL_BLOB_SHA256` | A tag is mutable; the digest is not. GGUF is data and cannot execute code, so a swap would change text output, not the machine. |
| apt packages (`ydotool ydotoold wl-clipboard jq zstd gnupg git python3-pytest`) | Pop!_OS repos | apt signature checking | Same trust as the rest of your system. |
| ydotool 1.0.4 source (only if no `ydotoold` package is available) | GitHub, `ReimuNotMoe/ydotool`, tag `v1.0.4` | The checked-out commit must equal `YDOTOOL_COMMIT` (a tag can be moved; a commit hash cannot) | Small C project you compile yourself; you can read it in `~/.cache/localstt-downloads/ydotool-1.0.4`. |

Versions **and their digests** are pinned together at the top of `install.sh`. To upgrade, change both in the same commit; the installer refuses a version whose digest it does not know.

### 1.4 Your dictations are logged in plaintext

`~/.local/share/dictate/log.jsonl` can store every raw and cleaned transcript. That is what lets you tune the dictionary and prompt, and later fine-tune, but it means anything you ever dictate — a password, an address, a private message — sits in that file. It is **off by default** (`"log_text": false`: metadata only). Controls:

- The file and its directory are created mode `600`/`700` (owner only).
- `dictate log purge` deletes it.
- In `~/.config/dictate/settings.json`, `"log_text": true` records the text; `false` (default) keeps only metadata (timestamp, app, latency, word count); `"log_enabled": false` disables logging entirely. Turn text logging on while tuning the prompt, then off again.
- Every dictation also passes through the Wayland clipboard. A clipboard-history tool will keep its own copy; there is nothing this project can do about that.
- Voxtype's own `VOXTYPE_CONTEXT` variable carries the previous dictation for up to 60 s, in process memory only.

### 1.5 Things that are fine as designed

The ydotool socket is created mode `0600` under `$XDG_RUNTIME_DIR` by a daemon running as you (the installer refuses a root daemon with a `/tmp` socket), so only your user can inject through it. Ollama listens on `127.0.0.1:11434` only and runs in a systemd sandbox; the installer checks both. The cleanup LLM has no tools, so a prompt injection in something you dictate can at worst produce odd text — and §1.6 bounds "odd". The post-process hook is an installed *copy* of `polish.py` (not a symlink into the git checkout), and its `ollama_url` can only point at loopback, so neither a `git pull` nor a one-line settings edit can change what runs or where your dictations go.

### 1.6 What gets pasted

Whatever `polish.py` prints is pasted into the focused window with Shift+Insert. Two rules keep that from ever becoming a command: control characters (ESC, BEL, NUL, carriage return, …) are stripped on every path, so terminal escape sequences cannot survive; and newlines are replaced by spaces unless `"allow_newlines": true` is set in `settings.json` — and never for a terminal-style target, whatever the setting. So a video saying "new line" while you forgot the mic on cannot press Enter in your shell. See README → Settings.

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
chmod +x install.sh polish.py dictate indicator.py tests/latency_report.py
git init && git add -A && git commit -m "initial dictation stack"
```

**Step 2 — run the installer**

```bash
./install.sh                              # toggle mode (default; adds you to `uinput` only)
# or
HOTKEY_MODE=push_to_talk ./install.sh     # hold-to-talk via the sandboxed hotkeyd service (§1.2; still `uinput` only)
```

It asks for your sudo password for: apt installs, the `/dev/uinput` udev rule, the `uinput` group change, extracting Ollama to `/usr/local`, creating the `ollama` user and system service, and — in push-to-talk mode — the `hotkeyd` user, `/usr/local/lib/hotkeyd/hotkeyd.py` and its system service. Everything else is under your home directory. `INDICATOR=0 ./install.sh` skips the recording indicator (Step 5a) — not recommended in toggle mode. Each `==` section ends with green ✔ lines; a yellow `!` is informational; a red ✘ stops the run and says why.

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

In toggle mode Voxtype does not listen to the keyboard at all (`[hotkey] enabled = false`). COSMIC, which as the compositor already sees every key press, runs a command when it sees your shortcut. Press once → recording starts; press again → stops, cleans up, pastes.

*Through the GUI:* COSMIC Settings → **Keyboard** → **View and Customize Shortcuts** → **Custom Shortcuts** → **Add Shortcut**. Name `Dictate`; command `/home/<you>/.local/bin/voxtype record toggle` (full path — shortcuts do not run through your shell, so `~` and `PATH` are not expanded); click the key field and press the combination you want. A modifier combo such as **Super+Space** or **Ctrl+Alt+D** is the reliable choice.

*Bare keys such as F13:* COSMIC's shortcut picker often refuses a key with no modifier, so F13 alone may not register even though it works for push-to-talk. If you want a single physical key anyway, either remap it in the keyboard firmware to a *modified* combo (e.g. Super+F13) and bind that, or write the binding directly and log out/in:

```bash
mkdir -p ~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1
cat > ~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom <<'EOF'
{
    (modifiers: [], key: "F13"): Spawn("/home/<you>/.local/bin/voxtype record toggle"),
}
EOF
```

(If the file already exists, add the line inside the existing braces.) Check first with `wev` that the key actually reaches the compositor as `F13`; if it does not, fix the firmware mapping before fighting the picker.

*Test the binding:* open a text editor, press the shortcut, say "testing one two three", press it again. If nothing happens, run `/home/<you>/.local/bin/voxtype record toggle` twice from a terminal — if that records and pastes, the problem is the shortcut; if it does not, look at `journalctl --user -u voxtype -f`.

**Step 5a — the recording indicator (on by default)**

Toggle mode's one failure mode is forgetting the second press: the mic stays open and whatever the room says is pasted when you finally stop it. The `indicator` step installs `dictate-indicator`, a user service that paints a **green border around every monitor while the microphone is open** and draws nothing otherwise. It turns amber and pulses for the last 10 s before Voxtype's own hard cap (`[audio] max_duration_secs = 60` in the config — raise it for long dictation; the indicator reads the value) stops the recording and pastes what it has.

How it knows: it reads Voxtype's state file (`$XDG_RUNTIME_DIR/voxtype/state`, `state_file = "auto"` in the config) *and* asks PipeWire every 500 ms whether a running `voxtype` capture stream exists. Either one lights the border, so an indicator driven by the real audio graph cannot claim the mic is closed while it is open. It shows state only — it never sees the transcript.

Fail-visible rule: **no glow means the mic is closed — or the indicator is down.** If you think you are recording and see no border, treat that as "check the mic": `pw-top` (a `voxtype` capture row = still recording; press your shortcut) and `systemctl --user status dictate-indicator`. The unit restarts itself on any crash.

Why it cannot steal the paste: the overlay is a Wayland layer-shell surface on the overlay layer with keyboard interactivity *none*, an empty input region and exclusive zone −1, so the compositor never gives it focus, keys or pointer events and it reserves no screen space. Verify once per app you care about:

```bash
dictate-indicator --demo 8 &          # glow for 8 s regardless of state
echo "paste-through test" | wl-copy; sleep 2; ydotool key -d 60 42:1 110:1 110:0 42:0   # shift+insert into a focused editor
```

Text must appear while the border is up. Tested targets: a GTK app (COSMIC Text Editor), an Electron app (Claude/VS Code) and Alacritty. `dictate-indicator --check` verifies the graphics stack (GTK 4 + gtk4-layer-shell + a layer-shell-capable compositor) and is what the installer runs.

Dependencies (apt): `python3-gi python3-gi-cairo gir1.2-gtk-4.0`. gtk4-layer-shell has no package on Ubuntu/Pop!_OS 24.04, so the installer builds v1.1.1 from a pinned commit into `~/.local/lib` (build tools via apt: meson, ninja, libgtk-4-dev, …); on releases that package `gir1.2-gtk4layershell-1.0` it uses that instead. `dictate-indicator` searches `~/.local/lib` itself when neither the distro package nor `GTK4_LAYER_SHELL_LIB` is present, so the commands above work in a plain terminal; the user unit also carries explicit `Environment=` lines for the same paths. Nothing in `polish.py` changes — the indicator is a separate process with no network (`RestrictAddressFamilies=AF_UNIX`), not in the `input` group, running as you.

`INDICATOR=0 ./install.sh indicator` disables the unit again.

**Step 6 — paste path probe (no microphone yet)**

```bash
echo "hello from ydotool" | wl-copy
# click into COSMIC Text Editor, then within 3 s:
sleep 3 && ydotool key -d 60 42:1 110:1 110:0 42:0    # shift+insert; see the note below
```

Text must appear. If not: `systemctl --user status ydotool`, `ls -l /dev/uinput` (group `uinput`, mode 660), `echo $YDOTOOL_SOCKET`.

The numeric arguments are not decoration. ydotool 1.x takes `keycode:state` pairs (42 = `KEY_LEFTSHIFT`, 110 = `KEY_INSERT`), and it **exits 0 without injecting anything** when handed a 0.x-style name like `shift+insert` — so the older form looks like a silent install failure rather than a bad command. `-d 60` matches `type_delay_ms` so the probe behaves like the real paste path in Electron apps (see §Troubleshooting). Voxtype itself parses `paste_keys = "shift+insert"` and calls ydotool with these same codes.

**Step 7 — LLM probe (no microphone yet)**

```bash
dictate test "send it monday actually delete that send it friday"
```

Expect `[llm]` and something like `final: Send it Friday.` If you see `[llm_error …]`: `systemctl status ollama`, `ollama list`, `ss -ltn | grep 11434`.

**Step 8 — first dictation**

Click into the text editor. Toggle (default): press your shortcut from Step 5, say "testing one two three", press it again. Push-to-talk: hold the F13 key, speak, release. Text should appear in about a second. If nothing happens, run `journalctl --user -u voxtype -f` in another terminal and try again. Common causes: the daemon is not running (`systemctl --user status voxtype`), the hotkey is not seen (toggle: the COSMIC binding; push-to-talk: `systemctl status hotkeyd`, `systemctl --user status hotkey-relay`), the paste failed (`uinput` group not yet active — did you log out?), or the paste landed in another window (an overlay stole focus — keep any OSD disabled).

**Step 9 — GPU check**

`journalctl --user -u voxtype | grep -i -E "cuda|provider|cpu"` should show the CUDA execution provider loading. If it says it fell back to CPU, the ONNX Runtime CUDA provider could not find cuDNN 9 / the CUDA 12 runtime libraries on the system. Voxtype still works on CPU (slower, ~1 s per utterance instead of ~0.2 s). To enable the GPU, install cuDNN 9 for CUDA 12 — on Pop!_OS the `system76-cudnn-12.x` packages, or NVIDIA's `libcudnn9-cuda-12` — then `systemctl --user restart voxtype`. The exact package names change; `apt search cudnn` lists what is available. **[verify]** — this is the one part of the stack whose runtime requirements are not documented by Voxtype.

**Step 10 — integration checks**

Repeat step 8 in Firefox/Edge, VS Code, and the Claude app (all accept `shift+insert`, so no per-app configuration). Copy an image, dictate, confirm the image is still on the clipboard afterwards. Hold and release without speaking: nothing should paste. Dictate for 30 s: no truncation.

**Known exception: COSMIC Terminal.** It pastes only on Ctrl+Shift+V and ignores Shift+Insert, and there is no single chord that works in terminals *and* GTK/Electron apps. Dictation into COSMIC Terminal is therefore not supported; the text is still copied to the clipboard for ~300 ms, but not long enough to paste by hand. If terminal dictation matters to you, Alacritty, kitty and foot all honour Shift+Insert.

**Step 11 — microphone-in-use check**

Run `pw-top` in a terminal. While idle, there should be no `voxtype` capture stream; while recording, one should appear; when you release, it should go away. The screen-edge glow (Step 5a) must be visible exactly while that stream exists — on every monitor — and nothing must be drawn once it is gone. Expect two rows while recording: the microphone *device* (e.g. a webcam's audio node, woken up because something is reading from it) and the `voxtype` *stream* consuming it — that pairing is normal. A `voxtype` row that persists while idle, or the device staying active with no stream under it, would be worth investigating. If a stream stays open permanently, that is worth knowing (and worth reporting upstream); it does not mean audio is being sent anywhere, but it is the behaviour §1.1 assumes.

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
| group membership `uinput` | uinput access (pasting) | `sudo gpasswd -d $USER uinput` |
| user `hotkeyd`, `/usr/local/lib/hotkeyd/hotkeyd.py`, `/etc/systemd/system/hotkeyd.service`, `~/.local/bin/hotkey-relay`, `~/.config/systemd/user/hotkey-relay.service` (push-to-talk only) | hold-to-talk keyboard reader + relay | `systemctl --user disable --now hotkey-relay; sudo systemctl disable --now hotkeyd; sudo rm -rf /usr/local/lib/hotkeyd /etc/systemd/system/hotkeyd.service; sudo userdel hotkeyd`, then delete the two user files |
| `/usr/local/bin/ollama`, `/usr/local/lib/ollama/`, `/etc/systemd/system/ollama.service`, user `ollama`, `/usr/share/ollama/` (models) | Ollama | `sudo systemctl disable --now ollama; sudo rm -rf /usr/local/bin/ollama /usr/local/lib/ollama /etc/systemd/system/ollama.service; sudo userdel -r ollama` |
| `~/.local/lib/voxtype/`, `~/.local/bin/voxtype` (wrapper), `~/.local/bin/polish.py`, `~/.local/bin/dictate` | Voxtype + hooks | `rm -rf` those paths |
| `~/.local/bin/dictate-indicator`, `~/.config/systemd/user/dictate-indicator.service`, `~/.local/lib/libgtk4-layer-shell*`, `~/.local/lib/girepository-1.0/Gtk4LayerShell-1.0.typelib`, `~/.local/include/gtk4-layer-shell/`, `~/.local/lib/pkgconfig/gtk4-layer-shell-0.pc`, `~/.local/share/gir-1.0/Gtk4LayerShell-1.0.gir` | recording indicator | `systemctl --user disable --now dictate-indicator`, then delete |
| `~/.local/share/voxtype/models/` | Parakeet | `rm -rf` |
| `~/.config/voxtype/config.toml`, `~/.config/dictate/`, `~/.config/systemd/user/{ydotool,voxtype}.service*`, `~/.config/environment.d/ydotool.conf`, `~/.profile` (one `export YDOTOOL_SOCKET` line) | config | `systemctl --user disable --now voxtype ydotool`, then delete |
| `~/.local/share/dictate/log.jsonl` | dictation log | `dictate log purge` |
| `~/.cache/localstt-downloads/` | verified downloads | `rm -rf` |

---

## 5. Hotkey: why F13, and the modifier-key trap

This section is about **push-to-talk**, where `hotkeyd` reads the key at the evdev level (it looks for `KEY_F13`, code 183, and nothing else). In toggle mode the key is a COSMIC shortcut (Step 5) and none of the following applies — there a modifier combo is the *preferred* choice.

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
| `ydotool key` does nothing | `ls -l /dev/uinput` is group `uinput`; `id -nG` includes it; `echo $YDOTOOL_SOCKET` matches `systemctl --user show ydotool -p ExecStart` |
| Text comes out as digits | A `wtype`/`eitype` driver got used. `driver_order` must start with `ydotool`. |
| Paste lands in the wrong window | Disable any Voxtype OSD/overlay. |
| `[llm_error]` in `dictate test` | `systemctl status ollama`, `ss -ltn \| grep 11434`, `ollama list` |
| Transcription slow (~1 s+) | GPU fallback to CPU; see step 9. |
| Checksum mismatch | Delete `~/.cache/localstt-downloads/*` and re-run. If it persists, do not install — the release may have been re-uploaded or tampered with; compare against the GitHub release page. |
| Hotkey ignored in push-to-talk | `systemctl status hotkeyd` and `systemctl --user status hotkey-relay` (both must be active); `sudo journalctl -u hotkeyd` for "permission denied" on `/dev/input`; `ls -l /run/hotkeyd/hotkey.sock` must be `660 hotkeyd:<you>`; `sudo evtest` to confirm the keyboard reports `KEY_F13` (hotkeyd ignores every other code) |
| Pastes in GTK apps but not Electron (Claude, VS Code) | Hotkey is a modifier key → §5. Also check `type_delay_ms = 60`. |
| `4114` (or other digits) typed instead of a paste | ydotool client is pre-1.0 → §5; `./install.sh ydotool` builds 1.0.4. |
| Daemon logs `Loading Parakeet … model` and nothing after; 0 % CPU | CUDA build hung in its CPU fallback (no CUDA runtime installed). `VOXTYPE_VARIANT=cpu ./install.sh voxtype` for the avx2 build, or install CUDA 13 runtime + cuDNN 9. |
