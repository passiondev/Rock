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
            if (!$manifest.ContainsKey("prNumber") -or $manifest.prNumber -le 0) {
                Write-Warning "Skipping invalid PR manifest $($manifestFile.FullName)."
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
