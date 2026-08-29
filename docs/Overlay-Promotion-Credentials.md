# Overlay Promotion Credentials

The scheduled overlay rebase validates an exact candidate commit before it changes the deployment branch. Candidate code is tested with the repository `GITHUB_TOKEN` unavailable for writes and with checkout credentials disabled.

Promotion requires an Actions secret named `OVERLAY_PROMOTION_TOKEN` in `wangzheng15534-blip/brew`. Use a fine-grained credential scoped only to that repository with:

- **Contents: write**, to update `automation/overlay-rebase-candidate` and `overlay-store`.
- **Workflows: write**, because the rebased commit can modify files under `.github/workflows`.

The credential is exposed only to the final promotion step, after the recovery matrix, full RSpec suite, RuboCop, and Sorbet have passed. The step verifies the exact tested SHA and updates `overlay-store` with an explicit force-with-lease against the previously observed tip.

Do not place this credential in checkout configuration or in any earlier test step. Rotate it immediately if a pre-promotion step ever receives it.
