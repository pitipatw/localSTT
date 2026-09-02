#!/usr/bin/env bash
# Idempotent installer for the local dictation stack on Pop!_OS COSMIC (Wayland).
# Re-run freely; every step checks before it acts and ends with a verification.
#
#   ./install.sh            run all steps
#   ./install.sh --list     show step names
#   ./install.sh <step>...  run only the named steps (e.g. ./install.sh voxtype model)
#
# Steps that need sudo will prompt. Steps that need a re-login say so and keep going.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
DICTATE_DIR="$HOME/.config/dictate"
VOX_CFG_DIR="$HOME/.config/voxtype"
MODEL_DIR="$HOME/.local/share/voxtype/models/parakeet-tdt-0.6b-v3"
HF_REPO="https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main"
OLLAMA_MODEL="qwen3:8b"
NEED_RELOGIN=0

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; exit 1; }
step()  { echo; bold "== $1"; }

# ----------------------------------------------------------------------------
step_preflight() {
  step "preflight"
  [[ "$(uname -m)" == "x86_64" ]] || fail "expected x86_64"
  command -v nvidia-smi >/dev/null || fail "nvidia-smi missing — install the NVIDIA driver first"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/  /'
  if command -v pactl >/dev/null && pactl info 2>/dev/null | grep -qi pipewire; then
    ok "audio server is PipeWire"
  else
    warn "could not confirm PipeWire (pactl info) — Voxtype may still work via ALSA/Pulse"
  fi
  [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && ok "Wayland session" || warn "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset} (expected wayland)"
  echo "  keyboard layout: $(localectl status 2>/dev/null | grep -i 'x11 layout' | awk '{print $NF}' || echo unknown)  (irrelevant with paste_keys=shift+insert)"
}

step_apt() {
  step "apt packages"
  local pkgs=(ydotool wl-clipboard curl jq python3 python3-pytest)
  local missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
  fi
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || fail "$p not installed"; done
}

step_ydotool() {
  step "ydotool / uinput"
  if id -nG "$USER" | grep -qw input; then
    ok "$USER is in group input"
  else
    sudo usermod -aG input "$USER"; NEED_RELOGIN=1
    warn "added $USER to group input — takes effect after logout/login"
  fi
  local rule=/etc/udev/rules.d/80-uinput.rules
  local want='KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"'
  if [[ -f $rule ]] && grep -qF "$want" "$rule"; then
    ok "udev rule present"
  else
    echo "$want" | sudo tee "$rule" >/dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger
    ok "udev rule written"
  fi
  sudo modprobe uinput 2>/dev/null || true
  grep -q '^uinput$' /etc/modules-load.d/*.conf 2>/dev/null || echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
  ls -l /dev/uinput | sed 's/^/  /'

  # user daemon: use the distro unit if it exists, else ours
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/environment.d"
  if ! systemctl --user cat ydotool >/dev/null 2>&1; then
    cp "$REPO/systemd/ydotool.service" "$HOME/.config/systemd/user/ydotool.service"
    systemctl --user daemon-reload
    ok "installed user unit from repo"
  else
    ok "ydotool user unit already available"
  fi
  systemctl --user enable --now ydotool
  sleep 0.5
  local sock
  sock=$(systemctl --user show ydotool -p ExecStart --value | grep -o -- '--socket-path=[^ ]*' | cut -d= -f2 || true)
  sock="${sock//%t/$XDG_RUNTIME_DIR}"
  [[ -z $sock ]] && sock="/tmp/.ydotool_socket"   # distro default
  echo "YDOTOOL_SOCKET=$sock" > "$HOME/.config/environment.d/ydotool.conf"
  grep -q YDOTOOL_SOCKET "$HOME/.profile" 2>/dev/null || echo "export YDOTOOL_SOCKET=\"$sock\"" >> "$HOME/.profile"
  export YDOTOOL_SOCKET="$sock"
  systemctl --user is-active ydotool >/dev/null && ok "ydotoold running, socket $sock" || fail "ydotoold not running: journalctl --user -u ydotool"
  [[ -S $sock ]] && ok "socket exists" || warn "socket $sock not found yet (re-login may be needed)"
}

step_ollama() {
  step "Ollama + $OLLAMA_MODEL"
  if ! command -v ollama >/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  ok "ollama $(ollama --version 2>/dev/null | head -1)"
  systemctl is-active ollama >/dev/null 2>&1 || sudo systemctl enable --now ollama || true
  ollama list 2>/dev/null | grep -q "^${OLLAMA_MODEL}" || ollama pull "$OLLAMA_MODEL"
  local t0 t1 resp
  t0=$(date +%s%N)
  resp=$(curl -s http://localhost:11434/api/chat -d "{\"model\":\"$OLLAMA_MODEL\",\"think\":false,\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}")
  t1=$(date +%s%N)
  echo "$resp" | jq -r '.message.content' | grep -qi ok && ok "model answers ($(( (t1-t0)/1000000 )) ms, first call includes load)" || fail "unexpected reply: $resp"
}

step_voxtype() {
  step "Voxtype (ONNX+CUDA build)"
  if command -v voxtype >/dev/null; then
    ok "already installed: $(voxtype --version 2>/dev/null | head -1)"
    return
  fi
  local api="https://api.github.com/repos/peteonrails/voxtype/releases/latest"
  local url
  url=$(curl -fsSL "$api" | jq -r '.assets[].browser_download_url' | grep -i 'onnx-cuda' | grep -i 'x86_64\|amd64' | grep -i '\.deb$' | head -1 || true)
  if [[ -n $url ]]; then
    echo "  downloading $url"
    curl -fL -o /tmp/voxtype.deb "$url"
    sudo apt-get install -y /tmp/voxtype.deb
  else
    url=$(curl -fsSL "$api" | jq -r '.assets[].browser_download_url' | grep -i 'onnx-cuda' | grep -i 'x86_64' | grep -i 'appimage' | head -1 || true)
    [[ -n $url ]] || fail "no onnx-cuda x86_64 asset found in latest release — open https://github.com/peteonrails/voxtype/releases and install manually"
    mkdir -p "$BIN"; curl -fL -o "$BIN/voxtype" "$url"; chmod +x "$BIN/voxtype"
  fi
  command -v voxtype >/dev/null && ok "installed $(voxtype --version 2>/dev/null | head -1)" || fail "voxtype not on PATH (is ~/.local/bin in PATH?)"
}

step_model() {
  step "Parakeet TDT 0.6B v3 (ONNX)"
  mkdir -p "$MODEL_DIR"
  local f
  for f in encoder-model.onnx encoder-model.onnx.data decoder_joint-model.onnx vocab.txt config.json; do
    if [[ -s "$MODEL_DIR/$f" ]]; then ok "$f"; else
      echo "  fetching $f"
      curl -fL --progress-bar -o "$MODEL_DIR/$f" "$HF_REPO/$f"
    fi
  done
  du -sh "$MODEL_DIR" | sed 's/^/  /'
}

step_config() {
  step "config + hooks"
  mkdir -p "$BIN" "$DICTATE_DIR" "$VOX_CFG_DIR"
  chmod +x "$REPO/polish.py" "$REPO/dictate"
  ln -sfn "$REPO/polish.py" "$BIN/polish.py"
  ln -sfn "$REPO/dictate"   "$BIN/dictate"
  ok "symlinked polish.py and dictate into $BIN"
  local f
  for f in prompt.md corrections.json snippets.json jargon.txt settings.json; do
    if [[ -e "$DICTATE_DIR/$f" ]]; then ok "$f exists (kept)"; else cp "$REPO/config/$f" "$DICTATE_DIR/$f"; ok "$f installed"; fi
  done
  local cfg="$VOX_CFG_DIR/config.toml"
  if [[ -e $cfg ]] && ! cmp -s "$cfg" "$REPO/config/voxtype.config.toml"; then
    cp "$cfg" "$cfg.bak.$(date +%s)"; warn "existing config.toml backed up"
  fi
  sed "s#/home/pitipatw#$HOME#g" "$REPO/config/voxtype.config.toml" > "$cfg"
  ok "wrote $cfg"
  printf 'um so uh this is a test of the polish hook with enough words' | "$BIN/polish.py" >/dev/null && ok "polish.py runs end to end (see: dictate log tail 1)"
}

step_service() {
  step "voxtype daemon"
  voxtype setup || warn "voxtype setup reported issues (see above)"
  voxtype setup systemd || warn "voxtype setup systemd failed — run it manually"
  systemctl --user enable --now voxtype 2>/dev/null || warn "could not enable voxtype unit"
  sleep 2
  systemctl --user is-active voxtype >/dev/null && ok "voxtype running" || warn "voxtype not active: journalctl --user -u voxtype -f"
}

step_summary() {
  step "next: manual checks"
  cat <<EOF
  1. $( ((NEED_RELOGIN)) && echo "LOG OUT AND BACK IN (input group), then re-run: ./install.sh ydotool service" || echo "no re-login needed" )
  2. Clipboard paste probe: echo hello | wl-copy; focus an editor; sleep 3 && ydotool key shift+insert
  3. Hold RIGHT CTRL, say "testing one two three", release → text appears in the focused box
  4. dictate test "send it monday actually delete that send it friday"
  5. Latency: after ~20 dictations run: dictate log stats
  Logs: journalctl --user -u voxtype -f   |   ~/.local/share/dictate/log.jsonl
EOF
}

ALL=(preflight apt ydotool ollama voxtype model config service summary)
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
if (($#)); then STEPS=("$@" summary); else STEPS=("${ALL[@]}"); fi
for s in "${STEPS[@]}"; do
  declare -F "step_$s" >/dev/null || fail "unknown step: $s (see --list)"
  "step_$s"
done
