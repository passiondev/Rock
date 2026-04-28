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

if (Test-Path "IIS:\Sites\$SiteName") {
    Remove-Website -Name $SiteName
}

if (Test-Path "IIS:\AppPools\$AppPoolName") {
    $poolState = (Get-WebAppPoolState -Name $AppPoolName).Value
    if ($poolState -ne "Stopped") {
        Stop-WebAppPool -Name $AppPoolName
    }
    Remove-WebAppPool -Name $AppPoolName
}

if (Test-Path $EnvironmentPath) {
    Remove-Item $EnvironmentPath -Recurse -Force
}

Write-Host "Destroyed $SiteName if it existed."
