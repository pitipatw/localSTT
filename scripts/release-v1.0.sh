#!/usr/bin/env bash
# One-time release script for localSTT v1.0. Run it on pop-os from the repo root:
#
#     ./scripts/release-v1.0.sh            # do it
#     ./scripts/release-v1.0.sh --dry-run  # only print what would happen
#
# What it does, in order (each step is a separate, reversible git object):
#   1. merges `security-hardening` into `main` with a merge commit (--no-ff)
#   2. commits CHANGELOG.md and the release script as "release: v1.0"
#   3. creates the annotated tag `v1.0` on that commit
#   4. commits docs/ROADMAP.md + AGENTS.md as the first commit of the 1.x cycle
#   5. pushes main and the tag to origin
#
# Undo, if anything looks wrong before pushing:
#   git tag -d v1.0 && git reset --hard origin/main
# After pushing, the tag can be removed with `git push origin :refs/tags/v1.0`.
set -euo pipefail

TAG="v1.0"
DRY=0
[[ ${1:-} == "--dry-run" ]] && DRY=1

run() { if (( DRY )); then echo "+ $*"; else echo "+ $*"; "$@"; fi; }

cd "$(git rev-parse --show-toplevel)"

# Preconditions ---------------------------------------------------------------
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG already exists at $(git rev-parse --short "$TAG"); nothing to do" >&2
  exit 1
fi
# The only untracked/modified files allowed are the ones this release adds.
allowed='^(scripts/release-v1.0.sh|CHANGELOG.md|docs/ROADMAP.md|AGENTS.md)$'
dirty=$(git status --porcelain -uall | awk '{print $2}' | grep -Ev "$allowed" || true)
if [[ -n $dirty ]]; then
  echo "working tree has other changes; commit or stash them first:" >&2
  echo "$dirty" >&2
  exit 1
fi
for f in CHANGELOG.md docs/ROADMAP.md AGENTS.md; do
  [[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
done

echo "== tests on the tree that will be tagged"
run python3 -m pytest -q tests/

# 1. merge ---------------------------------------------------------------------
run git checkout main
run git merge --no-ff security-hardening -m "Merge security-hardening into main for $TAG"

# 2. release commit --------------------------------------------------------------
run git add CHANGELOG.md scripts/release-v1.0.sh
run git commit -m "release: $TAG

Local, offline push-to-talk dictation for Pop!_OS + COSMIC.
Verified daily driver (2026-09-02) plus the security-hardening series
(pinned digests, fail-closed installer, sandboxed Ollama, output sanitizer,
loopback-only ollama_url). 37 unit tests."

# 3. tag ---------------------------------------------------------------------------
run git tag -a "$TAG" -m "localSTT $TAG — first tagged release. See CHANGELOG.md."

# 4. roadmap for the 1.x cycle -----------------------------------------------------
run git add docs/ROADMAP.md AGENTS.md
run git commit -m "docs: improvement roadmap and agent protocol for the 1.x cycle"

# 5. push --------------------------------------------------------------------------
run git push origin main
run git push origin "$TAG"

echo
if (( DRY )); then echo "dry run complete; nothing changed"; exit 0; fi
echo "done: $TAG = $(git rev-parse --short "$TAG"); main = $(git rev-parse --short main)"
echo "the security-hardening branch is now fully merged; delete it when convenient:"
echo "  git branch -d security-hardening && git push origin --delete security-hardening"
