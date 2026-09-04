# AGENTS.md — protocol for the scheduled improvement agent

You are running on a schedule (every 2–3 days) to advance `docs/ROADMAP.md` by exactly one
step. Nobody is watching; Pitipat reads the result later. Optimise for a change he can review in
five minutes, trust because the evidence is attached, and undo with one command.

## Ground rules

1. **One step per run.** Take the first step in the roadmap whose status is `ready` and whose
   "after N" prerequisites are `merged`. If none is available, update the roadmap statuses, write
   a short note in `docs/steps/` about what is blocking, and stop.
2. **One branch, one PR, one merge commit.** Branch `improve/NN-slug` from `origin/main`.
   Commits on the branch can be small and many; the PR is merged with `--no-ff` (or the
   GitHub "merge commit" option, never squash or rebase) so the step is one revertible unit.
3. **Never weaken a check to make it pass.** Tests are not deleted, skipped, or loosened;
   `REQUIRE_GPG`, digest pins and the loopback rule for `ollama_url` are not relaxed. If a
   pinned value must change, the PR states the source (URL, release note, `sha256sum` output).
4. **`polish.py` stays standard-library only** and keeps its invariants (always exits 0, always
   prints something, never blocks longer than `llm_timeout_s`). `dictate` likewise.
5. **Data files are the user's.** Never rewrite `~/.config/dictate/*` semantics without a
   default that keeps existing files working. `config/` in the repo holds templates only.
6. **Installer changes are idempotent and lintable.** Every `install.sh` change passes
   `bash -n` and `shellcheck`, lives inside a `step_*` function, and is listed by
   `./install.sh --list`. You cannot run the installer where you are; say so, and mark the
   step `awaiting pop-os check`.
7. **Be honest about what you verified.** "Tests pass" means you ran them and pasted the last
   line. If something could only be reasoned about, write "not verified: …" rather than
   implying it was.
8. **Small model, small diff.** Prefer a 100-line PR that does one thing over a 500-line PR
   that does three. Anything you notice beyond the step's scope goes into `docs/ROADMAP.md`
   under a new "Proposed" row, not into the PR.

## A run, start to finish

```
1. git clone / fetch; git checkout main; git pull --ff-only
2. Read docs/ROADMAP.md. Check open PRs (gh pr list):
     - a PR with label needs-pop-os and a comment "verified on pop-os" → merge it
       (merge commit), set its roadmap row to `merged <sha>`, add its CHANGELOG line
       under "Unreleased", and stop if that is enough for this run's budget.
     - a PR with CI red → fix it on its branch instead of starting a new step.
3. Pick the step. git checkout -b improve/NN-slug
4. Implement. Run: python3 -m pytest -q tests/ ; bash -n install.sh ; shellcheck install.sh
5. Write docs/steps/NN-slug.md (template below). Update the roadmap row's Status.
   Add a line under CHANGELOG.md "Unreleased" (prefixed [PR #n] once known).
6. git push -u origin improve/NN-slug ; gh pr create --fill --label <cloud|needs-pop-os>
7. Cloud-verifiable step with CI green → merge it yourself (merge commit), then update the
   roadmap row to `merged <sha>` on main. Needs-pop-os step → leave open, status
   `awaiting pop-os check`, and end your report with the exact command(s) Pitipat should run.
8. Final message: what changed, PR link, how it was verified, how to revert, what is next.
```

If pushing is impossible (no credentials), stop after step 5 and produce `git format-patch
origin/main` output as a file for Pitipat to apply. Do not retry with other methods.

## Step report template — `docs/steps/NN-slug.md`

```markdown
# Step NN — <title>

**Roadmap row:** NN · **Branch:** improve/NN-slug · **PR:** #n · **Merge commit:** <sha or pending>

## What changed
Two to five sentences. Files touched, listed.

## Why
The roadmap's reason, plus anything learned while doing it.

## How it was verified
- cloud: exact commands and their last output line
- pop-os: what Pitipat must run, and what "good" looks like (or "n/a")

## Numbers (if any)
Before / after, copied from docs/metrics.md.

## How to revert
`git revert -m 1 <merge-sha>` plus any on-machine step (e.g. `./install.sh <step>` from the
reverted tree, or a settings key to delete).

## Follow-ups noticed
Added to docs/ROADMAP.md as "Proposed" rows, or "none".
```

## Labels and statuses

| PR label | Meaning | Who merges |
|---|---|---|
| `cloud` | Fully verified by unit tests / lint / static check | The agent, once CI is green |
| `needs-pop-os` | Needs the real machine | The agent, on a later run, after Pitipat comments `verified on pop-os` |

Roadmap statuses: `ready` · `ready, after N` · `PR #n` · `awaiting pop-os check` ·
`merged <sha>` · `reverted <sha>: <reason>` · `blocked: <reason>`.

## What Pitipat does between runs

- Read the PR and `docs/steps/NN-*.md`; for `needs-pop-os` PRs run the listed command and
  reply `verified on pop-os` (or describe what broke).
- After a merge that touched the installer: `git pull && ./install.sh <step>` (the report
  names the step), then `./install.sh --check` once step 2 exists.
- Keep `docs/metrics.md` honest: paste `dictate log stats` after ~20 dictations whenever a
  latency step lands.
- To pause the agent: set the next `ready` rows to `blocked: paused` — the agent will stop.

## Scheduled-task prompt (what the agent is started with)

```
You are the localSTT improvement agent. Repository: https://github.com/pitipatw/localSTT
(clone it fresh; push with the GITHUB_TOKEN in your environment via HTTPS).
Read AGENTS.md first and follow it exactly. Then read docs/ROADMAP.md and advance it by one
step as AGENTS.md describes. Do not start a second step. End with the final message described
in AGENTS.md; it is the only thing the maintainer will read.
```
