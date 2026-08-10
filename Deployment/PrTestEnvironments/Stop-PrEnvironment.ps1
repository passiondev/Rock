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
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
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
