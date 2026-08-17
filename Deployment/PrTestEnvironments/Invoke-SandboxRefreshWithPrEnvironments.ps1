<#
.SYNOPSIS
Coordinates a shared sandbox database/file refresh with PR test IIS app pools.

.DESCRIPTION
Runs on the Windows IIS host. The script discovers PR environments from
C:\RockTestEnvs\pr-*\env.json, writes a maintenance signal, stops all managed PR
app pools, invokes the configured refresh/sanitization commands, then restarts
only the PR environments that were running before maintenance began.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs",

    [Parameter(Mandatory = $false)]
    [string]
    $LogRoot = "C:\RockDeploy\logs",

    [Parameter(Mandatory = $true)]
    [string]
    $RefreshCommand,

    [Parameter(Mandatory = $false)]
    [string]
    $PostRefreshCommand,

    [Parameter(Mandatory = $false)]
    [string]
    $SharedFileStorageCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-ConfiguredCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Host "No $Name configured; skipping."
        return
    }

    Write-Host "Starting $Name."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
    Write-Host "Finished $Name."
}

function Write-MaintenanceState {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][string]$Message
    )

    $maintenance = [ordered]@{
        status = $Status
        message = $Message
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $maintenance | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $EnvironmentRoot "maintenance.json") -Encoding UTF8 -Force
}

function Get-PrEnvironmentManifests {
    if (!(Test-Path $EnvironmentRoot)) {
        return @()
    }

    $manifestFiles = Get-ChildItem -Path $EnvironmentRoot -Recurse -Filter "env.json" -File -ErrorAction SilentlyContinue
    $environments = @()
    foreach ($manifestFile in $manifestFiles) {
        try {
            $manifest = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json -AsHashtable

            # A manifest with no prNumber is not corrupt -- it is a non-PR
            # environment, and `staging` is one. Deploy-PrEnvironment.ps1 is the
            # only writer that emits prNumber; Deploy-RockEnvironment.ps1, which
            # deploys staging in DedicatedSite mode, writes environmentName and no
            # PR number, at C:\RockTestEnvs\staging\env.json -- inside the tree this
            # function walks. So staging has always reached this branch and been
            # logged as an invalid manifest every night, which reads as a defect and
            # buries the one line that matters.
            #
            # Skipping it is now correct rather than incidental: staging has its own
            # catalog (STAGING_DB_NAME) and is deliberately excluded from the prod
            # restore, so its app pool must NOT be stopped -- there is nothing being
            # refreshed underneath it. That is only true once the catalog exists. If
            # staging is still falling back to the shared catalog, it is being
            # restored out from under a running app pool, and the fix is to finish
            # provisioning the catalog, not to start stopping the pool here.
            if (!$manifest.ContainsKey("prNumber")) {
                $label = if ($manifest.ContainsKey("environmentName")) { $manifest.environmentName } else { $manifestFile.FullName }
                Write-Host "Leaving non-PR environment '$label' running: it does not share the catalog being refreshed."
                continue
            }

            # Reaching here means prNumber is present but unusable, which is a real
            # malformed manifest and worth a warning that says so.
            if ($manifest.prNumber -le 0) {
                Write-Warning "Skipping malformed manifest $($manifestFile.FullName): prNumber is '$($manifest.prNumber)'."
                continue
            }

            $appPoolName = if ($manifest.ContainsKey("appPoolName")) { $manifest.appPoolName } else { "rock-pr-$($manifest.prNumber)" }
            $siteName = if ($manifest.ContainsKey("siteName")) { $manifest.siteName } else { "rock-pr-$($manifest.prNumber)" }
            $environments += [pscustomobject]@{
                prNumber = [int]$manifest.prNumber
                appPoolName = [string]$appPoolName
                siteName = [string]$siteName
                manifestPath = $manifestFile.FullName
                previouslyRunning = $false
            }
        }
        catch {
            Write-Warning "Skipping corrupt manifest $($manifestFile.FullName): $($_.Exception.Message)"
        }
    }

    return $environments
}

Ensure-Directory -Path $EnvironmentRoot
Ensure-Directory -Path $LogRoot
$logPath = Join-Path $LogRoot ("sandbox-refresh-{0}.log" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss"))
$environments = @()
$refreshSucceeded = $false

Start-Transcript -Path $logPath -Append
try {
    Write-MaintenanceState -Status "starting" -Message "Sandbox refresh is starting; PR environments are being stopped."
    $environments = @(Get-PrEnvironmentManifests)

    foreach ($environment in $environments) {
        if (Test-Path "IIS:\AppPools\$($environment.appPoolName)") {
            $state = (Get-WebAppPoolState -Name $environment.appPoolName).Value
            $environment.previouslyRunning = ($state -eq "Started")
            if ($state -ne "Stopped") {
                Write-Host "Stopping PR $($environment.prNumber) app pool $($environment.appPoolName)."
                if ($PSCmdlet.ShouldProcess($environment.appPoolName, "Stop app pool before sandbox refresh")) {
                    Stop-WebAppPool -Name $environment.appPoolName
                }
            }
        }
    }

    Write-MaintenanceState -Status "running" -Message "Sandbox refresh is running; PR environments are unavailable."
    Invoke-ConfiguredCommand -Name "RefreshCommand" -Command $RefreshCommand
    Invoke-ConfiguredCommand -Name "PostRefreshCommand" -Command $PostRefreshCommand
    Invoke-ConfiguredCommand -Name "SharedFileStorageCommand" -Command $SharedFileStorageCommand
    $refreshSucceeded = $true
    Write-MaintenanceState -Status "restarting" -Message "Sandbox refresh completed; previously running PR environments are restarting."
}
catch {
    Write-MaintenanceState -Status "failed" -Message $_.Exception.Message
    Write-Error $_
}
finally {
    foreach ($environment in $environments) {
        if ($environment.previouslyRunning -and (Test-Path "IIS:\AppPools\$($environment.appPoolName)")) {
            $state = (Get-WebAppPoolState -Name $environment.appPoolName).Value
            if ($state -ne "Started") {
                Write-Host "Restarting previously running PR $($environment.prNumber) app pool $($environment.appPoolName)."
                if ($PSCmdlet.ShouldProcess($environment.appPoolName, "Restart app pool after sandbox refresh")) {
                    Start-WebAppPool -Name $environment.appPoolName
                }
            }
        }
    }

    if ($refreshSucceeded) {
        Write-MaintenanceState -Status "complete" -Message "Sandbox refresh completed successfully."
    }

    Stop-Transcript
}

if (!$refreshSucceeded) {
    exit 1
}
