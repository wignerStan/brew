# Overlay Promotion Credentials

The scheduled overlay rebase uses three jobs with separate GitHub-hosted runners:

1. **Prepare** checks out `overlay-store` without persisted credentials, disables Git hooks, rebases it onto `Homebrew/brew:main`, records the exact commit and tree hashes, and publishes that object to `automation/overlay-rebase-candidate` with the repository-scoped `GITHUB_TOKEN`. It does not run repository tests or other candidate code.
2. **Validate** checks out the exact proposed SHA on a fresh runner with read-only repository permissions and persisted checkout credentials disabled. It verifies the immutable candidate ref and tree hash, then runs the recovery matrix, full RSpec suite, changed-line style gate, and Sorbet.
3. **Promote** starts on another fresh runner after validation succeeds. It is gated by the `overlay-promotion` environment, never checks out or executes candidate files, uses an isolated `HOME`, `PATH`, Git configuration, and template directory, fetches the exact candidate into an empty repository, verifies the target SHA and candidate tree again, and updates `overlay-store` with an explicit force-with-lease.

Promotion requires an Actions secret named `OVERLAY_PROMOTION_TOKEN` in the protected `overlay-promotion` environment of `wangzheng15534-blip/brew`. Prefer a short-lived GitHub App installation token. If a fine-grained personal access token is used, scope it only to that repository with:

- **Contents: write**, to update `overlay-store`.
- **Workflows: write**, because a rebased commit may modify files under `.github/workflows`.

Configure required reviewers and deployment-branch restrictions on the `overlay-promotion` environment. The promotion credential must never be exposed to the preparation or validation jobs. Rotate it immediately if that boundary is violated.
