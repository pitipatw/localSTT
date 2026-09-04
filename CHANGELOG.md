# Changelog

All notable changes to localSTT. Format: one section per tag, newest first; each entry
names the commit or PR so a change can be found and reverted with `git revert <sha>`.

## Unreleased

(The scheduled improvement agent adds one line here per merged step — see `AGENTS.md`.)

- [PR #3] `2e5f14c` CI: GitHub Actions runs `pytest -q tests/`, `bash -n install.sh`, `shellcheck -S warning install.sh` and byte-compiles every Python entry point on every push and pull request; badge in README. (roadmap step 1)

## v1.0 — 2026-09-03

First tagged release. Working daily driver on Pop!_OS 24.04 + COSMIC (Wayland),
verified 2026-09-02 in COSMIC Text Editor, VS Code, Edge and the Claude desktop app.

### Pipeline
- Voxtype 1.0.1 daemon, Parakeet TDT 0.6B v3 on CPU (~0.2 s), `polish.py` post-process hook
  (snippets → dictionary → LLM cleanup via Qwen3-8B on Ollama → length guard), paste via
  `wl-copy` + ydotool 1.0.4 `shift+insert`.
- `dictate` CLI: `fix` / `unfix` / `snippet` / `jargon` / `list` / `test` / `log` / `app`.
- Asymmetric length guard (+30 % / −75 %), few-shot examples sent as chat turns.

### Security-hardening series (merged from `security-hardening`)
- `a9266e6` polish: control characters stripped on every output path; newlines off by
  default (`allow_newlines`), never in terminals; `ollama_url` restricted to loopback + http.
- `aa3496f` install: every download pinned by version **and** digest (Voxtype tarball +
  GPG `VALIDSIG` against a dedicated keyring, ydotool commit, Ollama tarball sha256, Parakeet
  files by sha256 / blob id); fail-closed by default; toggle mode default so the user is not
  put in `input`; Ollama under a sandboxed system unit bound to 127.0.0.1.
- `240baa4` docs: `SECURITY_REVIEW.md`, settings reference, COSMIC shortcut setup, two
  feature requests (`docs/feature-requests/`).

### Tests
- 37 unit tests (`pytest -q tests/`), LLM mocked.

### Known limitations
- COSMIC Terminal does not accept `shift+insert`; not supported.
- GPU inference off (Voxtype CUDA build hangs without CUDA 13 runtime).
- The hardened installer has not yet been re-run end to end on pop-os after the
  security-hardening merge (first item on the roadmap).
