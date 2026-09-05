# Overlay Promotion Credentials

The scheduled overlay rebase separates preparation, candidate execution, and promotion across three GitHub-hosted jobs.

1. **Prepare** rebases `overlay-store` without executing repository code. It writes the proposed commit to a thin Git bundle, records the exact commit, tree, upstream base, and bundle SHA-256, and uploads that bundle as a one-day immutable workflow artifact. It has read-only repository permission and does not update any branch.
2. **Validate** starts on a fresh, read-only runner with persisted checkout credentials disabled. It verifies the bundle digest, imports the exact proposed commit, runs the recovery matrix, full RSpec suite, changed-line style validation, and Sorbet, then attests the same commit, tree, and bundle digest after candidate execution.
3. **Promote** starts on another fresh runner and is gated by the protected `overlay-promotion` environment. It never checks out or executes candidate files. It downloads the same bundle, verifies the prepare and validation attestations, imports it into an empty repository with isolated Git configuration and disabled hooks, fetches the current target and upstream refs afresh, and updates `overlay-store` with an explicit force-with-lease.

The artifact handoff is deliberate: the ordinary repository `GITHUB_TOKEN` cannot rewrite a branch whose history contains workflow changes unless it has workflow-update authority. Preparation therefore performs no repository write and receives no promotion credential.

Promotion requires an environment secret named `OVERLAY_PROMOTION_TOKEN` in `wangzheng15534-blip/brew`. Prefer a short-lived GitHub App installation token. If a fine-grained personal access token is used, scope it only to that repository with:

- **Contents: write**, to update `overlay-store`.
- **Workflows: write**, because the rebased commit can modify files under `.github/workflows`.

Protect the `overlay-promotion` environment with required reviewers and restrict which branches may deploy through it. The promotion credential is exposed only inside the final shell step, after artifact download, and never reaches a runner that executes candidate code. Rotate it immediately if any preparation or validation job ever receives it.
