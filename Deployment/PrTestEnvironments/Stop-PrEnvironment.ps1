[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [int]
    $PrNumber,

    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

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

$SiteName = "rock-pr-$PrNumber"
$AppPoolName = "rock-pr-$PrNumber"
$EnvironmentPath = Join-Path $EnvironmentRoot "pr-$PrNumber"
$ManifestPath = Join-Path $EnvironmentPath "env.json"

if (Test-Path "IIS:\AppPools\$AppPoolName") {
    $poolState = (Get-WebAppPoolState -Name $AppPoolName).Value
    if ($poolState -ne "Stopped") {
        Stop-WebAppPool -Name $AppPoolName
    }
}

if (Test-Path "IIS:\Sites\$SiteName") {
    $siteState = (Get-WebsiteState -Name $SiteName).Value
    if ($siteState -ne "Stopped") {
        Stop-Website -Name $SiteName
    }
}

if (Test-Path $EnvironmentPath) {
    $manifest = @{}
    if (Test-Path $ManifestPath) {
        $manifest = ConvertTo-ManifestHashtable -Json (Get-Content $ManifestPath -Raw)
    }

    $manifest.prNumber = $PrNumber
    $manifest.siteName = $SiteName
    $manifest.appPoolName = $AppPoolName
    $manifest.environmentPath = $EnvironmentPath
    $manifest.status = "stopped"
    $manifest.stoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8 -Force
}

Write-Host "Stopped $SiteName if it existed."
