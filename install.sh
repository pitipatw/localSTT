#!/usr/bin/env bash
# Idempotent installer for the local dictation stack on Pop!_OS COSMIC (Wayland).
# Re-run freely; every step checks before it acts and ends with a verification.
#
#   ./install.sh                      run all steps (push-to-talk, needs `input` group)
#   HOTKEY_MODE=toggle ./install.sh   toggle mode: no `input` group, hotkey via COSMIC shortcut
#   ./install.sh --list               show step names
#   ./install.sh <step>...            run only the named steps (e.g. ./install.sh voxtype model)
#
# Security posture (see INSTALL.md):
#   * Nothing is piped from the network into a shell. Binaries are pinned to the
#     versions below and checked against the publisher's SHA256 list; Voxtype's
#     list is also GPG-verified when gpg is available.
#   * The only privileged actions are apt installs, the udev rule, group membership,
#     and installing Ollama under /usr/local with its own system user.

set -euo pipefail
trap 'printf "  \033[31m✘\033[0m unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---- pinned versions -------------------------------------------------------
VOXTYPE_VERSION="1.0.1"
VOXTYPE_GPG_KEY="9CCF7915B750CAE8B095ED1AA3FC9F33FD209279"   # from the release notes
OLLAMA_VERSION="0.33.2"
OLLAMA_MODEL="qwen3:8b"
YDOTOOL_VERSION="1.0.4"        # only used if the distro package lacks ydotoold
PARAKEET_REPO="https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main"
# ---------------------------------------------------------------------------

HOTKEY_MODE="${HOTKEY_MODE:-push_to_talk}"     # push_to_talk | toggle
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
VOX_LIB="$HOME/.local/lib/voxtype"
DICTATE_DIR="$HOME/.config/dictate"
VOX_CFG_DIR="$HOME/.config/voxtype"
MODEL_DIR="$HOME/.local/share/voxtype/models/parakeet-tdt-0.6b-v3"
LOG_DIR="$HOME/.local/share/dictate"
DL="$HOME/.cache/localstt-downloads"
NEED_RELOGIN=0
mkdir -p "$DL"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; exit 1; }
step()  { echo; bold "== $1"; }
fetch() { # fetch <url> <dest>  (skips if dest exists and is non-empty)
  [[ -s "$2" ]] && return 0
  curl -fL --progress-bar --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

case "$HOTKEY_MODE" in
  push_to_talk) UINPUT_GROUP=input ;;
  toggle)       UINPUT_GROUP=uinput ;;
  *) fail "HOTKEY_MODE must be push_to_talk or toggle" ;;
esac

build_ydotool() {
  # Source build of ReimuNotMoe/ydotool at a pinned tag. Installs ydotool + ydotoold
  # into ~/.local/bin (takes precedence over /usr/bin when ~/.local/bin is first in PATH).
  local need=() p
  for p in cmake build-essential git scdoc; do dpkg -s "$p" >/dev/null 2>&1 || need+=("$p"); done
  ((${#need[@]})) && sudo apt-get install -y "${need[@]}"
  local src="$DL/ydotool-$YDOTOOL_VERSION"
  if [[ ! -d $src/.git ]]; then
    git clone --depth 1 --branch "v$YDOTOOL_VERSION" https://github.com/ReimuNotMoe/ydotool "$src"
  fi
  echo "  source: $(git -C "$src" rev-parse HEAD) (tag v$YDOTOOL_VERSION)"
  cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/.local" >/dev/null
  cmake --build "$src/build" -j"$(nproc)" >/dev/null
  # not `cmake --install`: it also tries to drop a unit into /usr/lib/systemd (needs root; we have our own unit)
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$src/build/ydotool" "$src/build/ydotoold" "$HOME/.local/bin/"
  [[ -x "$HOME/.local/bin/ydotoold" && -x "$HOME/.local/bin/ydotool" ]] || fail "ydotool build failed — see $src/build"
  ok "built ydotool $YDOTOOL_VERSION → $HOME/.local/bin/{ydotool,ydotoold}"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not on PATH; add it to ~/.profile" ;; esac
}

# ----------------------------------------------------------------------------
step_preflight() {
  step "preflight  (mode: $HOTKEY_MODE, uinput group: $UINPUT_GROUP)"
  [[ "$(uname -m)" == "x86_64" ]] || fail "expected x86_64"
  command -v nvidia-smi >/dev/null || fail "nvidia-smi missing — install the NVIDIA driver first"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/  /'
  if command -v pactl >/dev/null && pactl info 2>/dev/null | grep -qi pipewire; then
    ok "audio server is PipeWire"
  else
    warn "could not confirm PipeWire (pactl info)"
  fi
  [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && ok "Wayland session" || warn "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset} (expected wayland)"
}

step_apt() {
  step "apt packages"
  # Debian/Ubuntu split ydotool into `ydotool` (client) and `ydotoold` (daemon).
  local pkgs=(ydotool ydotoold wl-clipboard curl jq zstd gnupg python3 python3-pytest)
  local missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}" || {
      warn "some packages failed to install; retrying without ydotoold (will build it from source instead)"
      sudo apt-get install -y "${missing[@]/ydotoold/}"
    }
  fi
  for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then ok "$p"
    elif [[ $p == ydotoold ]]; then warn "ydotoold package unavailable — the ydotool step will build it from source"
    else fail "$p not installed"; fi
  done
}

step_ydotool() {
  step "ydotool / uinput  (group: $UINPUT_GROUP)"
  if [[ $UINPUT_GROUP == uinput ]] && ! getent group uinput >/dev/null; then
    sudo groupadd --system uinput; ok "created group uinput"
  fi
  if id -nG "$USER" | grep -qw "$UINPUT_GROUP"; then
    ok "$USER is in group $UINPUT_GROUP"
  else
    sudo usermod -aG "$UINPUT_GROUP" "$USER"; NEED_RELOGIN=1
    warn "added $USER to group $UINPUT_GROUP — takes effect after logout/login"
  fi
  if [[ $UINPUT_GROUP == uinput ]] && id -nG "$USER" | grep -qw input; then
    warn "$USER is ALSO in group 'input' (keyboard read access). Toggle mode does not need it: sudo gpasswd -d $USER input"
  fi

  local rule=/etc/udev/rules.d/80-uinput.rules
  local want="KERNEL==\"uinput\", GROUP=\"$UINPUT_GROUP\", MODE=\"0660\", OPTIONS+=\"static_node=uinput\""
  if [[ -f $rule ]] && grep -qF "$want" "$rule"; then
    ok "udev rule present"
  else
    echo "$want" | sudo tee "$rule" >/dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger
    ok "udev rule written"
  fi
  sudo modprobe uinput 2>/dev/null || true
  grep -qs '^uinput$' /etc/modules-load.d/*.conf || echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
  ls -l /dev/uinput | sed 's/^/  /'

  mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/environment.d"
  local sock daemon

  # Case A: the distro runs ydotoold as a SYSTEM service (root). Use it as-is.
  if systemctl is-active ydotool >/dev/null 2>&1; then
    sock=$(systemctl show ydotool -p ExecStart --value | grep -o -- '--socket-path=[^ ]*' | cut -d= -f2 || true)
    [[ -z $sock ]] && sock="/tmp/.ydotool_socket"
    ok "distro system ydotool.service is running (socket $sock); not installing a user unit"
    systemctl --user disable --now ydotool >/dev/null 2>&1 || true
  else
    # Case B: our user unit. Locate the daemon binary — packages differ on where it lives.
    # Voxtype drives ydotool with 1.0-style numeric args ("42:1 110:1 …"); a pre-1.0 client
    # types those literally (you see "4114" instead of a paste). Build 1.0.x if the package is older.
    local pkgver
    pkgver=$(dpkg-query -W -f='${Version}' ydotool 2>/dev/null || echo 0)
    if [[ -x "$HOME/.local/bin/ydotoold" && -x "$HOME/.local/bin/ydotool" && ${YDOTOOL_FROM_SOURCE:-0} != 1 ]]; then
      ok "ydotool $YDOTOOL_VERSION already built in $HOME/.local/bin (YDOTOOL_FROM_SOURCE=1 to rebuild)"
    elif [[ ${YDOTOOL_FROM_SOURCE:-0} == 1 ]] || ! dpkg --compare-versions "$pkgver" ge 1.0; then
      warn "packaged ydotool is $pkgver (< 1.0) — building $YDOTOOL_VERSION from source so Voxtype's key syntax works"
      build_ydotool
    fi
    daemon=$(command -v ydotoold 2>/dev/null || true)
    [[ -x "$HOME/.local/bin/ydotoold" ]] && daemon="$HOME/.local/bin/ydotoold"
    [[ -z $daemon ]] && daemon=$(ls /usr/libexec/ydotoold /usr/sbin/ydotoold /usr/lib/ydotool/ydotoold /usr/local/bin/ydotoold 2>/dev/null | head -1 || true)
    [[ -z $daemon ]] && daemon=$(dpkg -L ydotool 2>/dev/null | grep -E '/ydotoold$' | head -1 || true)
    if [[ -z $daemon || ! -x $daemon ]] && apt-cache show ydotoold >/dev/null 2>&1; then
      sudo apt-get install -y ydotoold && daemon=$(command -v ydotoold 2>/dev/null || true)
    fi
    if [[ -z $daemon || ! -x $daemon ]]; then
      warn "no ydotoold package available — building ydotool $YDOTOOL_VERSION from source into $HOME/.local"
      build_ydotool
      daemon="$HOME/.local/bin/ydotoold"
    fi
    ok "ydotoold at $daemon"
    local unit="$HOME/.config/systemd/user/ydotool.service"
    if [[ ! -f $unit ]] || ! grep -q "^ExecStart=$daemon" "$unit"; then
      sed "s#^ExecStart=/usr/bin/ydotoold#ExecStart=$daemon#" "$REPO/systemd/ydotool.service" > "$unit"
      systemctl --user daemon-reload
      ok "wrote user unit ($unit)"
    else
      ok "user unit up to date"
    fi
    systemctl --user reset-failed ydotool >/dev/null 2>&1 || true
    systemctl --user enable ydotool >/dev/null 2>&1 || true
    systemctl --user restart ydotool || true
    sleep 1
    # Some builds ignore --socket-path; trust what the daemon says it did.
    sock=$(journalctl --user -u ydotool --since "-30s" --no-pager 2>/dev/null \
           | grep -o 'listening on socket [^ ]*' | tail -1 | awk '{print $NF}' || true)
    if [[ -z $sock ]]; then
      sock=$(systemctl --user show ydotool -p ExecStart --value | grep -o -- '--socket-path=[^ ]*' | cut -d= -f2 || true)
      sock="${sock//%t/$XDG_RUNTIME_DIR}"
    fi
    [[ -z $sock ]] && sock="/tmp/.ydotool_socket"
  fi

  echo "YDOTOOL_SOCKET=$sock" > "$HOME/.config/environment.d/ydotool.conf"
  sed -i '/YDOTOOL_SOCKET/d' "$HOME/.profile" 2>/dev/null || true
  echo "export YDOTOOL_SOCKET=\"$sock\"" >> "$HOME/.profile"
  export YDOTOOL_SOCKET="$sock"

  if systemctl is-active ydotool >/dev/null 2>&1 || systemctl --user is-active ydotool >/dev/null 2>&1; then
    ok "ydotoold running, socket $sock"
    if [[ -S $sock ]]; then
      ls -l "$sock" | sed 's/^/  /'
      [[ "$(stat -c %a "$sock")" == "600" ]] || warn "socket is not mode 600 — other local users could inject keystrokes; consider a system-wide multi-user review"
    else
      warn "socket $sock not present — check: journalctl --user -u ydotool -n 5"
    fi
  elif ((NEED_RELOGIN)); then
    warn "ydotoold cannot open /dev/uinput until you log out and back in — expected on first run; continuing"
  else
    journalctl --user -u ydotool -n 6 --no-pager | sed 's/^/  /'
    fail "ydotoold not running (see log above). Show me: dpkg -L ydotool ; id -nG ; ls -l /dev/uinput"
  fi
}

step_ollama() {
  step "Ollama $OLLAMA_VERSION + $OLLAMA_MODEL  (pinned tarball, sha256-verified, no curl|sh)"
  local marker="$DL/ollama-$OLLAMA_VERSION.installed"
  if [[ -f $marker && -x /usr/local/bin/ollama ]]; then
    ok "ollama $OLLAMA_VERSION already extracted to /usr/local"
  else
    local base="https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION"
    fetch "$base/ollama-linux-amd64.tar.zst" "$DL/ollama-$OLLAMA_VERSION.tar.zst"
    fetch "$base/sha256sum.txt"              "$DL/ollama-$OLLAMA_VERSION.sha256sum.txt"
    local want have
    # checksum lines look like "<hash>  ./ollama-linux-amd64.tar.zst" (path prefix and binary-mode '*' both tolerated)
    want=$(grep -E '[ */]ollama-linux-amd64\.tar\.zst$' "$DL/ollama-$OLLAMA_VERSION.sha256sum.txt" | awk '{print $1}' | head -1 || true)
    have=$(sha256sum "$DL/ollama-$OLLAMA_VERSION.tar.zst" | awk '{print $1}')
    [[ -n $want ]] || fail "could not find ollama-linux-amd64.tar.zst in sha256sum.txt — show me: cat $DL/ollama-$OLLAMA_VERSION.sha256sum.txt"
    [[ $want == "$have" ]] || fail "ollama tarball checksum mismatch (want $want, have $have) — delete $DL/ollama-* and retry"
    ok "sha256 verified"
    sudo tar -C /usr/local --zstd -xf "$DL/ollama-$OLLAMA_VERSION.tar.zst"
    touch "$marker"
    ok "extracted to /usr/local/bin/ollama"
  fi
  if ! id ollama >/dev/null 2>&1; then
    sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
  fi
  local unit=/etc/systemd/system/ollama.service
  if [[ -f $unit ]] && ! grep -q '^# managed by localSTT' "$unit"; then   # foreign unit: back up before replacing
    sudo cp "$unit" "$unit.bak.$(date +%s)"
    warn "replacing pre-existing $unit (backup kept) so the service runs the verified binary bound to 127.0.0.1"
  fi
  if [[ ! -f $unit ]] || ! grep -q '^# managed by localSTT v2' "$unit"; then
    sudo tee "$unit" >/dev/null <<'EOF'
# managed by localSTT v2 (install.sh) — keeps the cleanup model resident in VRAM so the
# first dictation after idle does not hit the hook's 4 s timeout.
[Unit]
Description=Ollama (local LLM server)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="HOME=/usr/share/ollama"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
  fi
  sudo systemctl enable ollama >/dev/null 2>&1
  sudo systemctl restart ollama          # restart, not start: an older Ollama may already be running
  local running=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    running=$(curl -s http://127.0.0.1:11434/api/version 2>/dev/null | jq -r '.version // empty' || true)
    [[ -n $running ]] && break; sleep 1
  done
  [[ $running == "$OLLAMA_VERSION" ]] && ok "server running $running" || fail "server on :11434 reports version '${running:-none}', expected $OLLAMA_VERSION — sudo journalctl -u ollama -n 20"
  ss -ltn | grep -q '127.0.0.1:11434' && ok "listening on 127.0.0.1:11434 only" || warn "not bound to 127.0.0.1:11434 — check: ss -ltn | grep 11434"
  ollama list 2>/dev/null | grep -q "^${OLLAMA_MODEL}" || ollama pull "$OLLAMA_MODEL"
  local t0 t1 resp
  t0=$(date +%s%N)
  resp=$(curl -s http://127.0.0.1:11434/api/chat -d "{\"model\":\"$OLLAMA_MODEL\",\"think\":false,\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}")
  t1=$(date +%s%N)
  echo "$resp" | jq -r '.message.content' | grep -qi ok && ok "model answers ($(( (t1-t0)/1000000 )) ms incl. first load)" || fail "unexpected reply: $resp"
}

step_voxtype() {
  # VOXTYPE_VARIANT=auto (cuda-12/13 by driver) | cpu (onnx-avx2, no GPU libs needed).
  # Unset: keep whatever variant is already installed (recorded in $VOX_LIB/.variant); auto on a fresh machine.
  local stamp="$VOX_LIB/.variant"
  local want_variant="${VOXTYPE_VARIANT:-$(cat "$stamp" 2>/dev/null || echo auto)}"
  step "Voxtype $VOXTYPE_VERSION  (variant: $want_variant, sha256 + GPG verified)"
  if [[ -x "$VOX_LIB/voxtype" ]] && "$VOX_LIB/voxtype" --version 2>/dev/null | grep -q "$VOXTYPE_VERSION" \
     && [[ "$(cat "$stamp" 2>/dev/null)" == "$want_variant" ]]; then
    ok "already installed: $("$VOX_LIB/voxtype" --version | head -1) ($(cat "$stamp"))"
  else
    local base="https://github.com/peteonrails/voxtype/releases/download/v$VOXTYPE_VERSION"
    local stem files=()
    if [[ $want_variant == cpu ]]; then
      stem="voxtype-$VOXTYPE_VERSION-linux-x86_64-onnx-avx2"
      files=("$stem")
      echo "  variant: onnx-avx2 (CPU only)"
    else
      # cuda-13 build needs a driver that reports CUDA >= 13; otherwise cuda-12.
      local cuda_major variant
      cuda_major=$(nvidia-smi | grep -o 'CUDA Version: [0-9]*' | grep -o '[0-9]*$' || echo 12)
      variant=$(( cuda_major >= 13 ? 13 : 12 ))
      stem="voxtype-$VOXTYPE_VERSION-linux-x86_64-onnx-cuda-$variant"
      files=("$stem" "$stem.libonnxruntime_providers_cuda.so" "$stem.libonnxruntime_providers_shared.so")
      [[ $variant == 13 ]] && files+=("$stem.libonnxruntime.so.1.24.4")
      echo "  variant: cuda-$variant (driver reports CUDA $cuda_major)"
    fi
    fetch "$base/SHA256SUMS.txt"     "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt"
    fetch "$base/SHA256SUMS.txt.asc" "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt.asc"
    if command -v gpg >/dev/null; then
      gpg --list-keys "$VOXTYPE_GPG_KEY" >/dev/null 2>&1 || gpg --keyserver hkps://keys.openpgp.org --recv-keys "$VOXTYPE_GPG_KEY" \
        || warn "could not fetch signing key from keys.openpgp.org"
      if gpg --verify "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt.asc" "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt" 2>/dev/null; then
        ok "SHA256SUMS.txt signature valid ($VOXTYPE_GPG_KEY)"
      else
        warn "GPG verification failed or key unavailable — falling back to sha256 only. Verify manually: gpg --verify $DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt.asc"
      fi
    fi
    local f
    for f in "${files[@]}"; do fetch "$base/$f" "$DL/$f"; done
    ( cd "$DL" && grep -E " ($(IFS='|'; echo "${files[*]}"))$" "voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt" | sha256sum --check --strict ) \
      | sed 's/^/  /' || fail "sha256 mismatch — delete $DL/voxtype-* and retry, or the release was tampered with"
    ok "sha256 verified for ${#files[@]} files"
    mkdir -p "$VOX_LIB" "$BIN"
    rm -f "$VOX_LIB"/libonnxruntime*.so*          # no stale provider libs from another variant
    install -m 0755 "$DL/$stem" "$VOX_LIB/voxtype"
    for f in "${files[@]:1}"; do install -m 0644 "$DL/$f" "$VOX_LIB/${f#"$stem".}"; done
    echo "$want_variant" > "$stamp"
    ok "installed to $VOX_LIB"
    systemctl --user try-restart voxtype 2>/dev/null || true
  fi
  # wrapper so the CUDA provider .so files (and system CUDA/cuDNN libs) are found
  cat > "$BIN/voxtype" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$VOX_LIB:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$VOX_LIB/voxtype" "\$@"
EOF
  chmod +x "$BIN/voxtype"
  command -v voxtype >/dev/null || fail "$BIN is not on PATH — add it and re-run"
  ok "$(voxtype --version 2>/dev/null | head -1)"
  if [[ $want_variant == cpu ]]; then
    ok "CPU build: no CUDA libraries needed"
  elif ldconfig -p | grep -q 'libcudnn.so.9'; then
    ok "cuDNN 9 found (CUDA execution provider can load)"
  else
    warn "libcudnn.so.9 not found — Parakeet will run on CPU until cuDNN 9 + CUDA runtime libs are installed"
    warn "  Pop!_OS: sudo apt install system76-cudnn-12.x  (or NVIDIA's libcudnn9-cuda-12); see INSTALL.md §GPU"
  fi
}

step_model() {
  step "Parakeet TDT 0.6B v3 (ONNX, data-only format)"
  mkdir -p "$MODEL_DIR"
  local f
  for f in encoder-model.onnx encoder-model.onnx.data decoder_joint-model.onnx vocab.txt config.json; do
    if [[ -s "$MODEL_DIR/$f" ]]; then ok "$f"; else
      echo "  fetching $f"; fetch "$PARAKEET_REPO/$f" "$MODEL_DIR/$f"
    fi
  done
  du -sh "$MODEL_DIR" | sed 's/^/  /'
}

step_config() {
  step "config + hooks  (mode: $HOTKEY_MODE)"
  mkdir -p "$BIN" "$DICTATE_DIR" "$VOX_CFG_DIR" "$LOG_DIR"
  chmod 700 "$DICTATE_DIR" "$LOG_DIR"
  chmod +x "$REPO/polish.py" "$REPO/dictate" "$REPO/tests/latency_report.py"
  ln -sfn "$REPO/polish.py" "$BIN/polish.py"
  ln -sfn "$REPO/dictate"   "$BIN/dictate"
  ok "symlinked polish.py and dictate into $BIN"
  local f
  for f in prompt.md corrections.json snippets.json jargon.txt settings.json; do
    if [[ -e "$DICTATE_DIR/$f" ]]; then ok "$f exists (kept)"; else cp "$REPO/config/$f" "$DICTATE_DIR/$f"; ok "$f installed"; fi
  done
  local src="$REPO/config/voxtype.config.toml"
  [[ $HOTKEY_MODE == toggle ]] && src="$REPO/config/voxtype.config.toggle.toml"
  local cfg="$VOX_CFG_DIR/config.toml"
  if [[ -e $cfg ]] && ! sed "s#/home/pitipatw#$HOME#g" "$src" | cmp -s - "$cfg"; then
    cp "$cfg" "$cfg.bak.$(date +%s)"; warn "existing config.toml backed up"
  fi
  sed "s#/home/pitipatw#$HOME#g" "$src" > "$cfg"
  chmod 600 "$cfg"
  ok "wrote $cfg"
  printf 'um so uh this is a test of the polish hook with enough words' | "$BIN/polish.py" >/dev/null && ok "polish.py runs end to end (see: dictate log tail 1)"
  [[ -f "$LOG_DIR/log.jsonl" ]] && { chmod 600 "$LOG_DIR/log.jsonl"; ok "log.jsonl is mode 600"; }
}

step_service() {
  step "voxtype daemon"
  voxtype setup || warn "voxtype setup reported issues (see above)"
  voxtype setup systemd || warn "voxtype setup systemd failed — run it manually"
  # drop-in so the daemon (started by systemd, not through the wrapper) finds the CUDA
  # provider libraries and the ydotool socket
  mkdir -p "$HOME/.config/systemd/user/voxtype.service.d"
  cat > "$HOME/.config/systemd/user/voxtype.service.d/override.conf" <<EOF
[Service]
TimeoutStopSec=10
Environment="LD_LIBRARY_PATH=$VOX_LIB:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu"
Environment="YDOTOOL_SOCKET=${YDOTOOL_SOCKET:-$XDG_RUNTIME_DIR/.ydotool_socket}"
Environment="PATH=$BIN:/usr/local/bin:/usr/bin:/bin"
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now voxtype 2>/dev/null || warn "could not enable voxtype unit"
  systemctl --user restart voxtype 2>/dev/null || true
  sleep 2
  systemctl --user is-active voxtype >/dev/null && ok "voxtype running" || warn "voxtype not active: journalctl --user -u voxtype -f"
  if [[ $HOTKEY_MODE == toggle ]]; then
    warn "toggle mode: add a COSMIC custom shortcut (Settings → Keyboard → Custom shortcuts):"
    warn "    command: $BIN/voxtype record toggle     key: your choice (e.g. Super+Space)"
  fi
}

step_summary() {
  step "next: manual checks"
  cat <<EOF
  1. $( ((NEED_RELOGIN)) && echo "LOG OUT AND BACK IN (new group membership), then re-run: ./install.sh" || echo "no re-login needed" )
  2. Paste probe:  echo hello | wl-copy; focus an editor; sleep 3 && ydotool key shift+insert
  3. LLM probe:    dictate test "send it monday actually delete that send it friday"
  4. Mic probe:    $( [[ $HOTKEY_MODE == toggle ]] && echo "press your toggle shortcut, say 'testing one two three', press again" || echo "hold the F13 key, say 'testing one two three', release" ) → text appears
  5. Mic-in-use check: run  pw-top  and confirm a voxtype capture stream exists ONLY while recording
  6. After ~20 dictations: dictate log stats
  Logs: journalctl --user -u voxtype -f   |   dictate log tail   |   dictate log purge
EOF
}

ALL=(preflight apt ydotool ollama voxtype model config service summary)
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
if (($#)); then STEPS=("$@" summary); else STEPS=("${ALL[@]}"); fi
for s in "${STEPS[@]}"; do
  declare -F "step_$s" >/dev/null || fail "unknown step: $s (see --list)"
  "step_$s"
done
