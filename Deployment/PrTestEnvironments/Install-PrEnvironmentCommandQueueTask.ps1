[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy",
    [Parameter(Mandatory = $false)][string]$TaskName = "Rock PR Environment Command Queue"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path $DeployRoot -Force | Out-Null
$scriptPath = Join-Path $DeployRoot "Invoke-PrEnvironmentCommandQueue.ps1"
$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -BucketName `"$BucketName`" -DeployRoot `"$DeployRoot`""

# schtasks supports minute-level repetition more consistently across Windows Server images
# than Register-ScheduledTask with an unbounded repetition duration.
& schtasks.exe /Create /TN $TaskName /TR $taskCommand /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install scheduled task $TaskName. schtasks.exe exited with $LASTEXITCODE."
}

Write-Host "Installed $TaskName to run $scriptPath every minute."
