[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BucketName,
    [Parameter(Mandatory = $false)][string]$DeployRoot = "C:\RockDeploy",

    # One queue per VM. The bucket is shared across environments, so if two hosts
    # polled the same pending/ prefix they would race for every command and each
    # would run roughly half of them -- a staging deploy could land on production.
    # The default keeps the existing test-VM queue exactly where it is.
    [Parameter(Mandatory = $false)][string]$QueueName = "commands",

    # Where the agent refreshes its own scripts from, and therefore the only thing
    # deciding which repository ref this host executes. The queue name already keeps
    # two hosts from taking each other's commands; it does not keep them from running
    # each other's code. Left as one literal, a production agent would re-download
    # staging's scripts once a minute, so any .ps1 uploaded by the staging bootstrap
    # would be running on production inside 60 seconds with no review in between.
    #
    # The default is the prefix the test VM's installed task already reads. That task
    # was written without this argument and keeps running without it, so moving the
    # default is the one change here that cannot be rolled back from the repository.
    [Parameter(Mandatory = $false)][string]$BootstrapPrefix = "pr-environments/bootstrap/latest/"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($QueueName -notmatch '^[a-z][a-z0-9-]{1,30}$') {
    throw "QueueName must be lowercase letters, digits and hyphens, starting with a letter: '$QueueName'."
}

# $BootstrapPrefix is interpolated into a GCS list query and every name it returns is
# downloaded, parsed and then executed as this host's deployment scripts. Two ways to
# get that wrong are worth failing on rather than discovering later: an empty prefix
# lists the entire bucket, and a prefix missing its trailing slash also matches its
# siblings, so "pr-environments/bootstrap/prod" would pull "bootstrap/prod-old/" too.
if ($BootstrapPrefix -notmatch '^pr-environments/[a-z0-9][a-z0-9/-]*/$') {
    throw "BootstrapPrefix must start with 'pr-environments/' and end with '/': '$BootstrapPrefix'."
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
    # Invoke-WebRequest picks the type of .Content from the response Content-Type:
    # text/* and the JSON and XML families arrive as a string, everything else as a
    # byte[]. gsutil uploads a .ps1 as application/octet-stream, so the deployment
    # scripts land in the second group while the command JSON lands in the first.
    #
    # That is not cosmetic on PowerShell 6+. A byte[] passed to a [string] parameter
    # renders as its elements joined by spaces -- "35 32 82 111 ..." -- which is not
    # the file and does not parse, so Sync-DeploymentScripts would skip every file on
    # every poll while the command queue kept working, its objects being
    # application/json.
    #
    # Read that as defence, not as the diagnosis. Sync-DeploymentScripts really has
    # never delivered a file to connect-srv-test, but retyping an object to text/plain
    # on 2026-08-24 did not make it deliver one either, so this is not the fault. The
    # agent runs under powershell.exe, where .Content may already be a string whatever
    # the content type -- on that VM this is a no-op. Keep it anyway: it costs nothing
    # and it is correct wherever the byte[] form does show up.
    param([Parameter(Mandatory = $true)][string]$ObjectName)
    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$encodedObjectName`?alt=media"
    $headers = @{ Authorization = "Bearer $(Get-GcsAccessToken)" }
    $content = (Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $uri).Content
    if ($content -isnot [byte[]]) {
        return $content
    }

    # A UTF-8 BOM survives GetString as a leading U+FEFF. Left in, it would make the
    # content comparison in Sync-DeploymentScripts differ from the identical copy on
    # disk, so every file would be rewritten on every poll forever.
    if ($content.Length -ge 3 -and $content[0] -eq 0xEF -and $content[1] -eq 0xBB -and $content[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($content, 3, $content.Length - 3)
    }
    return [System.Text.Encoding]::UTF8.GetString($content)
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
function Get-StepLogPath {
    <#
        .SYNOPSIS
        Where a command's deploy timeline is written on the box.

        .DESCRIPTION
        Per-command, so two commands can never interleave into one file, and under
        $DeployRoot so it lands beside the scripts rather than in a temp directory
        that a reboot clears before anybody reads it.

        Named from the pending object's stem rather than from $CommandId. At the
        point in the loop where this is needed, $CommandId is still the pending
        object's file name and carries its .json extension -- it is only replaced by
        the command body's own id once the body parses. Taking the stem here is what
        keeps the timeline beside deploy-staging-1234-1.log instead of landing as
        deploy-staging-1234-1.json-steps.log.

        .PARAMETER DeployRoot
        Where the agent keeps the deployment scripts.

        .PARAMETER CommandObjectName
        The pending object, either the full prefixed name or a bare file name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$DeployRoot,
        [Parameter(Mandatory = $true)][string]$CommandObjectName
    )

    $stem = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $CommandObjectName -Leaf))
    return (Join-Path $DeployRoot (Join-Path 'logs' "$stem-steps.log"))
}

function Get-CommandLogText {
    <#
        .SYNOPSIS
        The command's captured output, followed by the deploy timeline recovered
        from the box.

        .DESCRIPTION
        The background job's output is not a reliable record. Measured on the
        staging rehearsal of 2026-08-25: deploy-staging-32794680054-1 ran 15m24s,
        reported success, and produced a 916-byte log that stops at "Stopping app
        pool" -- the first line of the window in which the site is offline. The
        remaining twelve minutes covered the site replace, the ACL grant, the
        preserved-file restore, the app pool start and the health check, all of
        which ran, because a success result requires reaching the end of the deploy
        script.

        It was not redaction, the character cap, a timeout, a preference change, a
        stale script or a second agent instance; each was ruled out in turn. The
        job stream itself drops records, and the mechanism is still unexplained.

        So the deploy also writes its timeline to a file, and this function puts
        that file back into the uploaded log. It is deliberately indifferent to why
        the stream lost the records, because a production cutover should not be
        waiting on that answer.

        .PARAMETER CaptureText
        What Receive-Job gave back, however complete that turned out to be.

        .PARAMETER StepLogPath
        The timeline file the deploy was told to write. Empty for commands that do
        not write one, which is every command except deploy-environment.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)][string]$CaptureText,
        [Parameter(Mandatory = $false)][string]$StepLogPath
    )

    if ([string]::IsNullOrWhiteSpace($StepLogPath)) { return $CaptureText }

    try {
        if (-not (Test-Path -Path $StepLogPath -PathType Leaf)) { return $CaptureText }
        $timeline = [System.IO.File]::ReadAllText($StepLogPath)
    }
    catch {
        # A timeline we cannot read must never cost us the capture we already have.
        Write-Warning "Could not read the deploy timeline at ${StepLogPath}: $($_.Exception.Message)"
        return $CaptureText
    }

    if ([string]::IsNullOrWhiteSpace($timeline)) { return $CaptureText }

    # Appended rather than prepended. The capture opens with the deploy header,
    # which is the orienting context, and when the capture is short it stops at the
    # interesting moment -- so the recovered timeline reads on from exactly where
    # the reader ran out of log.
    return ($CaptureText.TrimEnd() + "`n`n=== deploy timeline recovered from the box ===`n" + $timeline.TrimEnd())
}

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
    <#
    .SYNOPSIS
        Delete one object, and report it if the delete did not happen.

    .DESCRIPTION
        This used to swallow its own failure into a warning. It has exactly one
        caller and that caller is retiring a queued command, where a delete that
        did not happen is the difference between a command running once and a
        command running every sixty seconds until somebody notices. Swallowing it
        made that outcome indistinguishable from success, so the caller could not
        retry it and could not report it.
    #>
    param([Parameter(Mandatory = $true)][string]$ObjectName)

    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $uri = "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$encodedObjectName"

    try {
        Invoke-GcsRequest -Uri $uri -Method DELETE | Out-Null
    }
    catch {
        # 404 is the outcome this function exists to produce, reached by another
        # route. Reporting it as a failure would cost three retries and then warn
        # that a command is about to run again, when there is no longer an object
        # left to run it from -- a false alarm at the exact moment somebody is
        # already reading warnings carefully.
        #
        # Read through PSObject: Set-StrictMode -Version Latest makes a missing
        # property a terminating error, and the exception shape differs between
        # Windows PowerShell 5.1, which the scheduled task runs under, and the
        # PowerShell 7 this is tested on.
        $statusCode = $null
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($responseProperty -and $responseProperty.Value) {
            $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($statusProperty -and $null -ne $statusProperty.Value) {
                $statusCode = [int]$statusProperty.Value
            }
        }

        if ($statusCode -ne 404) {
            throw
        }
    }
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Run an action until it succeeds. Return $null on success, or the last
        error message if every attempt failed.

    .DESCRIPTION
        Deliberately returns a message rather than throwing. Both callers below are
        finishing a command that has already run, and neither can be allowed to
        abandon the rest of its work because a report failed -- which is precisely
        the bug this whole path exists to close.

    .PARAMETER Action
        The thing to attempt. Runs in the caller's scope.

    .PARAMETER Attempts
        How many times to try in total, not how many times to retry.

    .PARAMETER RetryDelaySeconds
        Multiplied by the attempt number, so the waits lengthen. Zero in tests.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $false)][int]$Attempts = 3,
        [Parameter(Mandatory = $false)][int]$RetryDelaySeconds = 5
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            & $Action
            return $null
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $Attempts -and $RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds ($RetryDelaySeconds * $attempt)
            }
        }
    }

    return $lastError
}

function Complete-QueuedCommand {
    <#
    .SYNOPSIS
        Report a command's result and make sure that command cannot run again.

    .DESCRIPTION
        The object in pending/ is the only record of a command being outstanding.
        The agent lists that prefix every sixty seconds and takes whatever it finds,
        so a command is retired by being deleted and by nothing else.

        This used to be two bare statements, the write first, under an
        $ErrorActionPreference of 'Stop'. Any failure of the write skipped the
        delete, so a transient 503 -- nothing misconfigured, nothing anyone did --
        left the command pending and ran it again a minute later, and again, for as
        long as the host stayed up. On a deploy that means re-extracting the site
        and re-entering migrations underneath a run already in progress.

        So the two halves are independent now, and the delete happens whether or not
        the report did. Reporting failure costs the dispatching workflow a timeout
        with no result: a false red on work that ran exactly once, recoverable by
        reading a log. The behaviour it replaces is recoverable by nothing.

        The proper fix is a claim marker -- move the object to processing/ before
        running it, which is what the unused $ProcessingPrefix was reserved for.
        That changes the contract shared with the enqueue and wait actions, so it is
        deliberately not being done days before a production cutover.

    .PARAMETER Attempts
        Applied to each half separately. A failing report does not spend the
        delete's attempts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CommandObjectName,
        [Parameter(Mandatory = $true)][string]$ResultObjectName,
        [Parameter(Mandatory = $true)][string]$ResultJson,
        [Parameter(Mandatory = $false)][int]$Attempts = 3,
        [Parameter(Mandatory = $false)][int]$RetryDelaySeconds = 5
    )

    $writeError = Invoke-WithRetry -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds -Action {
        Write-GcsObjectText -ObjectName $ResultObjectName -Text $ResultJson
    }

    $removeError = Invoke-WithRetry -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds -Action {
        Remove-GcsObject -ObjectName $CommandObjectName
    }

    if ($writeError) {
        Write-Warning ("Could not write the result object $ResultObjectName after $Attempts attempts: $writeError. " +
            "The command has been retired regardless, so it ran exactly once; the workflow that dispatched it will " +
            "time out waiting for a result that is never going to appear.")
    }

    if ($removeError) {
        # The one outcome this function cannot fix, and the only one that is still
        # getting worse while nobody is looking.
        Write-Warning ("Could not delete $CommandObjectName after $Attempts attempts: $removeError. " +
            "THIS COMMAND WILL RUN AGAIN on the next poll, once a minute, until the object is removed by hand.")
    }
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

    # Only objects sitting directly under the prefix. The bootstrap publishes this
    # directory flat, but bootstrap/latest/ also still holds a PrTestEnvironments/
    # subdirectory of April 2026 scaffolding, and Split-Path -Leaf would flatten
    # those names onto the same destinations -- overwriting eight live scripts with
    # four-month-old stubs, Stop-PrEnvironment.ps1 among them. Those objects have
    # been harmless only because nothing this function fetched ever parsed, so this
    # guard has to land in the same change as the decode above, not after it.
    $objects = Get-GcsObjectList -Prefix $Prefix | Where-Object {
        $_ -like '*.ps1' -and $_.StartsWith($Prefix) -and -not $_.Substring($Prefix.Length).Contains('/')
    }
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
    param($DeployRoot, $Command, $StepLogPath)

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

            # Only this command writes a timeline. It is the one that takes the
            # site offline, and the only one whose log going quiet costs an
            # operator the window they need.
            if (![string]::IsNullOrWhiteSpace($StepLogPath)) {
                $arguments['StepLogPath'] = $StepLogPath
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
    $stepLogPath = Get-StepLogPath -DeployRoot $DeployRoot -CommandObjectName $commandObject
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

        $job = Start-Job -ScriptBlock $CommandRunner -ArgumentList $DeployRoot, $command, $stepLogPath
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
            $mergedOutput = Get-CommandLogText -CaptureText $commandOutput -StepLogPath $stepLogPath
            $redactedOutput = Get-RedactedText -Text $mergedOutput -Secrets $commandSecrets
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
        Complete-QueuedCommand -CommandObjectName $commandObject `
            -ResultObjectName $resultObject `
            -ResultJson $resultJson
    }
}
