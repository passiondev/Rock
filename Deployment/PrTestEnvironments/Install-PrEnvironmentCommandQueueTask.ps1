[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy",
    [Parameter(Mandatory = $false)][string]$TaskName = "Rock PR Environment Command Queue"
)

New-Item -ItemType Directory -Path $DeployRoot -Force | Out-Null
$scriptPath = Join-Path $DeployRoot "Invoke-PrEnvironmentCommandQueue.ps1"
$argument = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -BucketName `"$BucketName`" -DeployRoot `"$DeployRoot`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Host "Installed $TaskName to run $scriptPath every minute."
