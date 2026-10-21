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

# Marks a PR environment's manifest stopped, keeping everything the deploy wrote.
#
# Merged into the existing file rather than rewritten: the deploy's fields --
# its host name and sha among them -- stay on record beside the stop. Cleanup
# then measures idleness from the newest timestamp the file carries, which is
# this stop, not the deploy. A manifest that is missing (the directory survived,
# the file did not) is started fresh rather than failing the stop.
#
# A function so ManifestContract.Tests.ps1 can run it over a manifest the real
# deploy writer produced, and hand the result to cleanup's real reader. Paths
# come in as parameters, not from this script's scope, for the same reason.
function Write-StoppedManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [int]
        $PrNumber,

        [Parameter(Mandatory = $true)]
        [string]
        $SiteName,

        [Parameter(Mandatory = $true)]
        [string]
        $AppPoolName,

        [Parameter(Mandatory = $true)]
        [string]
        $EnvironmentPath
    )

    $manifest = @{}
    if (Test-Path $Path) {
        $manifest = ConvertTo-ManifestHashtable -Json (Get-Content $Path -Raw)
    }

    $manifest.prNumber = $PrNumber
    $manifest.siteName = $SiteName
    $manifest.appPoolName = $AppPoolName
    $manifest.environmentPath = $EnvironmentPath
    $manifest.status = "stopped"
    $manifest.stoppedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8 -Force
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
    Write-StoppedManifest -Path $ManifestPath -PrNumber $PrNumber -SiteName $SiteName `
        -AppPoolName $AppPoolName -EnvironmentPath $EnvironmentPath
}

Write-Host "Stopped $SiteName if it existed."
