# Pilot rollout on one internal PR

**Last verified:** 2026-08-19

**Type:** HITL  
**Blocked by:** 01-bootstrap-server-prerequisites, 04-label-triggered-deploy-workflow, 06-stop-destroy-lifecycle, 10-runtime-config-integration-lockdown, 11-runbooks  
**User stories covered:** 1, 2, 3, 4, 6, 7, 13, 14, 15, 16

## What to build

Run the complete PR test environment workflow against one internal PR and verify the end-to-end developer experience before broader team rollout.

## Current configuration

The eligible PR base branch is whatever `.github/pr-test-environments.json` names as
`baseBranch`, which is the repository's default branch. At the time of writing that is
`passion-19.3.4`; it is renamed at every Rock upgrade, and
`Tests/PrTestEnvironments/test_base_branch_config.py` fails the build if this line and the
config disagree — so read the config, not this sentence, and if you find them out of step the
config is right.

## Pilot attempt — historical record, closed

> **This section is history and its details are deliberately frozen.** Every branch name,
> PR number and bucket path below is what was true *at the time*, not what is true now. Do not
> bump them at a Rock cutover: the current pin lives in the section above, and a mechanical
> find-and-replace through this section falsifies the record. That has already happened once —
> an earlier revision listed PR #3's base branch as the then-current trunk, when it was
> actually `develop-17.6.1`.

- First pilot PR: https://github.com/passiondev/Rock/pull/2 — closed, not merged
  - Branch: `pilot/pr-test-env-doc-smoke`
  - Result: closed because it targeted `develop` instead of the configured base branch.
- Second pilot PR: https://github.com/passiondev/Rock/pull/3 — closed, not merged
  - Branch: `pilot/pr-test-env-doc-smoke-v1761`, based on `develop-17.6.1`
  - Change type: documentation-only smoke change
  - Applied label: `rock:start`
  - Result *at the time*: Actions triggered from `rock:start`, built the PR head, packaged and
    uploaded a PR/SHA-specific artifact to GCS, updated the sticky comment, and then failed at
    an **SSH deployment step**, because a Google Windows VM is not reachable from
    GitHub-hosted runners on port 22.
  - Run: https://github.com/passiondev/Rock/actions/runs/25059249875

**That SSH step no longer exists.** It was replaced by the Cloud Storage command queue: the
runner writes a command object under `pr-environments/<queue>/pending/`, an agent on the VM
polls for it, runs it, and uploads a redacted log. Nothing deploys over port 22 any more, so
the blocker recorded above is not a live problem and needs no re-diagnosis. The artifact bucket
moved too — it is `gs://connect-file-storage`, and the bucket named in earlier revisions of
this document never existed under that name.

`pr-3` itself later became the worked example for a different defect entirely: one shared
database catalog across environments on different Rock minors. That story is item 7 of
`Documentation/Training/DevOps-Open-Items-Rock-CICD.md`, and the staging half of it was fixed
on 2026-08-18.

## Acceptance criteria

The pipeline has moved a long way past where the pilot left these, so the boxes below are
re-marked against what has actually been *observed* since — not against what the code is
believed to do. Anything not directly observed stays unchecked, because an unverified tick here
is worse than an empty box.

- [x] An internal PR can be labeled with `rock:start`.
- [x] GitHub Actions builds the latest PR head and uploads a PR/SHA-specific artifact to GCS.
- [x] The Google Windows server deploys the artifact into a PR-specific IIS site/app pool.
      *(Observed repeatedly on the demo environment for PR #4.)*
- [x] The sticky PR comment shows the correct URL, SHA, status, and instructions.
- [x] Rock loads successfully in a browser and can be functionally tested.
- [x] `rock:destroy` tears down the environment cleanly. *(Exercised across the whole fleet
      when it was pruned on 2026-08-19, after the teardown fixes landed. Before those fixes it
      did not, which is why this needed re-observing rather than inheriting a tick.)*
- [ ] **The PR URL is reachable over VPN and not reachable from an unapproved network.**
      **Not met.** The firewall rule `https-from-world` allows `tcp:443` from `0.0.0.0/0` to
      the network tag `prod-passion-compute`, and `connect-srv-test` carries that tag — the
      same one `connect-srv-prod` carries. There is no VPN gateway in front of it, and the
      office allowlist covers only RDP and SQL. So the second half of this criterion has never
      been true. (Staging does answer HTTP 302 on a valid certificate when tested, but that
      test was run from the office address, so the rule rather than the request is what
      settles it.) Tracked as item 24 in
      `Documentation/Training/DevOps-Open-Items-Rock-CICD.md`.
- [ ] Re-adding `rock:start` redeploys or restarts as expected. *(Believed working;
      `rock:auto` covers the `synchronize` path. Not re-observed since the teardown fixes.)*
- [ ] `rock:stop` stops the environment while preserving files/site state. *(Not re-observed.)*
- [ ] Merging a test PR destroys the environment automatically. *(Not re-observed — every
      environment so far was closed rather than merged, deliberately, so this specific path is
      the least exercised one in the lifecycle.)*
- [ ] The team reviews pilot feedback and decides whether to enable the workflow for all internal PRs.

## Blocked by

- 01-bootstrap-server-prerequisites
- 04-label-triggered-deploy-workflow
- 06-stop-destroy-lifecycle
- 10-runtime-config-integration-lockdown
- 11-runbooks
