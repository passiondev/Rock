# Bootstrap server prerequisites and network access

**Type:** HITL  
**Blocked by:** None - can start immediately  
**User stories covered:** 3, 7, 13

## What to build

Prepare the Google Windows server and surrounding infrastructure so PR environments can be hosted safely under wildcard subdomains and accessed only from the office/VPN network.

## Chosen bootstrap assumptions

- PR environment wildcard: `*.rock-dev.connect.passion.team`
- PR environment URL format: `https://pr-<number>.rock-dev.connect.passion.team`
- Cloudflare DNS: manual DNS-only `A` record to `GCP_VM_EXTERNAL_IP`
- Office/VPN egress IP allowlist: `159.63.145.194/32`
- Google Windows VM: values are supplied by existing GitHub secrets `GCP_VM_NAME`, `GCP_VM_EXTERNAL_IP`, and `GCP_ZONE`
- Deploy principal: existing GitHub secrets `WINDOWS_USERNAME` and `WINDOWS_PASSWORD`
- PR environment root: `C:\RockTestEnvs`
- Deployment script root: `C:\RockDeploy`
- Sandbox DB configuration: existing GitHub secrets `CLOUD_SQL_CONNECTION_NAME`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`

## Acceptance criteria

- [x] Cloudflare has a DNS-only wildcard record for the PR test subdomain: `*.rock-dev.connect.passion.team`.
- [ ] IIS has a wildcard TLS certificate installed for `*.rock-dev.connect.passion.team`.
- [x] HTTP/HTTPS access to the server is restricted to office/VPN egress IPs: `159.63.145.194/32`.
- [ ] SSH access for deployment is available to a dedicated deploy user.
- [ ] The deploy user has enough rights to manage the PR environment root, IIS sites, IIS app pools, and bindings.
- [ ] A root directory exists for PR environments: `C:\RockTestEnvs`.
- [ ] A root directory exists for deployment scripts: `C:\RockDeploy`.
- [x] The shared sanitized sandbox DB connection details are known and stored as deployment secrets/configuration.
- [ ] A manual smoke test can reach a placeholder IIS site through VPN at a wildcard PR URL.

## Manual follow-up before pilot

- Confirm or install an IIS wildcard TLS certificate for `*.rock-dev.connect.passion.team` and record its thumbprint as a deployment secret when available.
- Apply office/VPN egress IP allowlist `159.63.145.194/32` through GCP firewall rules and/or Windows Firewall.
- Confirm OpenSSH is enabled on the Windows VM and that the deploy principal can create/update IIS sites, app pools, bindings, and files under `C:\RockTestEnvs` and `C:\RockDeploy`.

## Blocked by

None - can start immediately
