# localSTT 1.x roadmap (September 2026)

Starting point: tag `v1.0` (main). Goal for the month: finish the security follow-ups and make
`polish.py` more accurate and faster — measurably, with numbers recorded before and after each
change. Work is done in small steps by a scheduled agent that runs every 2–3 days and follows
`AGENTS.md`. One step per run, one branch and one pull request per step, one merge commit per
step so that any step can be undone with a single `git revert -m 1 <merge-sha>`.

## How to read the table

- **Verify** says where the step can be checked. *cloud* = fully checkable where the agent runs
  (unit tests, shell lint, static checks). *pop-os* = only meaningful on the real machine
  (installer, Voxtype, COSMIC, the real LLM). Steps marked *pop-os* are merged only after
  Pitipat has run the listed check and replied `verified on pop-os` on the PR.
- **Status** is updated by the agent at the end of every run: `ready` → `PR #n` →
  `awaiting pop-os check` → `merged <sha>` (or `reverted <sha>` with a reason).
- Steps are ordered by dependency, not by size. A blocked step is skipped, not forced.

## Baseline (record before step 1)

Run on pop-os and paste the output into `docs/metrics.md` under "v1.0 baseline":

```bash
git describe --tags                     # v1.0
dictate log stats                       # latency + stage counts after ≥ 20 dictations
pytest -q tests/ | tail -1              # 60 passed
```

Without a baseline, "faster" and "more accurate" cannot be shown. Every later step that touches
latency or accuracy appends its own before/after block to `docs/metrics.md`.

## Steps

| # | Step | Why | Deliverable | Verify | Status |
|---|------|-----|-------------|--------|--------|
| 0 | Re-run the hardened installer on pop-os | `SECURITY_REVIEW.md` lists this as not yet done; v1.0 must actually match what is installed | `./install.sh` output pasted into `docs/metrics.md`; `systemd-analyze security ollama` score recorded | pop-os (Pitipat, no agent) | ready |
| 1 | CI: GitHub Actions | Every later step needs an automatic safety net independent of the agent's own claims | `.github/workflows/ci.yml`: `pytest -q tests/`, `bash -n install.sh`, `shellcheck install.sh`, `python -m py_compile polish.py dictate`; badge in README | cloud | merged 2e5f14c |
| 2 | Read-only health check: `./install.sh --check` | Cross-checking the security story today means reading the installer; a read-only report makes each pop-os verification a one-liner and gives every later step a before/after | `--check` prints installed versions vs pins, file digests, `id -nG` (no `input` in toggle mode), ydotool socket mode/owner, Ollama bind address + unit hardening score, hook file is a copy not a symlink; exits non-zero on any mismatch; no writes, no sudo | cloud (`bash -n`, shellcheck, a `--check` dry run against a fake `$HOME`) + pop-os (run it, paste report) | ready, after 1 |
| 3 | Sync `SECURITY_REVIEW.md` with reality; verify the Voxtype key fingerprint | The review still says `OLLAMA_SHA256` is empty (it is pinned); the fingerprint `9CCF…9279` has only one source | Corrected review; fingerprint cross-checked against Voxtype release notes / signed tags (agent has web access) with the evidence URL recorded; if it cannot be corroborated, say so and keep `REQUIRE_GPG=1` | cloud | ready |
| 4 | Golden eval set + `dictate eval` | Accuracy work without a fixed test set is guesswork. Pitipat curates raw→expected pairs from his own log (he chooses what to include; the file is his, not the agent's) | `tests/fixtures/golden.jsonl` (template + 10 seed pairs from the handoff), `dictate eval [--model M] [--prompt P]` runs the full pipeline over it, scores exact match and normalised edit distance per stage, prints a table and writes `docs/metrics.md` block; in CI the LLM is mocked so the harness itself is tested | cloud (harness) + pop-os (real numbers) | ready, after 1 |
| 5 | Per-stage timing in the log | "LLM path 55–700 ms" hides where the time goes: model load, prompt eval, generation | `polish.py` records `t_snippet/t_dict/t_llm_connect/t_llm_total` and Ollama's `prompt_eval_count`, `eval_count`, `load_duration` in each log line; `dictate log stats` breaks them down; `tests/latency_report.py` folded into `dictate` | cloud + pop-os (20 dictations, paste stats) | ready, after 4 |
| 6 | Speed round 1: keep the model hot and the prompt short | Cold loads and long prompts dominate p95; both are settings, not code | `keep_alive` sent with every request (setting, default `-1`), prompt trimmed with `dictate eval` proving no accuracy loss, `num_ctx` sized to the prompt; before/after in `docs/metrics.md` | pop-os (eval + stats) | ready, after 5 |
| 7 | Speed round 2: model A/B | `qwen3:4b` may be good enough; a smaller model halves latency | `dictate eval --model qwen3:4b` vs `qwen3:8b` on the golden set, results table; default changed only if accuracy is within 1 golden case and latency improves ≥ 30 % | pop-os | ready, after 6 |
| 8 | Accuracy round 1: prompt and demonstrations | Failures in the golden set point at specific rules the 8B model ignores; demonstrations fix those better than rules | Revised `config/prompt.md` (new `Raw:/Clean:` pairs, tightened rules), each change justified by a failing golden case; golden score before/after | pop-os (eval) | ready, after 4 |
| 9 | Accuracy round 2: faster teaching loop | Turning a bad dictation into a fix takes four commands today | `dictate fix --last` (turn the last log entry into a correction interactively), `dictate log review` (list entries where LLM changed text or a guard fired), correction values keep the user's capitalisation, snippets allow `{date}`-style placeholders — all with tests | cloud + pop-os (smoke) | ready, after 5 |
| 10 | Harden the Voxtype user unit | Ollama got `ProtectSystem=strict` etc.; the daemon that reads the mic and pastes text did not | Drop-in `~/.config/systemd/user/voxtype.service.d/hardening.conf` installed by `install.sh` (idempotent, own step, `--check` reports it); `systemd-analyze security --user voxtype` before/after; must keep PipeWire, `/dev/uinput` via ydotool socket, and the hook working | cloud (lint) + pop-os (dictate in 3 apps) | ready, after 2 |
| 11 | Ollama sandbox stage B (device policy) and GPU decision | Deferred in M4 until GPU inference; decide it explicitly | Either enable `DevicePolicy=closed` + NVIDIA `DeviceAllow` (with a working GPU path via `VOXTYPE_VARIANT=auto`) or document why CPU stays and close M4 as-is | pop-os | ready, after 10 |
| 12 | App-context helper (C9): investigation only | The read side exists; the write side depends on what COSMIC exposes | `docs/design/app-context.md`: what COSMIC (`cosmic-comp` IPC / `wlr-foreign-toplevel` / `ext-foreign-toplevel-list`) actually offers, a 30-line prototype if feasible, else a clear "not now"; no installer changes | cloud (research) + pop-os (prototype) | ready |
| 13 | Release v1.1 | Roll up | `CHANGELOG.md` section, README numbers refreshed from `docs/metrics.md`, tag `v1.1` | pop-os (Pitipat runs `scripts/release.sh v1.1`, generalised from the v1.0 script) | after all merged |

Feature requests, merged ahead of this cycle rather than deferred to a 1.2: the recording
indicator (`docs/feature-requests/01`) landed as `c054fa1` — it was already written, and toggle mode
being the default makes the open-mic risk it closes worth taking early. hotkeyd
(`docs/feature-requests/02`) follows on the same reasoning. Both were verified by observation on
pop-os, not measured: their reports live in `docs/steps/fr0*.md` and carry checks, not numbers.
The measurement tooling above is still what later accuracy and latency work depends on.

## Reversibility rules (summary; details in AGENTS.md)

- Every step is one `--no-ff` merge commit on `main`; `git revert -m 1 <sha>` undoes it fully.
- Steps never rewrite data files under `~/.config/dictate/` in place. New settings get a
  default in `DEFAULT_SETTINGS`; old `settings.json` files keep working.
- Installer changes ship as a new or existing `step_*` function and are idempotent, so an
  un-reverted install on pop-os can be repaired by re-running `./install.sh <step>` from
  the reverted tree.
- Pinned digests and fingerprints change only with a documented source in the PR.

## Cross-checking a finished step

Each merged step leaves three things that can be compared independently: the PR (diff and
CI run), `docs/steps/NN-slug.md` (what was claimed, how it was verified, how to revert), and a
`docs/metrics.md` block when numbers were involved. If the three disagree, the step is reverted
first and discussed second.
