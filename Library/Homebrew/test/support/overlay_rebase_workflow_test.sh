#!/bin/bash
# Static guard for fresh-runner, exact-SHA overlay branch promotion.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

python3 - \
  "${repo}/.github/workflows/rebase-upstream-overlay.yml" \
  "${repo}/.github/workflows/overlay-validation.yml" <<'PY'
from pathlib import Path
import sys

rebase = Path(sys.argv[1]).read_text(encoding="utf-8")
validation = Path(sys.argv[2]).read_text(encoding="utf-8")

for job in ("  prepare:\n", "  validate:\n", "  promote:\n"):
    if job not in rebase:
        raise SystemExit(f"overlay promotion workflow is missing {job.strip()}")

prepare_start = rebase.index("  prepare:\n")
validate_start = rebase.index("  validate:\n")
promote_start = rebase.index("  promote:\n")
if not prepare_start < validate_start < promote_start:
    raise SystemExit("overlay promotion jobs are not ordered prepare, validate, promote")

prepare = rebase[prepare_start:validate_start]
validate_job = rebase[validate_start:promote_start]
promote = rebase[promote_start:]

required_prepare = [
    "if: github.repository == 'wangzheng15534-blip/brew'",
    "permissions:\n      contents: write",
    "persist-credentials: false",
    "git -c core.hooksPath=/dev/null rebase upstream/main",
    "automation/overlay-rebase-candidate",
    "PREPARE_TOKEN: ${{ github.token }}",
    "--force-with-lease=\"${candidate_ref}:${candidate_before}\"",
]
required_validate = [
    "needs: prepare",
    "permissions:\n      contents: read",
    "ref: ${{ needs.prepare.outputs.after }}",
    "persist-credentials: false",
    "overlay_final_review_reproducer.sh",
    "bin/brew tests --no-parallel",
    "overlay_style_delta_check.py upstream/main HEAD",
    "bin/brew typecheck",
    "Verify the exact validated object after candidate execution",
]
required_promote = [
    "needs: [prepare, validate]",
    "environment: overlay-promotion",
    "permissions: {}",
    "OVERLAY_PROMOTION_TOKEN: ${{ secrets.OVERLAY_PROMOTION_TOKEN }}",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "core.hooksPath /dev/null",
    "refs/remotes/origin/candidate",
    "--force-with-lease=refs/heads/overlay-store:",
    "${AFTER}:refs/heads/overlay-store",
]
for section, required in (
    (prepare, required_prepare),
    (validate_job, required_validate),
    (promote, required_promote),
):
    missing = [fragment for fragment in required if fragment not in section]
    if missing:
        raise SystemExit(f"overlay promotion gate is incomplete: {missing}")

if "OVERLAY_PROMOTION_TOKEN" in rebase[:promote_start]:
    raise SystemExit("promotion credential is exposed before the fresh promotion runner")
if "actions/checkout" in promote:
    raise SystemExit("promotion job must not check out or execute candidate files")
if "uses: actions/checkout@v" in rebase or "uses: actions/checkout@v" in validation:
    raise SystemExit("overlay workflows must pin actions/checkout by immutable commit SHA")
if "pull_request:" not in validation or "      - overlay-store" not in validation:
    raise SystemExit("overlay validation is not enabled for overlay-store pull requests")
if "    paths:" in validation or "    paths-ignore:" in validation:
    raise SystemExit("security-sensitive overlay PR validation must not be path-filtered")
if "persist-credentials: false" not in validation:
    raise SystemExit("overlay validation checkout persists credentials")
PY

printf 'overlay rebase workflow test: PASS\n'
