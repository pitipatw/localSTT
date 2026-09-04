#!/usr/bin/env bash
# Idempotent installer for the local dictation stack on Pop!_OS COSMIC (Wayland).
# Re-run freely; every step checks before it acts and ends with a verification.
#
#   ./install.sh                            run all steps (toggle mode: hotkey via COSMIC shortcut)
#   HOTKEY_MODE=push_to_talk ./install.sh   hold-to-talk via the sandboxed hotkeyd daemon
#   ./install.sh --list                     show step names
#   ./install.sh <step>...                  run only the named steps (e.g. ./install.sh voxtype model)
#   INDICATOR=0 ./install.sh                skip the screen-edge recording indicator (on by default)
#
# Security posture (see INSTALL.md and SECURITY_REVIEW.md):
#   * Nothing is piped from the network into a shell. Every download is pinned to
#     a version AND to a digest recorded in this file; a mismatch stops the run.
#     Voxtype's SHA256SUMS.txt must carry a valid signature from VOXTYPE_GPG_KEY
#     (REQUIRE_GPG=0 to accept sha256-only, not recommended).
#   * Your user is never added to the `input` group. Hold-to-talk reads the keyboard
#     from a dedicated system user (`hotkeyd`, 80 lines, sandboxed) that only reports
#     F13 press/release on a socket; your session just needs `uinput` for pasting.
#   * The only privileged actions are apt installs, the udev rule, the `uinput` group,
#     the hotkeyd user + system unit, and installing Ollama under /usr/local with
#     its own sandboxed system user.

set -euo pipefail
trap 'printf "  \033[31m✘\033[0m unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---- pinned versions + digests ---------------------------------------------
# A version is a name we ask a server for; the digest is what proves we got the bytes
# we expected. Bump both in the same commit.
VOXTYPE_VERSION="1.0.1"
VOXTYPE_GPG_KEY="9CCF7915B750CAE8B095ED1AA3FC9F33FD209279"   # from the release notes
REQUIRE_GPG="${REQUIRE_GPG:-1}"                               # 0 = accept sha256-only with a warning

OLLAMA_VERSION="0.33.2"
OLLAMA_SHA256="9785247dea264d9072f09f6c9c0eb4b8e666892826a3d8388eba3e8fb9ed1db9"   # sha256 of ollama-linux-amd64.tar.zst for OLLAMA_VERSION. Empty = verify against the
                   # release's sha256sum.txt only (same origin as the tarball) and nag until you pin it:
                   #   sha256sum ~/.cache/localstt-downloads/ollama-$OLLAMA_VERSION.tar.zst
OLLAMA_MODEL="qwen3:8b"
# digest of the weights blob in the registry manifest for OLLAMA_MODEL (registry.ollama.ai/v2/library/qwen3/manifests/8b)
OLLAMA_MODEL_BLOB_SHA256="a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f"

YDOTOOL_VERSION="1.0.4"        # only used if the distro package lacks ydotoold
YDOTOOL_COMMIT="57ba7d0af525e82da2de0e275d169477f293b197"   # what tag v1.0.4 points at (tags can move; commits cannot)

# gtk4-layer-shell powers the recording indicator overlay. Ubuntu/Pop!_OS 24.04 ship no
# package for it, so it is built from a pinned commit into ~/.local (no sudo, no PATH change).
LAYER_SHELL_VERSION="1.1.1"
LAYER_SHELL_COMMIT="4867d7b85cdf1e829fc1fd6f1d5f04c42cc99389"   # what tag v1.1.1 points at

PARAKEET_REV="8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce"     # commit in the HF repo, not the mutable `main`
PARAKEET_REPO="https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/$PARAKEET_REV"
# LFS files: sha256 (from the repo's LFS pointers). Small text files are stored in git, not LFS,
# so they are pinned by git blob id (sha1, verified with `git hash-object`).
declare -A PARAKEET_SHA256=(
  [encoder-model.onnx]="98a74b21b4cc0017c1e7030319a4a96f4a9506e50f0708f3a516d02a77c96bb1"
  [encoder-model.onnx.data]="9a22d372c51455c34f13405da2520baefb7125bd16981397561423ed32d24f36"
  [decoder_joint-model.onnx]="e978ddf6688527182c10fde2eb4b83068421648985ef23f7a86be732be8706c1"
)
declare -A PARAKEET_GITBLOB=(
  [vocab.txt]="fc43e1c723e262df60b70e1919614417162d1fe2"
  [config.json]="02a773005666393de591dfd55230b778da1653d8"
)
# ---------------------------------------------------------------------------

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
VOX_LIB="$HOME/.local/lib/voxtype"
DICTATE_DIR="$HOME/.config/dictate"
MODE_STAMP="$DICTATE_DIR/hotkey_mode"           # remembers the mode chosen on a previous run
# Mode precedence: explicit HOTKEY_MODE > what a previous run installed > toggle.
# Neither mode touches the `input` group: push_to_talk installs the hotkeyd system service instead.
HOTKEY_MODE="${HOTKEY_MODE:-$(cat "$MODE_STAMP" 2>/dev/null || echo toggle)}"     # push_to_talk | toggle
UINPUT_GROUP=uinput                             # the one group your user needs (paste via ydotool)
HOTKEYD_LIB=/usr/local/lib/hotkeyd              # root-owned copy of hotkeyd.py: the daemon cannot edit itself
HOTKEYD_UNIT=/etc/systemd/system/hotkeyd.service
RELAY_UNIT="$HOME/.config/systemd/user/hotkey-relay.service"
ME="$(id -un)"                                  # not $USER: that is just an environment variable
INDICATOR="${INDICATOR:-1}"                     # 0 = do not install/enable the recording indicator
VOX_CFG_DIR="$HOME/.config/voxtype"
MODEL_DIR="$HOME/.local/share/voxtype/models/parakeet-tdt-0.6b-v3"
LOG_DIR="$HOME/.local/share/dictate"
DL="$HOME/.cache/localstt-downloads"
NEED_RELOGIN=0
[[ $EUID -ne 0 ]] || { echo "run install.sh as your normal user; it calls sudo where needed" >&2; exit 1; }
mkdir -p "$DL"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; exit 1; }
step()  { echo; bold "== $1"; }
fetch() { # fetch <url> <dest>  (skips if dest exists and is non-empty; https only, also after redirects)
  [[ -s "$2" ]] && return 0
  curl -fL --proto '=https' --proto-redir '=https' --progress-bar --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

case "$HOTKEY_MODE" in
  push_to_talk|toggle) ;;
  *) fail "HOTKEY_MODE must be push_to_talk or toggle" ;;
esac
if [[ -n ${I_ACCEPT_INPUT_GROUP:-} ]]; then
  warn "I_ACCEPT_INPUT_GROUP is obsolete: hold-to-talk no longer needs your user in the 'input' group (see INSTALL.md §1.2)"
fi

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
  local head; head=$(git -C "$src" rev-parse HEAD)
  [[ $head == "$YDOTOOL_COMMIT" ]] || fail "ydotool tag v$YDOTOOL_VERSION is at $head, expected $YDOTOOL_COMMIT (tag moved?) — rm -rf $src"
  echo "  source: $head (tag v$YDOTOOL_VERSION, pinned)"
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
  local pkgs=(ydotool ydotoold wl-clipboard curl jq zstd gnupg git python3 python3-pytest)   # git: hash-object for model pins
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
  if ! getent group uinput >/dev/null; then
    sudo groupadd --system uinput; ok "created group uinput"
  fi
  if id -nG "$ME" | grep -qw "$UINPUT_GROUP"; then
    ok "$ME is in group $UINPUT_GROUP"
  else
    sudo usermod -aG "$UINPUT_GROUP" "$ME"; NEED_RELOGIN=1
    warn "added $ME to group $UINPUT_GROUP — takes effect after logout/login"
  fi
  if id -nG "$ME" | grep -qw input; then
    warn "$ME is in group 'input' (every process running as you can read the keyboard). localSTT no longer needs it in any mode: sudo gpasswd -d $ME input"
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

  # A distro-level ydotool.service runs ydotoold as ROOT with its socket in /tmp: anyone who
  # can reach that socket injects keystrokes with root's uinput handle. We always run our own
  # user-owned daemon with a 0600 socket under $XDG_RUNTIME_DIR instead.
  if systemctl is-enabled ydotool >/dev/null 2>&1 || systemctl is-active ydotool >/dev/null 2>&1; then
    warn "disabling the distro's system-wide (root) ydotool.service in favour of a user-owned daemon"
    sudo systemctl disable --now ydotool || true
  fi
  {
    # Our user unit. Locate the daemon binary — packages differ on where it lives.
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
      local line
      while IFS= read -r line; do
        [[ $line == "ExecStart=/usr/bin/ydotoold"* ]] && line="ExecStart=$daemon${line#ExecStart=/usr/bin/ydotoold}"
        printf '%s\n' "$line"
      done < "$REPO/systemd/ydotool.service" > "$unit"
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
      sock="${sock//%t/"$XDG_RUNTIME_DIR"}"
    fi
    [[ -z $sock ]] && sock="$XDG_RUNTIME_DIR/.ydotool_socket"
  }
  [[ $sock == /tmp/* ]] && fail "ydotoold socket landed in /tmp ($sock) — refusing a world-writable location; check the unit"

  # The socket path is scraped from a daemon log line: quote it as data, never as shell.
  printf 'YDOTOOL_SOCKET=%s\n' "$sock" > "$HOME/.config/environment.d/ydotool.conf"
  sed -i '/^export YDOTOOL_SOCKET=/d' "$HOME/.profile" 2>/dev/null || true
  printf 'export YDOTOOL_SOCKET=%q\n' "$sock" >> "$HOME/.profile"
  export YDOTOOL_SOCKET="$sock"

  if systemctl --user is-active ydotool >/dev/null 2>&1; then
    ok "ydotoold running, socket $sock"
    if [[ -S $sock ]]; then
      ls -l "$sock" | sed 's/^/  /'
      [[ "$(stat -c '%a %U' "$sock")" == "600 $ME" ]] \
        || fail "socket $sock must be mode 600 and owned by $ME — as is, other local users could inject keystrokes"
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
  step "Ollama $OLLAMA_VERSION + $OLLAMA_MODEL  (pinned tarball, sha256-verified, sandboxed unit, no curl|sh)"
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
    if [[ -n $OLLAMA_SHA256 ]]; then
      [[ $have == "$OLLAMA_SHA256" ]] || fail "ollama tarball does not match OLLAMA_SHA256 pinned in install.sh (have $have)"
      ok "sha256 verified against the digest pinned in install.sh"
    else
      warn "sha256 matches the release's own list only. Pin it: OLLAMA_SHA256=\"$have\" in install.sh"
    fi
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
  if [[ ! -f $unit ]] || ! grep -q '^# managed by localSTT v3' "$unit"; then
    sudo tee "$unit" >/dev/null <<'EOF'
# managed by localSTT v3 (install.sh) — keeps the cleanup model resident so the first
# dictation after idle does not hit the hook's 4 s timeout.
#
# Sandbox (stage A of SECURITY_REVIEW.md M4): the API has no authentication, so limit what
# the process can touch if it is ever abused. It can read the OS, write only its model
# store, and cannot gain privileges. Stage B (DevicePolicy=closed + DeviceAllow for the
# NVIDIA nodes) is deliberately NOT applied yet: add it together with GPU support and
# verify with `ollama ps` that the model still loads on the GPU.
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
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/usr/share/ollama
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
UMask=0077

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
  command -v systemd-analyze >/dev/null && echo "  sandbox: $(systemd-analyze security ollama 2>/dev/null | tail -1 | sed 's/^→ //')"
  ollama list 2>/dev/null | grep -q "^${OLLAMA_MODEL}" || ollama pull "$OLLAMA_MODEL"
  # A registry tag is mutable. Check the weights blob the server actually loaded against the
  # digest pinned above (the FROM line of the Modelfile names the blob by its sha256).
  local blob
  blob=$(ollama show "$OLLAMA_MODEL" --modelfile 2>/dev/null | grep -oE '^FROM .*sha256[-:]([0-9a-f]{64})' | grep -oE '[0-9a-f]{64}$' | head -1 || true)
  if [[ -z $blob ]]; then
    warn "could not read the model blob digest from 'ollama show --modelfile' — verify by hand against OLLAMA_MODEL_BLOB_SHA256"
  elif [[ $blob == "$OLLAMA_MODEL_BLOB_SHA256" ]]; then
    ok "$OLLAMA_MODEL weights match the pinned digest (${blob:0:12})"
  else
    fail "$OLLAMA_MODEL weights digest is $blob, expected $OLLAMA_MODEL_BLOB_SHA256 — the tag was repointed; review before use (ollama rm $OLLAMA_MODEL to re-pull)"
  fi
  local t0 t1 resp
  t0=$(date +%s%N)
  resp=$(curl -s http://127.0.0.1:11434/api/chat -d "{\"model\":\"$OLLAMA_MODEL\",\"think\":false,\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}")
  t1=$(date +%s%N)
  echo "$resp" | jq -r '.message.content' | grep -qi ok && ok "model answers ($(( (t1-t0)/1000000 )) ms incl. first load)" || fail "unexpected reply: $resp"
}

voxtype_sig_ok() {
  # Verify SHA256SUMS.txt.asc with a throwaway keyring holding ONLY the pinned key, and require
  # that the signature was made by that fingerprint (a plain `gpg --verify` returns 0 for a good
  # signature from ANY key in ~/.gnupg). Prints nothing; the return code is the answer.
  command -v gpg >/dev/null || return 1
  local kr="$DL/voxtype-signing-key.gpg" gnupg status
  gnupg=$(mktemp -d) || return 1
  if [[ ! -s $kr ]]; then
    gpg --homedir "$gnupg" --batch --keyserver hkps://keys.openpgp.org --recv-keys "$VOXTYPE_GPG_KEY" >/dev/null 2>&1 \
      && gpg --homedir "$gnupg" --batch --export "$VOXTYPE_GPG_KEY" > "$kr" || { rm -rf "$gnupg" "$kr"; return 1; }
  fi
  status=$(gpg --homedir "$gnupg" --batch --no-default-keyring --keyring "$kr" --status-fd 1 \
             --verify "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt.asc" "$DL/voxtype-$VOXTYPE_VERSION.SHA256SUMS.txt" 2>/dev/null)
  local rc=$?
  rm -rf "$gnupg"
  ((rc == 0)) && grep -q "^\[GNUPG:\] VALIDSIG $VOXTYPE_GPG_KEY " <<<"$status"
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
    if voxtype_sig_ok; then
      ok "SHA256SUMS.txt signed by $VOXTYPE_GPG_KEY"
    elif [[ $REQUIRE_GPG == 1 ]]; then
      fail "could not verify the signature on SHA256SUMS.txt with key $VOXTYPE_GPG_KEY (gpg missing, keyserver unreachable, or bad signature). Fix that, or accept sha256-only with REQUIRE_GPG=0"
    else
      warn "REQUIRE_GPG=0: skipping signature check — sha256 list and binaries come from the same server, so this only detects corruption, not substitution"
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
  step "Parakeet TDT 0.6B v3 (ONNX, rev ${PARAKEET_REV:0:8}, every file digest-checked)"
  mkdir -p "$MODEL_DIR"
  local f have want
  # The ONNX files are parsed and executed by ONNX Runtime inside the daemon that owns the
  # microphone, so they are treated like binaries: fetched from a fixed commit and checked
  # against digests recorded in this script. A file that fails the check is deleted.
  for f in "${!PARAKEET_SHA256[@]}" "${!PARAKEET_GITBLOB[@]}"; do
    if [[ ! -s "$MODEL_DIR/$f" ]]; then
      echo "  fetching $f"; fetch "$PARAKEET_REPO/$f" "$MODEL_DIR/$f"
    fi
    if [[ -n ${PARAKEET_SHA256[$f]:-} ]]; then
      want=${PARAKEET_SHA256[$f]}; have=$(sha256sum "$MODEL_DIR/$f" | cut -d' ' -f1)
    else
      want=${PARAKEET_GITBLOB[$f]}; have=$(git hash-object "$MODEL_DIR/$f")
    fi
    if [[ $have == "$want" ]]; then
      ok "$f (${have:0:12})"
    else
      rm -f "$MODEL_DIR/$f"
      fail "$f digest mismatch (have $have, want $want) — file removed; re-run to fetch again, or update the pin if the model was intentionally changed"
    fi
  done
  du -sh "$MODEL_DIR" | sed 's/^/  /'
}

step_config() {
  step "config + hooks  (mode: $HOTKEY_MODE)"
  mkdir -p "$BIN" "$DICTATE_DIR" "$VOX_CFG_DIR" "$LOG_DIR"
  chmod 700 "$DICTATE_DIR" "$LOG_DIR"
  echo "$HOTKEY_MODE" > "$MODE_STAMP"
  chmod +x "$REPO/polish.py" "$REPO/dictate" "$REPO/indicator.py" "$REPO/tests/latency_report.py"
  chmod go-w "$REPO" "$REPO/polish.py" "$REPO/dictate" "$REPO/indicator.py" 2>/dev/null || true
  # The hook runs with your full privileges on every dictation. Install a COPY so that what
  # runs is what you reviewed at install time, not whatever `git pull` brings in later.
  # DEV_SYMLINK=1 restores the symlink for prompt/pipeline tuning sessions.
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "  repo: $(git -C "$REPO" rev-parse --short HEAD) $(git -C "$REPO" status --porcelain | grep -q . && echo '(uncommitted changes!)' || echo '(clean)')"
  fi
  if [[ ${DEV_SYMLINK:-0} == 1 ]]; then
    ln -sfn "$REPO/polish.py" "$BIN/polish.py"
    ln -sfn "$REPO/dictate"   "$BIN/dictate"
    ln -sfn "$REPO/tests/latency_report.py" "$BIN/dictate_latency_report.py"
    warn "DEV_SYMLINK=1: $BIN/polish.py is a symlink into the repo — edits there run live"
  else
    rm -f "$BIN/polish.py" "$BIN/dictate" "$BIN/dictate_latency_report.py"
    install -m 0755 "$REPO/polish.py" "$BIN/polish.py"
    install -m 0755 "$REPO/dictate"   "$BIN/dictate"
    install -m 0755 "$REPO/tests/latency_report.py" "$BIN/dictate_latency_report.py"
    ok "installed copies of polish.py and dictate into $BIN (re-run './install.sh config' after editing them)"
  fi
  local f
  for f in prompt.md corrections.json snippets.json jargon.txt settings.json; do
    if [[ -e "$DICTATE_DIR/$f" ]]; then ok "$f exists (kept)"; else cp "$REPO/config/$f" "$DICTATE_DIR/$f"; ok "$f installed"; fi
  done
  # One template for both modes: Voxtype's own evdev listener stays off; the hotkey (COSMIC
  # shortcut or hotkeyd) drives it through `voxtype record ...`.
  local src="$REPO/config/voxtype.config.toml"
  local cfg="$VOX_CFG_DIR/config.toml"
  local rendered; rendered=$(<"$src"); rendered=${rendered//\/home\/pitipatw/"$HOME"}   # quoted: bash 5.2 would expand & in an unquoted replacement
  if [[ -e $cfg ]] && ! cmp -s <(printf '%s\n' "$rendered") "$cfg"; then
    cp "$cfg" "$cfg.bak.$(date +%s)"; warn "existing config.toml backed up"
  fi
  printf '%s\n' "$rendered" > "$cfg"
  chmod 600 "$cfg"
  ok "wrote $cfg"
  printf 'um so uh this is a test of the polish hook with enough words' | "$BIN/polish.py" >/dev/null && ok "polish.py runs end to end (see: dictate log tail 1)"
  [[ -f "$LOG_DIR/log.jsonl" ]] && { chmod 600 "$LOG_DIR/log.jsonl"; ok "log.jsonl is mode 600"; }
}

build_layer_shell() {
  # Source build of wmww/gtk4-layer-shell at a pinned commit into ~/.local. Prints the
  # Environment= lines the indicator unit needs to find the library and its typelib.
  local need=() p
  for p in meson ninja-build libwayland-dev wayland-protocols libgtk-4-dev gobject-introspection libgirepository1.0-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done
  ((${#need[@]})) && sudo apt-get install -y "${need[@]}"
  local src="$DL/gtk4-layer-shell-$LAYER_SHELL_VERSION"
  if [[ ! -d $src/.git ]]; then
    git clone --depth 1 --branch "v$LAYER_SHELL_VERSION" https://github.com/wmww/gtk4-layer-shell "$src"
  fi
  local head; head=$(git -C "$src" rev-parse HEAD)
  [[ $head == "$LAYER_SHELL_COMMIT" ]] || fail "gtk4-layer-shell tag v$LAYER_SHELL_VERSION is at $head, expected $LAYER_SHELL_COMMIT (tag moved?) — rm -rf $src"
  echo "  source: $head (tag v$LAYER_SHELL_VERSION, pinned)"
  # no vapi (needs valac), no examples/tests/docs; smoke tests would need a running compositor
  meson setup "$src/build" "$src" --prefix="$HOME/.local" --libdir=lib -Dintrospection=true -Dvapi=false \
    -Dexamples=false -Ddocs=false -Dtests=false -Dsmoke-tests=false >/dev/null
  ninja -C "$src/build" >/dev/null
  ninja -C "$src/build" install >/dev/null
  [[ -e "$HOME/.local/lib/libgtk4-layer-shell.so.0" && -e "$HOME/.local/lib/girepository-1.0/Gtk4LayerShell-1.0.typelib" ]] \
    || fail "gtk4-layer-shell build did not produce the library + typelib — see $src/build"
  ok "built gtk4-layer-shell $LAYER_SHELL_VERSION → $HOME/.local/lib"
}

step_indicator() {
  step "recording indicator  (screen-edge glow while the mic is open; INDICATOR=$INDICATOR)"
  local unit="$HOME/.config/systemd/user/dictate-indicator.service"
  if [[ $INDICATOR != 1 ]]; then
    systemctl --user disable --now dictate-indicator >/dev/null 2>&1 || true
    warn "INDICATOR=0: indicator not enabled. In toggle mode nothing tells you the mic is still open."
    return 0
  fi
  local pkgs=(python3-gi python3-gi-cairo gir1.2-gtk-4.0) missing=() p
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) && sudo apt-get install -y "${missing[@]}"
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || fail "$p not installed"; done

  # gtk4-layer-shell: distro package where one exists (Ubuntu >= 25.10), else pinned source build.
  local env_lines=()
  if dpkg -s gir1.2-gtk4layershell-1.0 >/dev/null 2>&1; then
    ok "gtk4-layer-shell from the distro package"
  elif apt-cache show gir1.2-gtk4layershell-1.0 >/dev/null 2>&1; then
    sudo apt-get install -y gir1.2-gtk4layershell-1.0 && ok "gtk4-layer-shell installed from the distro package"
  else
    if [[ -e "$HOME/.local/lib/libgtk4-layer-shell.so.0" && -e "$HOME/.local/lib/girepository-1.0/Gtk4LayerShell-1.0.typelib" && ${LAYER_SHELL_FROM_SOURCE:-0} != 1 ]]; then
      ok "gtk4-layer-shell already built in $HOME/.local (LAYER_SHELL_FROM_SOURCE=1 to rebuild)"
    else
      warn "no distro package for gtk4-layer-shell — building $LAYER_SHELL_VERSION from source into $HOME/.local"
      build_layer_shell
    fi
    env_lines=("Environment=GTK4_LAYER_SHELL_LIB=$HOME/.local/lib/libgtk4-layer-shell.so.0"
               "Environment=GI_TYPELIB_PATH=$HOME/.local/lib/girepository-1.0")
  fi

  # The indicator runs as you in every session; install a reviewed COPY like polish.py.
  if [[ ${DEV_SYMLINK:-0} == 1 ]]; then
    ln -sfn "$REPO/indicator.py" "$BIN/dictate-indicator"
  else
    rm -f "$BIN/dictate-indicator"
    install -m 0755 "$REPO/indicator.py" "$BIN/dictate-indicator"
  fi
  ok "installed $BIN/dictate-indicator"

  mkdir -p "$(dirname "$unit")"
  { cat "$REPO/systemd/dictate-indicator.service"
    if ((${#env_lines[@]})); then
      printf '\n# appended by install.sh: gtk4-layer-shell built from source\n[Service]\n'
      printf '%s\n' "${env_lines[@]}"
    fi
  } > "$unit.new"
  if [[ -f $unit ]] && cmp -s "$unit" "$unit.new"; then
    rm -f "$unit.new"; ok "user unit up to date"
  else
    mv "$unit.new" "$unit"; ok "wrote $unit"
  fi
  systemctl --user daemon-reload

  local check
  if check=$(env "${env_lines[@]#Environment=}" "$BIN/dictate-indicator" --check 2>&1); then
    ok "$check"
  else
    fail "indicator self-check failed: $check"
  fi
  systemctl --user reset-failed dictate-indicator >/dev/null 2>&1 || true
  systemctl --user enable dictate-indicator >/dev/null 2>&1 || warn "could not enable dictate-indicator"
  systemctl --user restart dictate-indicator || true
  sleep 1
  if systemctl --user is-active dictate-indicator >/dev/null 2>&1; then
    ok "dictate-indicator running (glow appears only while recording; nothing drawn now is correct)"
  else
    journalctl --user -u dictate-indicator -n 8 --no-pager | sed 's/^/  /'
    fail "dictate-indicator is not running (log above). Outside a Wayland session this is expected: re-run './install.sh indicator' from the desktop"
  fi
}

render_unit() {
  # render_unit <template>: prints it with @USER@/@BIN@ filled in. Bash substitution, not sed:
  # the values are data and must never be interpreted as a pattern.
  local t; t=$(<"$1"); t=${t//@USER@/"$ME"}; t=${t//@BIN@/"$BIN"}; printf '%s\n' "$t"
}

step_hotkeyd() {
  # Hold-to-talk without putting $ME in `input` (docs/feature-requests/02-hotkey-daemon.md):
  #   /dev/input -> hotkeyd (system user, sandboxed) -> /run/hotkeyd/hotkey.sock -> hotkey-relay (you) -> voxtype record start|stop
  step "hotkeyd  (hold-to-talk without the input group; mode: $HOTKEY_MODE)"
  if [[ $HOTKEY_MODE != push_to_talk ]]; then
    # Toggle mode: make sure nothing is left reading the keyboard from a previous push_to_talk install.
    [[ -f $HOTKEYD_UNIT ]] && { sudo systemctl disable --now hotkeyd >/dev/null 2>&1 || true; ok "hotkeyd disabled"; }
    [[ -f $RELAY_UNIT ]] && { systemctl --user disable --now hotkey-relay >/dev/null 2>&1 || true; ok "hotkey-relay disabled"; }
    ok "toggle mode: no keyboard reader installed"
    return 0
  fi
  local src="$REPO/hotkeyd/hotkeyd.py" lines
  lines=$(wc -l < "$src")
  (( lines <= 80 )) || fail "hotkeyd.py is $lines lines; the audit budget is 80 — do not grow it (see the feature request)"
  if ! id hotkeyd >/dev/null 2>&1; then
    sudo useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin hotkeyd
    ok "created system user hotkeyd (group input is granted by the unit, not by membership)"
  fi
  # Root-owned copy: neither the daemon nor anything else running as hotkeyd can rewrite its own code.
  if sudo cmp -s "$src" "$HOTKEYD_LIB/hotkeyd.py"; then
    ok "$HOTKEYD_LIB/hotkeyd.py up to date ($lines lines)"
  else
    sudo install -D -o root -g root -m 0755 "$src" "$HOTKEYD_LIB/hotkeyd.py"
    ok "installed $HOTKEYD_LIB/hotkeyd.py ($lines lines, root-owned)"
  fi
  # /run/hotkeyd must be 2750 hotkeyd:$ME before the daemon binds, so the socket inherits your
  # group. This is a tmpfiles rule, not RuntimeDirectory= + ExecStartPre: systemd re-applies a
  # runtime directory's owner and mode for every Exec* invocation and undoes the ExecStartPre.
  local tmpfiles=/etc/tmpfiles.d/hotkeyd.conf rendered_tmp
  rendered_tmp=$(render_unit "$REPO/systemd/hotkeyd.tmpfiles.conf")
  if [[ -f $tmpfiles ]] && cmp -s <(printf '%s\n' "$rendered_tmp") "$tmpfiles"; then
    ok "$tmpfiles up to date"
  else
    printf '%s\n' "$rendered_tmp" | sudo tee "$tmpfiles" >/dev/null
    ok "wrote $tmpfiles"
  fi
  sudo systemd-tmpfiles --create "$tmpfiles"
  local dirperms; dirperms=$(sudo stat -c '%a %U %G' /run/hotkeyd)
  [[ $dirperms == "2750 hotkeyd $ME" ]] || fail "/run/hotkeyd is '$dirperms', expected '2750 hotkeyd $ME' — the socket cannot inherit your group; check $tmpfiles"
  ok "/run/hotkeyd is $dirperms (setgid: the socket inherits group $ME)"

  local rendered; rendered=$(render_unit "$REPO/systemd/hotkeyd.service")
  if [[ -f $HOTKEYD_UNIT ]] && cmp -s <(printf '%s\n' "$rendered") "$HOTKEYD_UNIT"; then
    ok "system unit up to date"
  else
    printf '%s\n' "$rendered" | sudo tee "$HOTKEYD_UNIT" >/dev/null
    sudo systemctl daemon-reload
    ok "wrote $HOTKEYD_UNIT"
  fi
  sudo systemctl enable hotkeyd >/dev/null 2>&1
  sudo systemctl restart hotkeyd
  sleep 1
  if ! systemctl is-active hotkeyd >/dev/null 2>&1; then
    sudo journalctl -u hotkeyd -n 10 --no-pager | sed 's/^/  /'
    fail "hotkeyd is not running (log above)"
  fi
  local sock=/run/hotkeyd/hotkey.sock perms
  [[ -S $sock ]] || fail "$sock is not a socket you can reach — $(sudo stat -c '%a %U %G' /run/hotkeyd 2>/dev/null || echo 'no /run/hotkeyd'); sudo ls -l /run/hotkeyd; sudo journalctl -u hotkeyd -n 20"
  perms=$(stat -c '%a %U %G' "$sock")
  [[ $perms == "660 hotkeyd $ME" ]] || fail "$sock is '$perms', expected '660 hotkeyd $ME' — other users could see when you dictate; check the unit's ExecStartPre"
  ok "hotkeyd running; socket $sock (660 hotkeyd:$ME)"
  command -v systemd-analyze >/dev/null && echo "  sandbox: $(systemd-analyze security hotkeyd 2>/dev/null | tail -1 | sed 's/^→ //')"

  # The relay runs as you, outside `input`, and is the only thing that turns start/stop into a recording.
  install -m 0755 "$REPO/hotkeyd/hotkey-relay" "$BIN/hotkey-relay"
  mkdir -p "$(dirname "$RELAY_UNIT")"
  render_unit "$REPO/systemd/hotkey-relay.service" > "$RELAY_UNIT"
  systemctl --user daemon-reload
  systemctl --user enable hotkey-relay >/dev/null 2>&1 || true
  systemctl --user restart hotkey-relay
  sleep 1
  if systemctl --user is-active hotkey-relay >/dev/null 2>&1; then
    ok "hotkey-relay running as $ME → $BIN/voxtype record start|stop"
  else
    journalctl --user -u hotkey-relay -n 6 --no-pager | sed 's/^/  /'
    fail "hotkey-relay is not running (log above)"
  fi
  id -nG "$ME" | grep -qw input && warn "$ME is still in group 'input'; hold-to-talk no longer needs it: sudo gpasswd -d $ME input" || true
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
    [[ $INDICATOR == 1 ]] && warn "toggle mode: the screen edges glow green while the mic is open; no glow = mic closed (or indicator down: check pw-top)"
  fi
}

step_summary() {
  step "next: manual checks"
  cat <<EOF
  1. $( ((NEED_RELOGIN)) && echo "LOG OUT AND BACK IN (new group membership), then re-run: ./install.sh" || echo "no re-login needed" )
  2. Paste probe:  echo hello | wl-copy; focus an editor; sleep 3 && ydotool key -d 60 42:1 110:1 110:0 42:0
  3. LLM probe:    dictate test "send it monday actually delete that send it friday"
  4. Mic probe:    $( [[ $HOTKEY_MODE == toggle ]] && echo "press your toggle shortcut, say 'testing one two three', press again" || echo "hold the F13 key, say 'testing one two three', release" ) → text appears
  5. Mic-in-use check: run  pw-top  and confirm a voxtype capture stream exists ONLY while recording
     — and that the screen-edge glow is shown exactly then ($( [[ $INDICATOR == 1 ]] && echo "dictate-indicator --demo 8 tests paste-through" || echo "INDICATOR=0: not installed" ))
  6. After ~20 dictations: dictate log stats
  Logs: journalctl --user -u voxtype -f   |   dictate log tail   |   dictate log purge
$( [[ $HOTKEY_MODE == push_to_talk ]] && echo "  Hold-to-talk: sudo journalctl -u hotkeyd -f   |   journalctl --user -u hotkey-relay -f   (your user is NOT in 'input')" )
  Text logging is OFF by default ("log_text": true in ~/.config/dictate/settings.json turns it on).
  Newlines are OFF by default ("allow_newlines": true keeps "new line"/"new paragraph"; never in terminals).
  Mode '$HOTKEY_MODE' is remembered in $MODE_STAMP; pass HOTKEY_MODE=... to change it.
EOF
}

ALL=(preflight apt ydotool ollama voxtype model config indicator hotkeyd service summary)
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
if (($#)); then STEPS=("$@" summary); else STEPS=("${ALL[@]}"); fi
for s in "${STEPS[@]}"; do
  declare -F "step_$s" >/dev/null || fail "unknown step: $s (see --list)"
  "step_$s"
done
