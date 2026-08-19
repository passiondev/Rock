# PRD: Pull Request Test Environments for Rock RMS

**Status: built and in service.** This is the design record — what was proposed and why — and
it is deliberately frozen rather than bumped as the system changes, so do not read any value
here as current. For how the pipeline behaves today, read the workflows in `.github/` (the
only definitive source), then `PR-Test-Environments-Operator-Runbook.md` and
`PR-Test-Environments-Developer-Runbook.md`; `Training/DevOps-Open-Items-Rock-CICD.md` has
what is still open. The implementation slices are under
`PR-Test-Environments-Issues/`, whose README notes which of them measurement has since
overtaken.

## Problem Statement

The development team uses MacBooks, but Rock RMS is a .NET Framework WebForms application that requires Windows-centric build and runtime tooling. Local macOS development is blocked by slow or unreliable VM-based builds. Developers need a low-cost, repeatable way to build and functionally test code changes before merging to shared branches without keeping many expensive per-developer Windows machines running.

## Solution

Create PR-driven Rock test environments hosted on the existing Google Windows server infrastructure.

Developers will continue coding on MacBooks, then open a GitHub Pull Request and use labels to request a test environment. GitHub Actions will build Rock on a Windows runner, package the deployable `RockWeb` artifact, upload it to Google Cloud Storage, and remotely invoke a PowerShell deployment script on the Google Windows server over SSH.

Each PR will get an isolated IIS site and app pool keyed by PR number, for example:

- URL: `https://pr-123.rock-dev.example.org`
- IIS site: `rock-pr-123`
- App pool: `rock-pr-123`
- Path: `C:\RockTestEnvs\pr-123\site`

All PR environments will share one sanitized, non-production sandbox Rock database and shared sandbox file storage. The sandbox DB will be refreshed from production on a daily cadence through an existing sanitization/sync process. PR environments isolate code/runtime, not data.

> **Status note, 2026-08-17: the daily cadence is not implemented, and the "existing sanitization/sync process" this requirement assumed does not exist.** Verified against GCP: `connect-restore-test` was seeded once on 2026-04-14 by a per-database `.bak` import and has had no data load since; no Cloud Scheduler job exists in the project; nothing invokes `Invoke-SandboxRefreshWithPrEnvironments.ps1`. This sentence is the origin of every "refreshed daily" claim that had propagated into the runbooks and training material, all of which have now been corrected. Left in place as the requirement it is, rather than rewritten to match reality. See open item 7 in `Documentation/Training/DevOps-Open-Items-Rock-CICD.md`.

## User Stories

1. As a developer, I want to request a Rock test environment from a PR label, so that I can test changes without running Rock locally on macOS.
2. As a developer, I want the test environment URL posted back to my PR, so that I can quickly open and verify my changes.
3. As a developer, I want each PR to have a stable subdomain based on PR number, so that the URL is predictable and repeatable.
4. As a developer, I want to redeploy the latest PR head by adding a label, so that I can test new commits on demand.
5. As a developer, I want optional auto-redeploy on push, so that fast iteration is possible when needed.
6. As a developer, I want stopped environments to restart quickly, so that stale PRs can be retested later.
7. As a reviewer, I want to access the same PR environment as the developer, so that I can verify behavior before approval.
8. As a team lead, I want environments to stop after inactivity, so that server resources remain low-cost.
9. As a team lead, I want merged PR environments destroyed automatically, so that stale IIS sites and files do not accumulate.
10. As an operator, I want closed-unmerged PRs stopped and later destroyed, so that abandoned work can be inspected briefly but cleaned up automatically.
11. As an operator, I want a single shared sandbox DB, so that we avoid 2–4 hour database copies for every PR.
12. As an operator, I want nightly DB refreshes to stop PR app pools first, so that database sync is predictable and safe.
13. As a security owner, I want PR environments restricted to office/VPN traffic, so that sanitized sandbox data is not publicly exposed.
14. As a security owner, I want only internal repository branches deployable, so that forked PR code cannot run on long-lived infrastructure.
15. As a developer, I want background jobs and external integrations disabled or sandboxed, so that multiple PR sites do not accidentally process real queues or contact real services.
16. As an operator, I want deploy state reflected in PR labels and one sticky PR comment, so that the current environment status is visible without comment spam.

## Implementation Decisions

- Use PR labels as the user-facing environment state machine.
- User-applied command labels:
  - `rock:start`: ensure the PR environment exists, is running, and is deployed from latest PR head.
  - `rock:stop`: stop the app pool/site while preserving deployed files and IIS configuration.
  - `rock:destroy`: tear down IIS site, app pool, deployed files, and environment state.
  - `rock:auto`: opt into automatic rebuild/redeploy on every push to the PR.
- Bot-managed state labels:
  - `rock:queued`
  - `rock:building`
  - `rock:deploying`
  - `rock:deployed`
  - `rock:stopped`
  - `rock:failed`
- Labels are a status surface, not the only source of truth. The server should maintain per-PR environment state in a manifest such as `env.json`.
- Use GitHub-hosted Windows runners for builds, reusing the existing working GitHub Actions build pipeline.
- Extend the existing build to publish a PR-specific deployable artifact, such as `RockWeb-pr-123-abcdef.zip`.
- Use Google Cloud Storage as the artifact handoff location.
- Deploy by SSHing from GitHub Actions into the Google Windows server and invoking versioned PowerShell scripts.
- Use one IIS site and app pool per PR.
- Use PR number as the only environment key.
- Use Cloudflare wildcard DNS in DNS-only mode.
- Install and manage a wildcard TLS certificate on IIS for the PR test subdomain.
- Restrict HTTP/HTTPS access to office/VPN egress IPs through GCP and/or Windows firewall rules.
- Functional browser testing is the v1 target; remote breakpoint debugging is out of scope.
- Use GitHub Actions concurrency per PR with cancel-in-progress enabled so the latest commit always wins.
- Support only PRs whose head branch is in the internal repository.
- Use one sanitized shared sandbox DB for normal PR environments.
- Use shared sandbox file storage matching the shared sandbox DB.
- Disable or sandbox background jobs, email, SMS, payment gateways, webhooks, and other external integrations by default.
- Stop environments after 6 hours of lifecycle inactivity.
- Destroy environments after 7 days idle or closed-unmerged.
- Destroy immediately when a PR is merged.
- Closed but unmerged PRs should stop immediately, then destroy after timeout.
- Nightly/daily sandbox DB refresh should stop all PR app pools, refresh/sync the sanitized DB, run post-refresh sanitization/configuration, then restart or leave environments according to policy.

## Testing Decisions

- The most important tests should verify external behavior of the deployment lifecycle, not implementation details.
- Workflow tests should validate that label events produce the expected state transitions.
- Deployment script tests should validate idempotency:
  - starting a new PR creates the site/app pool/files/configuration;
  - starting an existing PR updates or restarts it safely;
  - stopping preserves files/site state;
  - destroying removes all PR-specific runtime resources.
- Cleanup tests should validate lifecycle timeout rules:
  - stop after 6 hours lifecycle idle;
  - destroy after 7 days idle/closed;
  - immediate destroy on merge.
- Security tests/checks should validate:
  - fork PRs cannot deploy;
  - required secrets are unavailable to untrusted contexts;
  - PR sites are only reachable through approved office/VPN network paths.
- Integration testing can be done against a staging Windows server or a non-production IIS host before enabling the workflow for the full team.
- For v1, browser-based functional testing of deployed PR environments is sufficient; remote debugging tests are not required.

## Out of Scope

- Native macOS builds of the full Rock .NET Framework application.
- Per-developer local Windows VMs.
- One SQL Server instance or database copy per PR.
- Remote breakpoint debugging from MacBooks.
- Public access to PR environments.
- Deploying PR environments for external fork PRs.
- Full database isolation for every PR.
- Path-based hosting such as `/pr-123/`; PR environments should use subdomains.
- Replacing the existing production/staging deployment pipeline.

## Implementation Issue Drafts

Markdown issue drafts have been created in:

`Documentation/Discussion Docs/PR-Test-Environments-Issues/`

Recommended implementation order:

1. [Bootstrap server prerequisites and network access](./PR-Test-Environments-Issues/01-bootstrap-server-prerequisites.md)
2. [Add reusable PR artifact packaging](./PR-Test-Environments-Issues/02-pr-artifact-packaging.md)
3. [Create PR environment deploy script](./PR-Test-Environments-Issues/03-deploy-pr-environment-script.md)
4. [Create GitHub label-triggered deploy workflow](./PR-Test-Environments-Issues/04-label-triggered-deploy-workflow.md)
5. [Add sticky PR status comment and label reconciliation](./PR-Test-Environments-Issues/05-sticky-comment-label-reconciliation.md)
6. [Implement stop and destroy lifecycle commands](./PR-Test-Environments-Issues/06-stop-destroy-lifecycle.md)
7. [Implement auto-redeploy and latest-commit-wins concurrency](./PR-Test-Environments-Issues/07-auto-redeploy-concurrency.md)
8. [Add scheduled idle cleanup](./PR-Test-Environments-Issues/08-scheduled-idle-cleanup.md)
9. [Coordinate sandbox DB refresh with PR app pools](./PR-Test-Environments-Issues/09-sandbox-db-refresh-coordination.md)
10. [Harden PR runtime configuration and integration lockdown](./PR-Test-Environments-Issues/10-runtime-config-integration-lockdown.md)
11. [Write operator and developer runbooks](./PR-Test-Environments-Issues/11-runbooks.md)
12. [Pilot rollout on one internal PR](./PR-Test-Environments-Issues/12-pilot-rollout.md)

## Further Notes

The existing GitHub Actions workflow already performs much of the required build/package work. It builds JavaScript assets, restores NuGet packages, builds Rock projects, copies DLLs into `RockWeb\bin`, creates a `RockWeb` zip package, uploads artifacts, and uploads to Google Cloud Storage.

The current deployment approach should not be reused as-is for PR environments because it deploys to `C:\inetpub\wwwroot\`, configures a VM startup script, and restarts the entire VM. PR environments need a multi-site IIS deployment model with no whole-VM restart.

Recommended implementation modules/artifacts:

- GitHub Actions PR environment workflow.
- Reusable artifact packaging step.
- PR label/state reconciliation logic.
- Sticky PR comment updater.
- PowerShell deployment script for create/update/start.
- PowerShell stop script.
- PowerShell destroy script.
- Scheduled cleanup script.
- Sandbox DB refresh coordination script.
- Server-side environment manifest format.
- Operator runbook for DNS, certificate, firewall, SSH, IIS, and sandbox DB setup.
