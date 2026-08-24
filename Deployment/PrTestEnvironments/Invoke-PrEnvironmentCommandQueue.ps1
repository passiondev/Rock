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
$BootstrapPrefix = "pr-environments/bootstrap/latest/"
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
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $false)][string]$ContentType = 'application/json'
    )
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/upload/storage/v1/b/$BucketName/o?uploadType=media&name=$encodedObjectName"
    Invoke-GcsRequest -Uri $uri -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType | Out-Null
}

# The command scripts write a lot of useful detail to their own output, but it
# used to land only in this scheduled task's log on the VM -- so a failed deploy
# reached GitHub as a single terse sentence and the only way to find out what
# actually happened was to RDP in. Uploading the output next to the result lets
# the queueing workflow print it, which is the difference between "did not become
# healthy" and knowing which step failed and why.
$LogsPrefix = "pr-environments/$QueueName/logs/"

# This output is about to be printed in a PUBLIC repository's Actions log, and a
# deploy command carries a database password. Redact by exact value first, using
# the secrets from the command itself, then sweep for any password= that survived
# in case a script assembled a connection string differently.
function Get-RedactedText {
    param(
        [Parameter(Mandatory = $false)][string]$Text,
        [Parameter(Mandatory = $false)][string[]]$Secrets = @()
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $redacted = $Text
    foreach ($secret in $Secrets) {
        # Short values are skipped: redacting a 3-character string would riddle
        # the log with <redacted> and hide the very detail we came for.
        if (![string]::IsNullOrWhiteSpace($secret) -and $secret.Length -ge 8) {
            $redacted = $redacted.Replace($secret, '<redacted>')
        }
    }
    $redacted = [regex]::Replace($redacted, '(?i)(password\s*=\s*)([^;"''\r\n]+)', '${1}<redacted>')
    return $redacted
}

function Get-CommandSecrets {
    param([Parameter(Mandatory = $true)]$Command)

    $secrets = @()
    foreach ($property in @('connectionString', 'sandboxConnectionString')) {
        if ($Command.PSObject.Properties.Name -contains $property) {
            $value = [string]$Command.$property
            if (![string]::IsNullOrWhiteSpace($value)) {
                $secrets += $value
                # Also redact the password on its own: the full string may be
                # line-wrapped or partially quoted in the output.
                $match = [regex]::Match($value, '(?i)password\s*=\s*([^;]+)')
                if ($match.Success) { $secrets += $match.Groups[1].Value.Trim() }
            }
        }
    }
    return $secrets
}

function Remove-GcsObject {
    param([Parameter(Mandatory = $true)][string]$ObjectName)
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$encodedObjectName"
    try { Invoke-GcsRequest -Uri $uri -Method DELETE | Out-Null } catch { Write-Warning $_.Exception.Message }
}

function Sync-DeploymentScripts {
    # The agent runs whatever copy of Deployment/PrTestEnvironments was on disk when the
    # VM was last bootstrapped, and until now nothing refreshed it. A fix merged to the
    # repository therefore sat deployed-looking and inert until somebody re-ran the
    # bootstrap by hand -- which is how three separate teardown bugs stayed live on this
    # VM after they were fixed in the repository. Nothing about the repo state showed it.
    #
    # The bootstrap and certificate-renewal workflows both already publish this directory
    # to bootstrap/latest/, so the upload half exists; this is only the pull half.
    # Commands are dispatched as `& (Join-Path $DeployRoot "X.ps1")` and resolved at call
    # time, so refreshing before the queue is drained means a fix applies to the very
    # command that is about to run.
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $objects = Get-GcsObjectList -Prefix $Prefix | Where-Object { $_ -like '*.ps1' }
    foreach ($object in $objects) {
        $name = Split-Path $object -Leaf

        # Isolated per file, and that matters more than it looks. This script is itself in
        # the list, and Windows may hold its file while it is executing -- so replacing it
        # can fail. Without this try/catch that failure would abort the whole sync, and
        # because the names are processed in listing order, Invoke-PrEnvironmentCommandQueue
        # sorts *before* Stop-PrEnvironment: the one file guaranteed to be skipped would be
        # one of the files most likely to need fixing.
        try {
            $text = Read-GcsObjectText -ObjectName $object

            # Parse before replacing anything. The agent is overwriting the scripts it runs,
            # so writing a file that does not parse would fail every subsequent command with
            # no way back -- the next sync would fetch the same broken file again. The
            # bootstrap workflow parses these before uploading; this is the same check on the
            # receiving end, where the consequence of being wrong is unattended.
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors) | Out-Null
            if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
                Write-Warning "Skipped $name from ${Prefix}: it does not parse ($($parseErrors[0].Message)). Keeping the copy already on disk."
                continue
            }

            $localPath = Join-Path $Destination $name
            if (Test-Path $localPath) {
                if ((Get-Content $localPath -Raw) -eq $text) { continue }
            }

            # Staged and moved rather than written in place: a write interrupted partway
            # leaves a truncated script, which is the same brick the parse check exists to
            # avoid.
            $stagingPath = "$localPath.sync"
            [System.IO.File]::WriteAllText($stagingPath, $text, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $stagingPath -Destination $localPath -Force
            Write-Host "Refreshed $name from $Prefix."
        }
        catch {
            Write-Warning "Could not refresh ${name}: $($_.Exception.Message). Keeping the copy already on disk."
        }
    }
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
    # Metadata-only by default and quick, but -MeasureSizes full-scans every table
    # that has a legacy column, and the catalog this is aimed at is 115 GB. The
    # fallback of 600s would kill a real scan part-way and report it as a failure,
    # which on a read-only diagnostic is the worst kind of wrong answer: it looks
    # like the catalog is unreadable rather than merely large.
    'find-legacy-text-columns' = 1800
    # Batched UPDATEs over every Person and PhoneNumber row in a prod-derived
    # catalog. The dry run is five COUNT(*)s and returns in seconds; -Apply rewrites
    # millions of rows and is the case this number has to cover. Killing it part-way
    # is survivable -- every batch commits on its own and the predicates skip rows
    # already done, so a rerun resumes -- but a half-anonymized catalog reported as a
    # failure invites someone to conclude the run did nothing and leave real
    # addresses in place.
    'anonymize-staging' = 3600
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
        "find-legacy-text-columns" {
            # Read-only, and deliberately the only Deployment/Database script this
            # agent can reach. Convert-LegacyTextColumns.ps1 is -Apply-gated and
            # rewrites column types; it stays a by-hand script with a human reading
            # the finder's output first, so there is no branch for it here.
            #
            # This exists because the finder had nowhere to run. The catalog is behind
            # a PSC endpoint with no public IP, and Cloud SQL refuses any login but the
            # owning `sqlserver` account into the database it owns -- so neither a
            # runner nor a workstation nor a hand-made diagnostic login can open it.
            # The VM already holds a working connection string on every deploy. Rather
            # than issue a second credential, the finder runs where that one already is.
            if (-not ($Command.PSObject.Properties.Name -contains 'connectionString')) {
                throw "find-legacy-text-columns requires a connectionString."
            }
            $arguments = @{ ConnectionString = [string]$Command.connectionString }
            if (($Command.PSObject.Properties.Name -contains 'measureSizes') -and $Command.measureSizes) {
                $arguments['MeasureSizes'] = $true
            }

            & (Join-Path $DeployRoot "Find-LegacyTextColumns.ps1") @arguments
        }
        "anonymize-staging" {
            # Replaces real email addresses and phone numbers in a prod-derived
            # staging catalog with undeliverable substitutes. Here for the same
            # reason the finder is: the catalog is reachable from this VM and from
            # nowhere else.
            #
            # Unlike the finder this one writes, so the arm carries its own gates
            # rather than trusting the caller to have set them. The script refuses
            # the production instance by address and refuses a catalog that does not
            # match expectedCatalog, and it is a dry run without apply. Those checks
            # live in the script because that is where they are enforced; they are
            # restated here because this arm is what a queued JSON document can
            # reach, and a command is easier to hand-write than a script is to edit.
            if (-not ($Command.PSObject.Properties.Name -contains 'connectionString')) {
                throw "anonymize-staging requires a connectionString."
            }
            # No fallback and no default. Every other optional field on every other
            # command degrades to something sensible when it is missing; this one
            # must not, because the value it carries is the operator stating which
            # catalog they mean to destroy contact data in. Absent means unstated,
            # and unstated is not a catalog name.
            if (-not ($Command.PSObject.Properties.Name -contains 'expectedCatalog') -or
                [string]::IsNullOrWhiteSpace([string]$Command.expectedCatalog)) {
                throw "anonymize-staging requires an expectedCatalog naming the catalog to rewrite."
            }
            $arguments = @{
                ConnectionString = [string]$Command.connectionString
                ExpectedCatalog  = [string]$Command.expectedCatalog
            }
            if (($Command.PSObject.Properties.Name -contains 'apply') -and $Command.apply) {
                $arguments['Apply'] = $true
            }
            # Domains whose rows keep their real values, so the people testing on
            # staging can still sign in and still receive the mail they are testing.
            # Carried as one comma-separated string rather than a JSON array so the
            # queued document stays a flat map of scalars like every other command
            # here, and so a hand-written command is still hand-writable.
            #
            # Absent or empty means anonymize everyone. That is the old behaviour and
            # the stricter of the two, so a command written before this field existed
            # keeps working and errs toward removing more contact data, not less. The
            # script validates each domain before it reaches a query.
            if (($Command.PSObject.Properties.Name -contains 'keepEmailDomains') -and
                ![string]::IsNullOrWhiteSpace([string]$Command.keepEmailDomains)) {
                $keepDomains = @(
                    ([string]$Command.keepEmailDomains).Split(',') |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { ![string]::IsNullOrWhiteSpace($_) }
                )
                if ($keepDomains.Count -gt 0) {
                    $arguments['KeepEmailDomains'] = $keepDomains
                }
            }

            & (Join-Path $DeployRoot "Invoke-StagingAnonymization.ps1") @arguments
        }
        default { throw "Unknown command: $($Command.command)" }
    }

    if (-not $?) { throw "Command script reported failure." }
}

# Refreshing is an improvement to the agent, not a precondition for it: a GCS blip must
# not stop the queue draining, because that would turn a transient network error into a
# fleet that will not respond to stop or destroy at all -- strictly worse than the stale
# scripts this exists to avoid.
try {
    Sync-DeploymentScripts -Prefix $BootstrapPrefix -Destination $DeployRoot
}
catch {
    Write-Warning "Could not refresh deployment scripts from ${BootstrapPrefix}: $($_.Exception.Message). Continuing with the copies already on disk."
}

$commands = Get-GcsObjectList -Prefix $PendingPrefix | Where-Object { $_ -like '*.json' }
foreach ($commandObject in $commands) {
    $fileName = Split-Path $commandObject -Leaf
    $resultObject = "$ResultsPrefix$fileName"
    $CommandId = $fileName
    $result = $null
    $job = $null
    $commandOutput = ''
    $commandSecrets = @()

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

        $commandSecrets = Get-CommandSecrets -Command $command

        $job = Start-Job -ScriptBlock $CommandRunner -ArgumentList $DeployRoot, $command
        $finished = Wait-Job -Job $job -Timeout $timeoutSeconds

        # Surface the command's output into the scheduled-task log regardless of
        # outcome, and keep a copy to upload so the workflow can print it too.
        #
        # -ErrorAction Continue is load-bearing. This script runs with
        # $ErrorActionPreference = 'Stop', and Receive-Job re-emits a failed job's
        # error as an error record -- which would become terminating and abandon
        # this assignment, throwing away the output of exactly the failed deploy
        # we wanted to read. Continue keeps it non-terminating so *>&1 can fold it
        # into the captured text; the job's real outcome is judged below from
        # $job.State, not from whether this line errored.
        try {
            $commandOutput = (Receive-Job -Job $job -ErrorAction Continue *>&1 | ForEach-Object {
                Write-Host $_
                [string]$_
            }) -join "`n"
        }
        catch {
            $commandOutput = "(could not read the command's output: $($_.Exception.Message))"
        }

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

        # Upload the output before the result. The workflow stops polling the
        # moment the result object appears, so writing the result first would
        # race the log it is meant to point at.
        $logObject = "$LogsPrefix$CommandId.log"
        try {
            $redactedOutput = Get-RedactedText -Text $commandOutput -Secrets $commandSecrets
            if ([string]::IsNullOrWhiteSpace($redactedOutput)) {
                $redactedOutput = "(the command produced no output)"
            }
            # Keep the tail: the failure and the steps leading to it are at the
            # end, and an unbounded log is neither uploadable nor readable.
            $maxLogCharacters = 200000
            if ($redactedOutput.Length -gt $maxLogCharacters) {
                $redactedOutput = "(truncated to the last $maxLogCharacters characters)`n" +
                    $redactedOutput.Substring($redactedOutput.Length - $maxLogCharacters)
            }
            Write-GcsObjectText -ObjectName $logObject -Text $redactedOutput -ContentType 'text/plain; charset=utf-8'
            # Indexer, not dot-notation: $result is an OrderedDictionary and this
            # adds a key that isn't there yet.
            $result['logObject'] = $logObject
        }
        catch {
            # A log we could not upload must never turn a successful deploy into
            # a failure, or mask the real error on a failed one.
            Write-Warning "Could not upload command output for ${CommandId}: $($_.Exception.Message)"
        }

        $resultJson = $result | ConvertTo-Json -Depth 10
        Write-GcsObjectText -ObjectName $resultObject -Text $resultJson
        Remove-GcsObject -ObjectName $commandObject
    }
}
