#!/bin/bash
# Static guard for tested, exact-SHA overlay branch promotion.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

python3 - \
  "${repo}/.github/workflows/rebase-upstream-overlay.yml" \
  "${repo}/.github/workflows/overlay-validation.yml" <<'PY'
from pathlib import Path
import sys

rebase = Path(sys.argv[1]).read_text(encoding="utf-8")
validation = Path(sys.argv[2]).read_text(encoding="utf-8")

required = [
    "if: github.repository == 'wangzheng15534-blip/brew'",
    "git rebase upstream/main",
    "overlay_final_review_reproducer.sh",
    "bin/brew tests --no-parallel",
    "bin/brew style",
    "bin/brew typecheck",
    "HEAD:refs/heads/automation/overlay-rebase-candidate",
    "--force-with-lease=refs/heads/overlay-store:${BEFORE}",
    "HEAD:refs/heads/overlay-store",
]
missing = [fragment for fragment in required if fragment not in rebase]
if missing:
    raise SystemExit(f"overlay promotion gate is incomplete: {missing}")
positions = [rebase.index(fragment) for fragment in required[1:]]
if positions != sorted(positions):
    raise SystemExit("overlay promotion can occur before the exact candidate completes validation")
if "uses: actions/checkout@v" in rebase or "uses: actions/checkout@v" in validation:
    raise SystemExit("overlay workflows must pin actions/checkout by immutable commit SHA")
if "pull_request:" not in validation or "fix/overlay-review-hardening" not in validation:
    raise SystemExit("overlay validation is not enabled for both review and branch pushes")
if "github.event.pull_request.head.sha || github.sha" not in validation:
    raise SystemExit("overlay validation is not checking out the exact candidate SHA")
PY

printf 'overlay rebase workflow test: PASS\n'
