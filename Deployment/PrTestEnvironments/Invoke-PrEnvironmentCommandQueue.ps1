[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PendingPrefix = "gs://$BucketName/pr-environments/commands/pending"
$ProcessingPrefix = "gs://$BucketName/pr-environments/commands/processing"
$ResultsPrefix = "gs://$BucketName/pr-environments/commands/results"
$LocalQueue = Join-Path $DeployRoot "queue"
New-Item -ItemType Directory -Path $LocalQueue -Force | Out-Null

$commands = (& gsutil ls "$PendingPrefix/*.json" 2>$null)
foreach ($commandUri in $commands) {
    if ([string]::IsNullOrWhiteSpace($commandUri)) { continue }
    $fileName = Split-Path $commandUri -Leaf
    $localCommand = Join-Path $LocalQueue $fileName
    $processingUri = "$ProcessingPrefix/$fileName"
    $resultUri = "$ResultsPrefix/$fileName"
    $result = $null

    try {
        & gsutil mv $commandUri $processingUri | Out-Host
        & gsutil cp $processingUri $localCommand | Out-Host
        $command = Get-Content $localCommand -Raw | ConvertFrom-Json
        $CommandId = $command.commandId
        Write-Host "Processing PR environment command $CommandId: $($command.command)"

        switch ($command.command) {
            "deploy" {
                & (Join-Path $DeployRoot "Deploy-PrEnvironment.ps1") `
                    -PrNumber $command.prNumber `
                    -Sha $command.sha `
                    -ArtifactGcsPath $command.artifactGcsPath `
                    -HostName $command.hostName `
                    -SandboxConnectionString $command.sandboxConnectionString
            }
            "stop" {
                & (Join-Path $DeployRoot "Stop-PrEnvironment.ps1") -PrNumber $command.prNumber
            }
            "destroy" {
                & (Join-Path $DeployRoot "Destroy-PrEnvironment.ps1") -PrNumber $command.prNumber
            }
            default { throw "Unknown command: $($command.command)" }
        }

        if ($LASTEXITCODE -ne 0) { throw "Command script exited with $LASTEXITCODE" }
        $result = [ordered]@{ commandId = $CommandId; prNumber = $command.prNumber; command = $command.command; status = "succeeded"; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        $result = [ordered]@{ commandId = if ($CommandId) { $CommandId } else { $fileName }; status = "failed"; error = $_.Exception.Message; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
    }
    finally {
        $localResult = Join-Path $LocalQueue $fileName
        $result | ConvertTo-Json -Depth 10 | Out-File -FilePath $localResult -Encoding UTF8 -Force
        & gsutil cp $localResult $resultUri | Out-Host
        & gsutil rm $processingUri 2>$null | Out-Host
    }
}
