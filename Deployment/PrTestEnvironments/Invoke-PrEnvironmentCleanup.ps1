# Supports -WhatIf for manual verification without stopping or destroying environments.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs",

    [Parameter(Mandatory = $false)]
    [int]
    $StopAfterHours = 6,

    [Parameter(Mandatory = $false)]
    [int]
    $DestroyAfterDays = 7,

    [Parameter(Mandatory = $false)]
    [string]
    $GitHubToken,

    [Parameter(Mandatory = $false)]
    [string]
    $GitHubRepository = "passiondev/Rock"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StopScript = Join-Path $ScriptRoot "Stop-PrEnvironment.ps1"
$DestroyScript = Join-Path $ScriptRoot "Destroy-PrEnvironment.ps1"
$NowUtc = (Get-Date).ToUniversalTime()

# ConvertFrom-Json -AsHashtable is PowerShell 6+. These scripts run under Windows
# PowerShell 5.1, where the parameter does not exist and the call dies with "A parameter
# cannot be found that matches parameter name 'AsHashtable'" -- which is what every
# `stop` command on this VM has returned. 5.1's ConvertFrom-Json is not a drop-in on its
# own: it returns a PSCustomObject, and the callers below use ContainsKey() and add keys
# by dot assignment, neither of which a PSCustomObject supports under
# Set-StrictMode -Version Latest.
#
# Duplicated across Stop-PrEnvironment.ps1, Invoke-PrEnvironmentCleanup.ps1 and
# Invoke-SandboxRefreshWithPrEnvironments.ps1 rather than shared, deliberately: the
# bootstrap ships this directory with `gsutil cp Deployment/PrTestEnvironments/*.ps1`,
# so a .psm1 would never reach the VM -- the same class of silent non-deployment this
# function exists to fix.
#
# Shallow on purpose. Only top-level keys are read or written here, and ConvertTo-Json
# re-serializes nested PSCustomObject values correctly, so walking deeper would add
# failure modes and buy nothing.
function ConvertTo-ManifestHashtable {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Json
    )

    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $result
    }

    $parsed = $Json | ConvertFrom-Json
    if ($null -eq $parsed) {
        return $result
    }

    foreach ($property in $parsed.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

function Get-ManifestActivityUtc {
    param([Parameter(Mandatory = $true)]$Manifest)

    # The newest of these, not the first one present.
    #
    # This list used to be walked in order with the first match returned. Nothing in
    # this repository has ever written lastLifecycleAtUtc, so the first entry never
    # matched, and deployedAtUtc then shadowed stoppedAtUtc on every manifest that
    # carried both -- which is every environment that was ever deployed and then
    # stopped.
    #
    # The caller below destroys a stopped environment once this timestamp is
    # DestroyAfterDays old. Reading the deploy date in place of the stop date meant an
    # environment deployed months ago and stopped this morning reported months of
    # idleness and was destroyed on the very next pass, with no grace period at all.
    #
    # Taking the maximum can only move the timestamp later, so it can only ever delay
    # a destroy. That is the safe direction to be wrong in for something irreversible.
    $activity = [DateTime]::MinValue.ToUniversalTime()

    foreach ($propertyName in @("lastLifecycleAtUtc", "deployedAtUtc", "stoppedAtUtc", "destroyedAtUtc")) {
        if (!$Manifest.ContainsKey($propertyName) -or [string]::IsNullOrWhiteSpace($Manifest[$propertyName])) {
            continue
        }

        $candidate = ([DateTime]::Parse($Manifest[$propertyName])).ToUniversalTime()
        if ($candidate -gt $activity) {
            $activity = $candidate
        }
    }

    return $activity
}

function Update-GitHubStatusIfConfigured {
    param(
        [Parameter(Mandatory = $true)][int]$PrNumber,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        return
    }

    Write-Host "GitHubToken supplied; external PR status update hook would report PR $PrNumber as $Status. $Message"
    # Intentionally leave the full sticky-comment update to GitHub Actions where the shared
    # .github/scripts/pr-test-status.js helper runs with a repository-scoped token.
}

if (!(Test-Path $EnvironmentRoot)) {
    Write-Host "Environment root $EnvironmentRoot does not exist; nothing to clean."
    return
}

$manifestFiles = Get-ChildItem -Path $EnvironmentRoot -Recurse -Filter "env.json" -File -ErrorAction SilentlyContinue
foreach ($manifestFile in $manifestFiles) {
    try {
        $manifest = ConvertTo-ManifestHashtable -Json (Get-Content $manifestFile.FullName -Raw)
        if (!$manifest.ContainsKey("prNumber")) {
            Write-Warning "Skipping manifest without prNumber: $($manifestFile.FullName)"
            continue
        }

        if ($manifest.prNumber -le 0) {
            Write-Warning "Skipping manifest with invalid prNumber: $($manifestFile.FullName)"
            continue
        }

        $status = if ($manifest.ContainsKey("status")) { [string]$manifest.status } else { "unknown" }
        $activityUtc = Get-ManifestActivityUtc -Manifest $manifest
        $idle = $NowUtc - $activityUtc
        $prNumber = [int]$manifest.prNumber

        if (($status -eq "stopped" -or $status -eq "closed") -and $idle.TotalDays -ge $DestroyAfterDays) {
            Write-Host "Destroying PR $prNumber after $([Math]::Round($idle.TotalDays, 2)) idle days."
            if ($PSCmdlet.ShouldProcess("PR $prNumber", "Destroy idle PR environment")) {
                & $DestroyScript -PrNumber $prNumber -EnvironmentRoot $EnvironmentRoot
                Update-GitHubStatusIfConfigured -PrNumber $prNumber -Status "destroyed" -Message "Destroyed by scheduled cleanup."
            }
            continue
        }

        if ($status -eq "deployed" -and $idle.TotalHours -ge $StopAfterHours) {
            Write-Host "Stopping PR $prNumber after $([Math]::Round($idle.TotalHours, 2)) idle hours."
            if ($PSCmdlet.ShouldProcess("PR $prNumber", "Stop idle PR environment")) {
                & $StopScript -PrNumber $prNumber -EnvironmentRoot $EnvironmentRoot
                Update-GitHubStatusIfConfigured -PrNumber $prNumber -Status "stopped" -Message "Stopped by scheduled cleanup."
            }
            continue
        }

        if ($idle.TotalDays -ge $DestroyAfterDays -and $status -ne "deployed") {
            Write-Host "Destroying PR $prNumber with status $status after $([Math]::Round($idle.TotalDays, 2)) idle days."
            if ($PSCmdlet.ShouldProcess("PR $prNumber", "Destroy stale PR environment")) {
                & $DestroyScript -PrNumber $prNumber -EnvironmentRoot $EnvironmentRoot
                Update-GitHubStatusIfConfigured -PrNumber $prNumber -Status "destroyed" -Message "Destroyed by scheduled cleanup."
            }
            continue
        }

        Write-Host "Keeping PR $prNumber with status $status; idle for $([Math]::Round($idle.TotalHours, 2)) hours."
    }
    catch {
        Write-Warning "Skipping corrupt or unreadable manifest $($manifestFile.FullName): $($_.Exception.Message)"
        continue
    }
}
