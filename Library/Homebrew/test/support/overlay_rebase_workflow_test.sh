#!/bin/bash
# Static guard for artifact-backed, fresh-runner, exact-SHA overlay promotion.
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
    "permissions:\n      contents: read",
    "persist-credentials: false",
    'isolated_home="$(mktemp -d)"',
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_TEMPLATE_DIR=",
    "/usr/bin/git -c core.hooksPath=/dev/null rebase",
    "git bundle create",
    "bundle_sha256:",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "retention-days: 1",
]
required_validate = [
    "needs: prepare",
    "permissions:\n      contents: read",
    "ref: ${{ needs.prepare.outputs.before }}",
    "persist-credentials: false",
    "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
    "git bundle verify",
    "git bundle unbundle",
    "overlay_final_review_reproducer.sh",
    "bin/brew tests --no-parallel",
    "overlay_style_delta_check.py upstream/main HEAD",
    "bin/brew typecheck",
    "Attest the exact validated object after candidate execution",
]
required_promote = [
    "needs: [prepare, validate]",
    "vars.OVERLAY_AUTOPROMOTION_ENABLED == 'true'",
    "environment: overlay-promotion",
    "permissions: {}",
    "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
    "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1",
    "client-id: ${{ vars.OVERLAY_PROMOTION_APP_CLIENT_ID }}",
    "private-key: ${{ secrets.OVERLAY_PROMOTION_APP_PRIVATE_KEY }}",
    "owner: wangzheng15534-blip",
    "repositories: brew",
    "permission-contents: write",
    "permission-workflows: write",
    "OVERLAY_PROMOTION_TOKEN: ${{ steps.app-token.outputs.token }}",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_TEMPLATE_DIR=",
    "core.hooksPath /dev/null",
    "bundle verify",
    "bundle unbundle",
    "--force-with-lease=refs/heads/overlay-store:${BEFORE}",
    '${AFTER}:refs/heads/overlay-store',
]
for section, required in (
    (prepare, required_prepare),
    (validate_job, required_validate),
    (promote, required_promote),
):
    missing = [fragment for fragment in required if fragment not in section]
    if missing:
        raise SystemExit(f"overlay promotion gate is incomplete: {missing}")

if "secrets.OVERLAY_PROMOTION_TOKEN" in rebase:
    raise SystemExit("long-lived overlay promotion token remains configured")
if "OVERLAY_PROMOTION_APP_PRIVATE_KEY" in rebase[:promote_start]:
    raise SystemExit("promotion private key is exposed before the fresh promotion runner")
if "git push" in prepare or "git push" in validate_job:
    raise SystemExit("pre-promotion jobs must not update repository refs")
if "automation/overlay-rebase-candidate" in rebase:
    raise SystemExit("candidate handoff must not depend on a workflow-rewriting branch push")
if "actions/checkout" in promote:
    raise SystemExit("promotion job must not check out candidate files")
for candidate_execution in ("bin/brew", "Library/Homebrew", "GITHUB_WORKSPACE"):
    if candidate_execution in promote:
        raise SystemExit(f"promotion job executes or consumes candidate state: {candidate_execution}")
if "uses: actions/checkout@v" in rebase or "uses: actions/checkout@v" in validation:
    raise SystemExit("overlay workflows must pin actions/checkout by immutable commit SHA")
if "uses: actions/upload-artifact@v" in rebase or "uses: actions/download-artifact@v" in rebase:
    raise SystemExit("overlay workflow must pin artifact actions by immutable commit SHA")
if "uses: actions/create-github-app-token@v" in rebase:
    raise SystemExit("overlay workflow must pin the GitHub App token action by immutable commit SHA")
if "pull_request:" not in validation or "      - overlay-store" not in validation:
    raise SystemExit("overlay validation is not enabled for overlay-store pull requests")
if "    paths:" in validation or "    paths-ignore:" in validation:
    raise SystemExit("security-sensitive overlay PR validation must not be path-filtered")
if "persist-credentials: false" not in validation:
    raise SystemExit("overlay validation checkout persists credentials")
PY

printf 'overlay rebase workflow test: PASS\n'
