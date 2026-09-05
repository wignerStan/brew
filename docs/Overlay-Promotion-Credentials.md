# Overlay Promotion Credentials

The scheduled overlay rebase separates preparation, candidate execution, and promotion across three GitHub-hosted jobs.

1. **Prepare** rebases `overlay-store` without executing repository code. It runs Git with an isolated home, disabled system and global configuration, an empty template directory, disabled hooks, and a fixed system `PATH`. It writes the proposed commit to a thin Git bundle, records the exact commit, tree, upstream base, and bundle SHA-256, and uploads that bundle as a one-day workflow artifact. It has read-only repository permission and does not update any branch.
2. **Validate** starts on a fresh, read-only runner with persisted checkout credentials disabled. It verifies the bundle digest, imports the exact proposed commit, runs the recovery matrix, full RSpec suite, changed-line style validation, and Sorbet, then attests the same commit, tree, and bundle digest after candidate execution.
3. **Promote** starts on another fresh runner and is gated by the protected `overlay-promotion` environment. It never checks out or executes candidate files. It downloads the same bundle, verifies the preparation and validation attestations, imports it into an empty repository with isolated Git configuration and disabled hooks, fetches the current target and upstream refs afresh, and updates `overlay-store` with an explicit force-with-lease.

The artifact handoff is deliberate: neither preparation nor validation needs write access to repository refs, and no workflow-capable credential is exposed to a runner that executes candidate code.

## Dedicated GitHub App

Install a dedicated GitHub App only on `wangzheng15534-blip/brew`. Grant the installation these repository permissions and no broader access:

- **Contents: write**, to update `overlay-store`.
- **Workflows: write**, because the rebased commit can modify files under `.github/workflows`.

Configure the repository with:

- variable `OVERLAY_PROMOTION_APP_CLIENT_ID`, containing the App client ID;
- variable `OVERLAY_AUTOPROMOTION_ENABLED`, set to `true` only after all deployment protections below are active;
- protected-environment secret `OVERLAY_PROMOTION_APP_PRIVATE_KEY`, containing the App private key.

The promotion job uses the pinned `actions/create-github-app-token` action to mint a short-lived installation token scoped to the single `brew` repository. Do not configure a long-lived personal access token or an `OVERLAY_PROMOTION_TOKEN` repository secret.

## Deployment protections

Protect the `overlay-promotion` environment with required reviewers and restrict which branches may deploy through it. Keep automatic promotion disabled until the environment and repository ruleset have been tested.

Protect `overlay-store` with a repository ruleset that:

- requires the complete native-overlay validation check on the exact proposed SHA;
- requires ordinary changes to arrive through a pull request;
- restricts direct branch updates and force pushes;
- permits bypass only to the dedicated promotion GitHub App;
- does not grant a general administrator or maintainer bypass for unattended updates.

The workflow's exact-SHA, tree, bundle-digest, ancestry, and force-with-lease checks are defense in depth. They do not replace server-side branch protection.

Rotate the App private key immediately if it is ever exposed outside the protected promotion environment or if a preparation or validation job receives it.
