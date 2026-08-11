# PR Test Environments: Operator Runbook

## Infrastructure

- Base branch config: `.github/pr-test-environments.json` controls which PR base branch is eligible for PR test environments. It currently targets `passion-18.4.1` for the Rock version pin. Update this value during Rock upgrades.
- Wildcard DNS: `*.rock-dev.connect.passion.team` points to the Google Windows VM. Cloudflare is configured manually in DNS-only mode.
- TLS: PR hosts use Let's Encrypt certificates installed in LocalMachine `My` and bound in IIS. `.github/workflows/pr-test-renew-certificates.yml` runs weekly and can be dispatched manually; it temporarily applies the `pr-test-acme-http` VM network tag for HTTP-01 validation, queues `renew-certificate`, then removes the tag. A Cloudflare DNS token would allow a future wildcard DNS-01 flow.
- Firewall: **as actually configured, HTTPS/443 is open to the whole internet** via the rule
  `https-from-world`, not restricted to office egress. The `159.63.145.194/32` allowlist covers
  RDP and SQL only. This document previously described the restricted design as though it were
  in force; it is not. These hosts run a sanitized sandbox database, so the exposure is bounded,
  but the gap between intent and reality is worth a decision rather than a surprise.
  A pre-created GCP firewall rule named `pr-test-acme-http` allows HTTP/80 only to VMs with the
  `pr-test-acme-http` network tag, which the renewal workflow applies only during ACME validation.
- Deployment control plane: GitHub Actions uploads artifacts/commands to GCS; the Windows VM polls the command queue. Do not expose SSH publicly for PR environment deployment.
- GCP/GCS: artifacts and commands use `PR_TEST_GCS_BUCKET`.
- GitHub secrets/vars used by workflows: `GCP_PROJECT_ID`, `GCP_SA_KEY`, `GCP_VM_NAME`, `GCP_VM_EXTERNAL_IP`, `GCP_ZONE`, `PR_TEST_GCS_BUCKET`, `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.

## Paths and naming

- PR environment root: `C:\RockTestEnvs`
- Deploy script root: `C:\RockDeploy`
- Logs: `C:\RockDeploy\logs`
- IIS site/app pool: `rock-pr-<number>`
- Environment path: `C:\RockTestEnvs\pr-<number>`
- Site path: `C:\RockTestEnvs\pr-<number>\site`
- Manifest: `env.json`
- Maintenance signal: `C:\RockTestEnvs\maintenance.json`

## Scripts

- `Deploy-PrEnvironment.ps1` creates/updates a PR environment from a GCS artifact.
- `Set-PrEnvironmentRuntimeConfiguration.ps1` writes sandbox DB/runtime config and disables outbound integrations/background jobs.
- `Stop-PrEnvironment.ps1` stops a PR site/app pool without deleting files.
- `Destroy-PrEnvironment.ps1` removes PR IIS resources and files.
- `Invoke-PrEnvironmentCleanup.ps1` stops deployed environments after 6 idle hours and destroys stale stopped environments after 7 days. Use `-WhatIf` for manual verification.
- `Invoke-SandboxRefreshWithPrEnvironments.ps1` stops PR app pools before DB refresh and restarts only previously running app pools afterward.
- `Invoke-PrEnvironmentCertificateRenewal.ps1` issues/renews Let's Encrypt certs for deployed PR environments and rebinds IIS HTTPS bindings. Run through the scheduled/manual certificate renewal workflow so the `pr-test-acme-http` network tag is present only during ACME validation.

## Sandbox DB refresh coordination

Run the refresh through `Invoke-SandboxRefreshWithPrEnvironments.ps1` on the Windows VM. Provide the existing sanitized DB refresh command via `-RefreshCommand`. Optional hooks:

- `-PostRefreshCommand` for post-refresh sanitization/configuration.
- `-SharedFileStorageCommand` for shared sandbox file storage refresh.

The script writes maintenance state to `C:\RockTestEnvs\maintenance.json` and logs to `C:\RockDeploy\logs\sandbox-refresh-*.log`.

## Manual recovery

- Stuck deploying: cancel stale GitHub Actions runs, then rerun with `rock-test:start`.
- IIS state mismatch: run `Destroy-PrEnvironment.ps1 -PrNumber <n>`, then re-add `rock-test:start`.
- Cleanup dry run: `Invoke-PrEnvironmentCleanup.ps1 -WhatIf`.
- Certificate/DNS issues: verify Cloudflare wildcard record, IIS certificate binding on `*:443:<host>`, and the weekly renewal workflow. No VPN allowlist is involved -- 443 is public via `https-from-world`.

## Troubleshooting

- Failed builds: inspect `.github/workflows/pr-test-artifact.yml` logs.
- Failed deploys: inspect `.github/workflows/pr-test-deploy.yml`, command queue results, GCS artifact path, and `C:\RockDeploy` scripts.
- Stopped environments: developers can re-add `rock-test:start`.
- Certificate warnings: expected until the certificate-selection fix reaches the VM -- every
  deploy used to rebind the self-signed placeholder over the real certificate (see open item 4).
  Measure the issuer with `openssl s_client`; a real certificate shows `O=Let's Encrypt`. If the
  fix is deployed and the issuer is still self-signed, dispatch
  `.github/workflows/pr-test-renew-certificates.yml` and confirm the log names the host.
- DNS failures: confirm `*.rock-dev.connect.passion.team` resolves to `GCP_VM_EXTERNAL_IP`. This is public DNS; no VPN is required.
