[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy",

    # One queue per VM. The bucket is shared across environments, so if two hosts
    # polled the same pending/ prefix they would race for every command and each
    # would run roughly half of them -- a staging deploy could land on production.
    # The default keeps the existing test-VM queue exactly where it is.
    [Parameter(Mandatory = $false)][string]$QueueName = "commands"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($QueueName -notmatch '^[a-z][a-z0-9-]{1,30}$') {
    throw "QueueName must be lowercase letters, digits and hyphens, starting with a letter: '$QueueName'."
}

$PendingPrefix = "pr-environments/$QueueName/pending/"
$ProcessingPrefix = "pr-environments/$QueueName/processing/"
$ResultsPrefix = "pr-environments/$QueueName/results/"
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
    if (-not ($response.PSObject.Properties.Name -contains 'items')) { return @() }
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

# Commands run inside a background job with a per-command timeout. Without this,
# a command that hangs (for example a certificate renewal blocked on win-acme)
# never returns, so this once-per-minute task -- which Windows will not start a
# second instance of while one is running -- wedges and stops processing every
# other command. The poll loop in the queueing workflow then times out with no
# result instead of seeing a real failure. On timeout the job is killed and a
# failed result is written, keeping the queue healthy and the workflow informed.
# Defaults are kept comfortably under each workflow's own poll window so the
# workflow reports the failure rather than timing out first.
$CommandTimeoutsSeconds = @{
    'deploy'             = 1500
    'deploy-environment' = 1800
    'stop'               = 300
    'destroy'            = 300
    'renew-certificate'  = 720
}
$FallbackCommandTimeoutSeconds = 600

$CommandRunner = {
    param($DeployRoot, $Command)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    switch ($Command.command) {
        "deploy" {
            & (Join-Path $DeployRoot "Deploy-PrEnvironment.ps1") `
                -PrNumber $Command.prNumber `
                -Sha $Command.sha `
                -ArtifactGcsPath $Command.artifactGcsPath `
                -HostName $Command.hostName `
                -SandboxConnectionString $Command.sandboxConnectionString
        }
        "deploy-environment" {
            # Long-lived named environments (staging, production). Optional fields
            # are only forwarded when present so an older queued command still
            # runs, and so production can omit connectionString to keep the one
            # already on disk.
            $arguments = @{
                EnvironmentName = [string]$Command.environmentName
                Sha             = [string]$Command.sha
                ArtifactGcsPath = [string]$Command.artifactGcsPath
                HostName        = [string]$Command.hostName
            }
            foreach ($optional in @('mode', 'connectionString', 'targetSitePath', 'targetSiteName', 'targetAppPoolName', 'environmentRoot')) {
                if (($Command.PSObject.Properties.Name -contains $optional) -and ![string]::IsNullOrWhiteSpace([string]$Command.$optional)) {
                    $parameterName = $optional.Substring(0, 1).ToUpperInvariant() + $optional.Substring(1)
                    $arguments[$parameterName] = [string]$Command.$optional
                }
            }
            # InPlace deploys are a dry run unless the command explicitly opts in.
            if (($Command.PSObject.Properties.Name -contains 'apply') -and $Command.apply) {
                $arguments['Apply'] = $true
            }

            & (Join-Path $DeployRoot "Deploy-RockEnvironment.ps1") @arguments
        }
        "stop" {
            & (Join-Path $DeployRoot "Stop-PrEnvironment.ps1") -PrNumber $Command.prNumber
        }
        "destroy" {
            & (Join-Path $DeployRoot "Destroy-PrEnvironment.ps1") -PrNumber $Command.prNumber
        }
        "renew-certificate" {
            & (Join-Path $DeployRoot "Invoke-PrEnvironmentCertificateRenewal.ps1") -DeployRoot $DeployRoot
        }
        default { throw "Unknown command: $($Command.command)" }
    }

    if (-not $?) { throw "Command script reported failure." }
}

$commands = Get-GcsObjectList -Prefix $PendingPrefix | Where-Object { $_ -like '*.json' }
foreach ($commandObject in $commands) {
    $fileName = Split-Path $commandObject -Leaf
    $resultObject = "$ResultsPrefix$fileName"
    $CommandId = $fileName
    $result = $null
    $job = $null

    try {
        $commandJson = Read-GcsObjectText -ObjectName $commandObject
        $command = $commandJson | ConvertFrom-Json
        $CommandId = $command.commandId
        Write-Host "Processing PR environment command ${CommandId}: $($command.command)"

        $timeoutSeconds = $FallbackCommandTimeoutSeconds
        if ($CommandTimeoutsSeconds.ContainsKey([string]$command.command)) {
            $timeoutSeconds = $CommandTimeoutsSeconds[[string]$command.command]
        }
        if (($command.PSObject.Properties.Name -contains 'timeoutSeconds') -and $command.timeoutSeconds) {
            $timeoutSeconds = [int]$command.timeoutSeconds
        }

        $job = Start-Job -ScriptBlock $CommandRunner -ArgumentList $DeployRoot, $command
        $finished = Wait-Job -Job $job -Timeout $timeoutSeconds

        # Surface the command's output into the scheduled-task log regardless of outcome.
        Receive-Job -Job $job *>&1 | ForEach-Object { Write-Host $_ }

        if ($null -eq $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Command '$($command.command)' timed out after $timeoutSeconds seconds and was terminated."
        }
        if ($job.State -eq 'Failed') {
            $reason = "Command script reported failure."
            $failedChild = $job.ChildJobs | Where-Object { $_.JobStateInfo.Reason } | Select-Object -First 1
            if ($failedChild) { $reason = $failedChild.JobStateInfo.Reason.Message }
            throw "Command '$($command.command)' failed: $reason"
        }

        $prNumber = $null
        if ($command.PSObject.Properties.Name -contains 'prNumber') { $prNumber = $command.prNumber }
        $result = [ordered]@{ commandId = $CommandId; prNumber = $prNumber; command = $command.command; status = "succeeded"; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
    }
    catch {
        $result = [ordered]@{ commandId = $CommandId; status = "failed"; error = $_.Exception.Message; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
    }
    finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        $resultJson = $result | ConvertTo-Json -Depth 10
        Write-GcsObjectText -ObjectName $resultObject -Text $resultJson
        Remove-GcsObject -ObjectName $commandObject
    }
}
