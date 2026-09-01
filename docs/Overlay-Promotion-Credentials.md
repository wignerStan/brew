# Overlay Promotion Credentials

The scheduled overlay rebase uses three jobs with separate GitHub-hosted runners:

1. **Prepare** rebases `overlay-store` without executing repository code and publishes the exact result to `automation/overlay-rebase-candidate` using the repository-scoped `GITHUB_TOKEN`.
2. **Validate** checks out that exact SHA on a fresh, read-only runner with persisted checkout credentials disabled, then runs the recovery matrix, the full RSpec suite, changed-line style validation, and Sorbet.
3. **Promote** starts on another fresh runner, is gated by the protected `overlay-promotion` environment, never checks out or executes candidate files, fetches the exact validated commit into an empty repository with isolated Git configuration, verifies its commit and tree hashes, and updates `overlay-store` with an explicit force-with-lease.

Promotion requires an Actions secret named `OVERLAY_PROMOTION_TOKEN` in `wangzheng15534-blip/brew`. Prefer a short-lived GitHub App installation token. If a fine-grained personal access token is used, scope it only to that repository with:

- **Contents: write**, to update `overlay-store`.
- **Workflows: write**, because the rebased commit can modify files under `.github/workflows`.

Protect the `overlay-promotion` environment with required reviewers and restrict which branches may deploy through it. The promotion credential is exposed only inside the final job. Rotate it immediately if any preparation or validation job ever receives it.
