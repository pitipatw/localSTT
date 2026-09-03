
## Remediation status (2026-09-03)

Applied in the working tree (see the commit sequence in the README's install section and `git log`):

| Finding | Status | Where |
|---|---|---|
| H1 Parakeet unverified | **Fixed** — pinned to commit `8f23f0c0`; sha256 for the three LFS files, git blob ids for `vocab.txt`/`config.json`; mismatching files are deleted | `install.sh` `step_model`, `PARAKEET_*` |
| H2 `input` group default | **Fixed** — toggle is the default; push-to-talk requires `I_ACCEPT_INPUT_GROUP=1`; chosen mode remembered in `~/.config/dictate/hotkey_mode` | `install.sh` mode block, `step_config` |
| H2 follow-up: open-mic risk in toggle mode | **Mitigated** — `dictate-indicator` draws a border on every monitor while the mic is open (Voxtype state file OR a running `voxtype` PipeWire capture stream, so it cannot under-report) and nothing otherwise; amber pulse before Voxtype's `max_duration_secs` hard cap (60 s, now explicit in the config) stops the recording. Runs as the user, not in `input`, `RestrictAddressFamilies=AF_UNIX` (no network), sees state only, never text. Layer-shell overlay with keyboard interactivity none + empty input region, so it cannot take focus or the paste chord. Fail-visible: an indicator that dies draws nothing, and "no glow while dictating" is documented as "check `pw-top`". gtk4-layer-shell is built from a pinned commit (`LAYER_SHELL_COMMIT`) when the distro has no package. Verified under headless sway (two outputs: border on both, nothing mapped when idle). Residual: not yet exercised on COSMIC itself — the paste-through and multi-monitor checks in INSTALL.md Step 5a are the acceptance test. | `indicator.py`, `systemd/dictate-indicator.service`, `install.sh` `step_indicator`, tests I1–I5 |
| H3 fail-open verification | **Fixed** — `REQUIRE_GPG=1` default; ydotool commit pinned; model weights blob digest checked after pull; `OLLAMA_SHA256` slot added (**still empty — pin it**: `sha256sum ~/.cache/localstt-downloads/ollama-0.33.2.tar.zst`; the installer nags until you do) | `install.sh` pins, `step_ollama`, `build_ydotool` |
| M1 output sanitization | **Fixed** — `sanitize_output()` on every path incl. crash fallback; `allow_newlines` setting (default off, never for terminals); 3 tests | `polish.py`, `tests/test_polish.py` S1 |
| M2 `ollama_url` exfil | **Fixed** — loopback + plain-http only, no redirects; 3 tests | `polish.py` `validate_ollama_url`, S2 |
| M3 symlinked hook | **Fixed** — installed as copies; `DEV_SYMLINK=1` for development; repo made non-group/world-writable; commit + dirty state printed | `install.sh` `step_config`, `dictate` |
| M4 Ollama unit | **Stage A applied** (`ProtectSystem=strict`, `ProtectHome`, `NoNewPrivileges`, `PrivateTmp`, address families, capability set empty, …). **Stage B (`DevicePolicy=closed` + NVIDIA `DeviceAllow`) deferred** until GPU inference is enabled; the unit comment says how to verify | `install.sh` `step_ollama` unit (marker `v3`) |
| M5 `gpg --verify` any key | **Fixed** — dedicated keyring with only the pinned key; `VALIDSIG <fingerprint>` required; positive/negative tested with a throwaway key | `install.sh` `voxtype_sig_ok` |
| M6 root ydotoold | **Fixed** — distro system unit disabled; user unit always; `/tmp` socket refused; socket must be `600` and owned by you (fatal) | `install.sh` `step_ydotool` |
| L1–L5 | **Fixed** — root guard, `printf %q` for `~/.profile`, anchored `sed`, bash substitution instead of `sed s#…#`, `id -un`, `curl --proto`, `log_text` default off, literal correction values + empty-key guard (test S3) | various |

Not yet done / needs you:
- Pin `OLLAMA_SHA256` (one line) after reading the hash off the cached tarball.
- Double-check the Voxtype fingerprint `9CCF…9279` against the Voxtype release notes: it is *not* among the keys on the author's GitHub profile (checked 2026-09-03), so the release notes are the only source for it.
- Re-run `./install.sh` on pop-os; the ydotool and Ollama steps rewrite their units. Expect the Ollama step to print a `systemd-analyze security` score.
- Run the INSTALL.md Step 5a checks once on the desktop (paste-through under the glow in a GTK app, an Electron app and Alacritty; glow on every monitor; `pw-top` agrees with the border).
- Follow-ups filed as feature requests: `docs/feature-requests/01-recording-indicator.md` (implemented, pending the hardware checks above), `docs/feature-requests/02-hotkey-daemon.md`.
