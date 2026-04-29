[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PendingPrefix = "pr-environments/commands/pending/"
$ProcessingPrefix = "pr-environments/commands/processing/"
$ResultsPrefix = "pr-environments/commands/results/"
$LocalQueue = Join-Path $DeployRoot "queue"
New-Item -ItemType Directory -Path $LocalQueue -Force | Out-Null

function Get-GcsAccessToken {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    $tokenResponse = Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    return $tokenResponse.access_token
}

function Invoke-GcsRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)][string]$Method = 'GET',
        [Parameter(Mandatory = $false)]$Body,
        [Parameter(Mandatory = $false)][string]$ContentType = 'application/json'
    )

    $headers = @{ Authorization = "Bearer $(Get-GcsAccessToken)" }
    if ($null -ne $Body) {
        return Invoke-RestMethod -Headers $headers -Method $Method -Uri $Uri -Body $Body -ContentType $ContentType
    }
    return Invoke-RestMethod -Headers $headers -Method $Method -Uri $Uri
}

function Get-GcsObjectList {
    param([Parameter(Mandatory = $true)][string]$Prefix)
    $encodedPrefix = [System.Uri]::EscapeDataString($Prefix)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o?prefix=$encodedPrefix"
    $response = Invoke-GcsRequest -Uri $uri
    if ($null -eq $response.items) { return @() }
    return @($response.items | ForEach-Object { $_.name })
}

function Read-GcsObjectText {
    param([Parameter(Mandatory = $true)][string]$ObjectName)
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$encodedObjectName`?alt=media"
    $headers = @{ Authorization = "Bearer $(Get-GcsAccessToken)" }
    return (Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $uri).Content
}

function Write-GcsObjectText {
    param(
        [Parameter(Mandatory = $true)][string]$ObjectName,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/upload/storage/v1/b/$BucketName/o?uploadType=media&name=$encodedObjectName"
    Invoke-GcsRequest -Uri $uri -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType 'application/json' | Out-Null
}

function Remove-GcsObject {
    param([Parameter(Mandatory = $true)][string]$ObjectName)
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$encodedObjectName"
    try { Invoke-GcsRequest -Uri $uri -Method DELETE | Out-Null } catch { Write-Warning $_.Exception.Message }
}

$commands = Get-GcsObjectList -Prefix $PendingPrefix | Where-Object { $_ -like '*.json' }
foreach ($commandObject in $commands) {
    $fileName = Split-Path $commandObject -Leaf
    $resultObject = "$ResultsPrefix$fileName"
    $CommandId = $fileName
    $result = $null

    try {
        $commandJson = Read-GcsObjectText -ObjectName $commandObject
        $command = $commandJson | ConvertFrom-Json
        $CommandId = $command.commandId
        Write-Host "Processing PR environment command ${CommandId}: $($command.command)"

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
        $result = [ordered]@{ commandId = $CommandId; status = "failed"; error = $_.Exception.Message; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
    }
    finally {
        $resultJson = $result | ConvertTo-Json -Depth 10
        Write-GcsObjectText -ObjectName $resultObject -Text $resultJson
        Remove-GcsObject -ObjectName $commandObject
    }
}
