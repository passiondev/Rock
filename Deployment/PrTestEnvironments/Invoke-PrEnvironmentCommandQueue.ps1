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

# -cnotmatch, not -notmatch: PowerShell matches case-insensitively by default, so
# this accepted 'Commands' and then polled a prefix GCS considers a different
# directory from the one the producers write to. Every command would have timed
# out against a VM that was running and healthy.
if ($QueueName -cnotmatch '^[a-z][a-z0-9-]{1,30}$') {
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

        Named from the pending object's stem rather than from $commandId. At the
        point in the loop where this is needed, $commandId is still the pending
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

function Get-SecretFieldNamePattern {
    <#
    .SYNOPSIS
        The shape of a command field name whose value must never reach a log.

    .DESCRIPTION
        A shape, not a list of known names. CONTEXT.md states the rule -- redaction
        keys on the shape of a field name -- because two producers once redacted
        `connectionString` while the one holding the sandbox password called the
        same thing `sandboxConnectionString`, and the log that mattered was the one
        that had never heard of the second name.

        Both halves of the queue need the identical rule: the producer redacts what
        it echoes into a public Actions log, the agent redacts what it uploads to
        the bucket, and a field name nobody has invented yet has to be covered by
        both without either being edited. Copied rather than shared, because no
        module can reach the VM (ADR-0001); test_shared_powershell_helpers.py is
        what holds the copies identical.
    #>
    return '(?i)(connectionstring|password|secret|token|credential)'
}

function Get-PasswordValuePattern {
    <#
    .SYNOPSIS
        The keyword backstop for a secret sitting inside an ordinary value.

    .DESCRIPTION
        The name rule cannot see a password embedded in a value that arrived under
        an innocuous name, or quoted inside a line of output a deploy printed. This
        catches `password=` up to the next delimiter. The two patterns together are
        what "redacted" means on both sides of the queue, which is why they are
        named and copied as a pair.
    #>
    return '(?i)(password\s*=\s*)([^;"''\r\n]+)'
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
    $redacted = [regex]::Replace($redacted, (Get-PasswordValuePattern), '${1}<redacted>')
    return $redacted
}

function Get-CommandSecrets {
    param([Parameter(Mandatory = $true)]$Command)

    # Every field whose name reads as a secret, rather than the two whose names
    # happened to exist when this was written. The producer has keyed on the shape
    # since the connectionString / sandboxConnectionString split; this side kept
    # the pair as a literal list, so a third name -- the case the shape rule exists
    # for -- would have been redacted in the public Actions log and printed in full
    # in the log this agent uploads to the bucket. Worse of the two places.
    $namePattern = Get-SecretFieldNamePattern

    $secrets = @()
    foreach ($property in $Command.PSObject.Properties) {
        if ($property.Name -notmatch $namePattern) { continue }

        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $secrets += $value
        # Also redact the password on its own: the full string may be
        # line-wrapped or partially quoted in the output.
        $match = [regex]::Match($value, (Get-PasswordValuePattern))
        if ($match.Success) { $secrets += $match.Groups[2].Value.Trim() }
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

function New-GcsQueueTransport {
    <#
    .SYNOPSIS
        The four things a poll pass does to the bucket, bound to GCS.

    .DESCRIPTION
        The pass used to call the GCS functions above by name, from script scope.
        That made it the one part of the agent every command goes through and the
        one part nothing could run: lifting it meant a bucket, so what it promised
        -- the log lands before the result, a failed refresh still drains the
        queue, an unknown verb comes back as a failed result -- was held by
        matching its source text. Handing it these four operations instead is what
        lets a suite hand it a dictionary.

        Four and no more, because that is everything the pass and
        Complete-QueuedCommand do to a queue: list a prefix, read an object, write
        an object, delete one. Sync-DeploymentScripts still calls GCS directly. It
        reads a different prefix for a different reason, and the suites already
        reach it at the network edge.

        Plain scriptblocks, not closures. Each one resolves the function it calls,
        and the $BucketName that function reads, when it runs rather than when it
        was made -- the same lookup the pass did when these were direct calls.

        Every adapter takes the same parameter names, and the pass calls them by
        name, so a second implementation that spelled one differently fails at its
        first call rather than binding a value to the wrong slot.

    .OUTPUTS
        A hashtable of List, Read, Write and Remove.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        List   = {
            param([string]$Prefix)
            Get-GcsObjectList -Prefix $Prefix
        }
        Read   = {
            param([string]$ObjectName)
            Read-GcsObjectText -ObjectName $ObjectName
        }
        Write  = {
            param([string]$ObjectName, [string]$Text, [string]$ContentType)
            # A blank content type means "whatever a result object has always
            # been", which is Write-GcsObjectText's own default. Passing the blank
            # through would upload the result with no type at all.
            if ([string]::IsNullOrWhiteSpace($ContentType)) {
                Write-GcsObjectText -ObjectName $ObjectName -Text $Text
                return
            }
            Write-GcsObjectText -ObjectName $ObjectName -Text $Text -ContentType $ContentType
        }
        Remove = {
            param([string]$ObjectName)
            Remove-GcsObject -ObjectName $ObjectName
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

    .PARAMETER Transport
        The queue transport -- see New-GcsQueueTransport. Only Write and Remove
        are used here.

    .PARAMETER Attempts
        Applied to each half separately. A failing report does not spend the
        delete's attempts.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Transport,
        [Parameter(Mandatory = $true)][string]$CommandObjectName,
        [Parameter(Mandatory = $true)][string]$ResultObjectName,
        [Parameter(Mandatory = $true)][string]$ResultJson,
        [Parameter(Mandatory = $false)][int]$Attempts = 3,
        [Parameter(Mandatory = $false)][int]$RetryDelaySeconds = 5
    )

    # Out-Null on both: Invoke-WithRetry reports success by returning nothing, so
    # anything an adapter happened to emit would come back here as an error
    # message and be printed as a failure that did not happen.
    $writeError = Invoke-WithRetry -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds -Action {
        & $Transport.Write -ObjectName $ResultObjectName -Text $ResultJson | Out-Null
    }

    $removeError = Invoke-WithRetry -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds -Action {
        & $Transport.Remove -ObjectName $CommandObjectName | Out-Null
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

    # Everything this function says, it says through Write-Host and Write-Warning,
    # and it runs before the command loop starts -- so none of it is captured in a
    # command result and none of it reaches the bucket. That is why "the script
    # refresh has never delivered a file to connect-srv-test" has stood as an
    # unexplained claim for weeks: there has never been an artifact that would show
    # the difference between not delivering and not being watched.
    #
    # This records the outcome per file where the next deploy can read it back and
    # print it -- see Write-DeployScriptProvenance in Deploy-RockEnvironment.ps1.
    # Until that evidence exists there is nothing to fix and nothing to justify
    # deleting either, so the function stays and starts reporting.
    $syncResults = @()

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
                $syncResults += [ordered]@{ name = $name; status = 'skipped-unparseable'; detail = $parseErrors[0].Message }
                continue
            }

            $localPath = Join-Path $Destination $name
            if (Test-Path $localPath) {
                if ((Get-Content $localPath -Raw) -eq $text) {
                    $syncResults += [ordered]@{ name = $name; status = 'identical'; detail = '' }
                    continue
                }
            }

            # Staged and moved rather than written in place: a write interrupted partway
            # leaves a truncated script, which is the same brick the parse check exists to
            # avoid.
            $stagingPath = "$localPath.sync"
            [System.IO.File]::WriteAllText($stagingPath, $text, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $stagingPath -Destination $localPath -Force
            Write-Host "Refreshed $name from $Prefix."
            $syncResults += [ordered]@{ name = $name; status = 'refreshed'; detail = "$($text.Length) chars" }
        }
        catch {
            Write-Warning "Could not refresh ${name}: $($_.Exception.Message). Keeping the copy already on disk."
            $syncResults += [ordered]@{ name = $name; status = 'error'; detail = $_.Exception.Message }
        }
    }

    # Best effort by design. This file is a diagnostic; failing to write it must
    # not turn a successful refresh into a failed one, and an agent that cannot
    # write beside its own scripts has a larger problem than this line.
    try {
        $state = [ordered]@{
            lastRunUtc   = (Get-Date).ToUniversalTime().ToString('o')
            prefix       = $Prefix
            objectsSeen  = $objects.Count
            files        = @($syncResults)
        }
        $statePath = Join-Path $Destination 'script-sync-state.json'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Warning "Could not record the script sync state: $($_.Exception.Message)."
    }
}

function Get-CommandBindingKind {
    <#
        .SYNOPSIS
        The ways a field of a queued command can reach a script parameter.

        .DESCRIPTION
        Named here rather than restated in each contract row and again in the
        binder, so that a section name nobody recognises is a refusal instead of a
        binding that quietly does nothing.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Required', 'Optional', 'Flag', 'List', 'Verbatim', 'Runtime')
}

function Get-CommandContractSection {
    <#
        .SYNOPSIS
        The sections of a contract row that bind no field.

        .DESCRIPTION
        Named beside the binding kinds for the same reason those are named: the
        binder refuses a section it does not recognise, so every section that is
        deliberately not a binding has to be listed somewhere, and a list written
        out inside the binder is one the tests cannot ask for.

            Script          The file to run, a bare name joined onto $DeployRoot.
            TimeoutSeconds  How long the background job may take.
            Unreachable     Script parameters a queued document is not allowed to
                            set, by name, so that the set of parameters is
                            accounted for rather than merely partly listed.

        Unreachable is the one that earns a section of its own. Deploy-RockEnvironment.ps1
        takes seventeen parameters and this table reached thirteen of them; the
        other four were not a decision recorded anywhere, they were the absence of
        one. A parameter added to a deployment script and never wired here looks
        exactly like a parameter deliberately left on its default, and the first
        reader to notice is an operator who wants to set it during an incident.
        Naming them turns the sweep in CommandContract.Tests.ps1 into a real
        question: every parameter is bound, or it is listed here with a reason.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Script', 'TimeoutSeconds', 'Unreachable')
}

function Get-CommandContract {
    <#
        .SYNOPSIS
        What one queued verb runs, how long it may take, and how the fields of a
        queued document reach that script's parameters.

        .DESCRIPTION
        Adding a verb used to take four edits in four places -- a timeout table, a
        switch arm inside the background job, the secret list, and the producer's
        payload -- and nothing asserted that the four agreed. Three of those are one
        row here. The fourth stopped being a list when redaction moved to keying on
        the shape of a field name, so a new secret-shaped field needs no edit at all.

        Commands run inside a background job with a per-command timeout. Without
        one, a command that hangs -- a certificate renewal blocked on win-acme, say
        -- never returns, so this once-per-minute task, which Windows will not start
        a second instance of while one is running, wedges and stops processing every
        other command. The poll loop in the queueing workflow then times out with no
        result instead of seeing a real failure. On timeout the job is killed and a
        failed result is written, keeping the queue healthy and the workflow
        informed. Each TimeoutSeconds is kept comfortably under its own workflow's
        poll window so the workflow reports the failure rather than timing out first.

        The binding kinds are a vocabulary, not a convenience. Each is a rule about
        what a missing or blank value means, and the versions written out by hand
        inside the job disagreed with one another:

            Required  Present and non-blank, or the command is refused by name.
            Optional  Forwarded when present and non-blank. Absent means "leave the
                      script's own default alone" -- which is how a production
                      deploy omits connectionString and keeps the one on the box.
            Flag      Forwarded as $true when present and truthy, omitted otherwise.
                      A switch that has to be asked for, which is what makes -Apply
                      a dry run by default.
            List      One comma-separated field split into an array. The queued
                      document stays a flat map of scalars like every other field,
                      so a hand-written command is still hand-writable.
            Verbatim  Forwarded whenever the property exists, empty or not. Only for
                      a field whose empty value means something -- clearing a block
                      rather than omitting it.
            Runtime   Not from the document at all: a value this agent knows and the
                      script needs. The key names the value, the value names the
                      parameter.

        Beside those, each row carries an Unreachable list: script parameters a
        queued document may not set, named so that the row accounts for the whole
        signature rather than describing part of it. See Get-CommandContractSection
        for why that is a section and not a comment, and CommandContract.Tests.ps1
        for the sweep that holds every row to it.

        The table lives inside a function because the Pester suites read functions
        out of these scripts rather than running them -- see Import-ScriptFunction.
        A hashtable at script scope would be unreachable, which is how the old one
        went unchecked.

        Script is a bare file name, joined onto $DeployRoot by the caller. The
        bootstrap copies Deployment/PrTestEnvironments and Deployment/Database into
        the same directory on the box, so two of these live in a different folder in
        this repository than they do on the VM.

        .PARAMETER Command
        The verb to look up. Omit it for the whole table, which is what the tests
        sweep.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$Command)

    $contracts = [ordered]@{

        'deploy' = @{
            Script         = 'Deploy-PrEnvironment.ps1'
            TimeoutSeconds = 1500
            Required       = [ordered]@{
                prNumber                = 'PrNumber'
                sha                     = 'Sha'
                artifactGcsPath         = 'ArtifactGcsPath'
                hostName                = 'HostName'
                sandboxConnectionString = 'SandboxConnectionString'
            }
            # EnvironmentRoot is where the whole fleet lives, and the certificate
            # renewal job walks that one tree; a command that moved one PR site out
            # of it would leave that site's certificate to expire unrenewed. The
            # other three are machine configuration the bootstrap sets as
            # environment variables on the box, so the answer differs per VM and a
            # queued document written on a runner does not know it.
            Unreachable    = @(
                'EnvironmentRoot',
                'CertificateThumbprint',
                'SharedAssetSourcePath',
                'SharedAssetDirectories'
            )
        }

        # Long-lived named environments (staging, production).
        'deploy-environment' = @{
            Script         = 'Deploy-RockEnvironment.ps1'
            TimeoutSeconds = 1800
            Required       = [ordered]@{
                environmentName = 'EnvironmentName'
                sha             = 'Sha'
                artifactGcsPath = 'ArtifactGcsPath'
                hostName        = 'HostName'
            }
            # Optional so that an older queued command still runs, and so that
            # production can omit connectionString and keep the one already on disk.
            Optional       = [ordered]@{
                mode              = 'Mode'
                connectionString  = 'ConnectionString'
                targetSitePath    = 'TargetSitePath'
                targetSiteName    = 'TargetSiteName'
                targetAppPoolName = 'TargetAppPoolName'
                environmentRoot   = 'EnvironmentRoot'
                # Reachable, and by a hand-written command only: no workflow input
                # sets it. On InPlace this decides where the sole rollback copy of
                # production goes and, because the manifest must never sit under
                # $EnvironmentRoot where the renewal job would find it, where the
                # manifest goes too -- and it was the one parameter with that much
                # riding on it that nothing could state. It stays out of
                # env-deploy-command.yml deliberately: every restore path in the
                # production runbook is written out as
                # C:\RockBackups\production\<utc>-<sha>, the rollback included, and a
                # dispatch box that could move it would make all of them wrong for
                # the one run somebody reads them during. A
                # full disk on the morning of a cutover is what the escape hatch is
                # for, and that operator is writing the queued document by hand.
                backupRoot        = 'BackupRoot'
            }
            # InPlace deploys are a dry run unless the command explicitly opts in.
            Flag           = [ordered]@{ apply = 'Apply' }
            # Only this command writes a timeline. It is the one that takes the site
            # offline, and the only one whose log going quiet costs an operator the
            # window they need.
            Runtime        = [ordered]@{ StepLogPath = 'StepLogPath' }
            # HealthCheckTimeoutSeconds is held under this row's own TimeoutSeconds,
            # which is 1800 and is what the agent kills the job at. A command that
            # raised the health check past it would not get a longer wait, it would
            # get a killed job reported as a failure while the site was still
            # migrating -- the one outcome that makes an operator roll back a deploy
            # that was working. Moving it means moving both numbers and the 60-minute
            # job limit in env-deploy-command.yml, which is an edit, not a field.
            # The other three are the same machine configuration the PR deploy reads,
            # and unreachable for the same reason.
            Unreachable    = @(
                'CertificateThumbprint',
                'SharedAssetSourcePath',
                'SharedAssetDirectories',
                'HealthCheckTimeoutSeconds'
            )
        }

        # Both take EnvironmentRoot and neither offers it. A stop or a destroy
        # aimed at a root other than the one the deploy used would find no site and
        # report success, which is the worst answer a destroy can give: the
        # environment is still up and the queue says it is gone.
        'stop' = @{
            Script         = 'Stop-PrEnvironment.ps1'
            TimeoutSeconds = 300
            Required       = [ordered]@{ prNumber = 'PrNumber' }
            Unreachable    = @('EnvironmentRoot')
        }

        'destroy' = @{
            Script         = 'Destroy-PrEnvironment.ps1'
            TimeoutSeconds = 300
            Required       = [ordered]@{ prNumber = 'PrNumber' }
            Unreachable    = @('EnvironmentRoot')
        }

        'renew-certificate' = @{
            Script         = 'Invoke-PrEnvironmentCertificateRenewal.ps1'
            TimeoutSeconds = 720
            # The only verb whose whole argument list is something this agent knows
            # rather than something the queued document carries.
            Runtime        = [ordered]@{ DeployRoot = 'DeployRoot' }
            # Which is the point of the row, so the rest of the signature is
            # unreachable by design rather than by omission. This one runs on a
            # timer against every manifest on the box; a queued document that could
            # narrow its roots or shorten its window would turn the fleet-wide
            # renewal into a partial one, and the next anybody heard of it would be
            # an expired certificate on a site nobody dispatched anything for.
            Unreachable    = @(
                'EnvironmentRoot',
                'AdditionalManifestRoots',
                'RenewWithinDays',
                'PerHostTimeoutSeconds',
                'WinAcmeDownloadUrl'
            )
        }

        # Read-only, and deliberately the only Deployment/Database script this agent
        # can reach. Convert-LegacyTextColumns.ps1 is -Apply-gated and rewrites
        # column types; it stays a by-hand script with a human reading the finder's
        # output first, so there is no row for it here.
        #
        # This exists because the finder had nowhere to run. The catalog is behind a
        # PSC endpoint with no public IP, and Cloud SQL refuses any login but the
        # owning `sqlserver` account into the database it owns -- so neither a runner
        # nor a workstation nor a hand-made diagnostic login can open it. The VM
        # already holds a working connection string on every deploy. Rather than
        # issue a second credential, the finder runs where that one already is.
        'find-legacy-text-columns' = @{
            Script         = 'Find-LegacyTextColumns.ps1'
            # Metadata-only by default and quick, but -MeasureSizes full-scans every
            # table that has a legacy column, and the catalog this is aimed at is
            # 115 GB. The fallback would kill a real scan part-way and report it as a
            # failure, which on a read-only diagnostic is the worst kind of wrong
            # answer: it looks like the catalog is unreadable rather than merely large.
            TimeoutSeconds = 1800
            Required       = [ordered]@{ connectionString = 'ConnectionString' }
            Flag           = [ordered]@{ measureSizes = 'MeasureSizes' }
            # OutFile writes beside the script on a box whose disk nobody watches,
            # and the command result already carries the finding; CommandTimeoutSeconds
            # is the SQL command's own limit and belongs under this row's 1800, for
            # the reason spelled out on deploy-environment.
            Unreachable    = @('OutFile', 'CommandTimeoutSeconds')
        }

        # Replaces real email addresses and phone numbers in a prod-derived staging
        # catalog with undeliverable substitutes. Here for the same reason the finder
        # is: the catalog is reachable from this VM and from nowhere else.
        #
        # Unlike the finder this one writes, so the row carries its own gates rather
        # than trusting the caller to have set them. The script refuses the production
        # instance by address and refuses a catalog that does not match
        # expectedCatalog, and it is a dry run without apply. Those checks live in the
        # script because that is where they are enforced; they are restated here
        # because this row is what a queued JSON document can reach, and a command is
        # easier to hand-write than a script is to edit.
        'anonymize-staging' = @{
            Script         = 'Invoke-StagingAnonymization.ps1'
            # Batched UPDATEs over every Person and PhoneNumber row in a prod-derived
            # catalog. The dry run is five COUNT(*)s and returns in seconds; -Apply
            # rewrites millions of rows and is the case this number has to cover.
            # Killing it part-way is survivable -- every batch commits on its own and
            # the predicates skip rows already done, so a rerun resumes -- but a
            # half-anonymized catalog reported as a failure invites someone to
            # conclude the run did nothing and leave real addresses in place.
            TimeoutSeconds = 3600
            Required       = [ordered]@{
                connectionString = 'ConnectionString'
                # No fallback and no default. Every other optional field on every
                # other command degrades to something sensible when it is missing;
                # this one must not, because the value it carries is the operator
                # stating which catalog they mean to destroy contact data in. Absent
                # means unstated, and unstated is not a catalog name.
                expectedCatalog  = 'ExpectedCatalog'
            }
            Flag           = [ordered]@{ apply = 'Apply' }
            # Domains whose rows keep their real values, so the people testing on
            # staging can still sign in and still receive the mail they are testing.
            #
            # Absent or empty means anonymize everyone. That is the old behaviour and
            # the stricter of the two, so a command written before this field existed
            # keeps working and errs toward removing more contact data, not less. The
            # script validates each domain before it reaches a query.
            List           = [ordered]@{ keepEmailDomains = 'KeepEmailDomains' }
            # BatchSize is a tuning knob over millions of rows and the script's own
            # default is the one that has been run; OutFile and CommandTimeoutSeconds
            # are unreachable for the reasons the finder's row gives.
            Unreachable    = @('BatchSize', 'OutFile', 'CommandTimeoutSeconds')
        }

        # Writes a theme's brand colours and custom CSS into
        # Theme.AdditionalSettingsJson. Here for the same reason the other two
        # database commands are: the catalog is reachable from this VM and from
        # nowhere else.
        #
        # This is the database half of the internal site's branding. The .less half
        # ships in the artifact; this half is per-catalog, and the v19 migration that
        # repoints the internal site at RockNextGen creates the row with it empty. So
        # the theme it addresses may not have existed until the deploy that ran just
        # before this command.
        'set-theme-customization' = @{
            Script         = 'Set-RockThemeCustomization.ps1'
            # One SELECT and one UPDATE against a table with a handful of rows. Short
            # on purpose: nothing about this command can legitimately take minutes, so
            # a run that hangs is a lock or a dead connection, and failing fast says so.
            TimeoutSeconds = 300
            Required       = [ordered]@{
                themeName        = 'ThemeName'
                connectionString = 'ConnectionString'
            }
            # -Apply-gated like anonymize-staging, and for the same reason: the queued
            # document is easier to hand-write than the script is to edit, so the row
            # forwards the gate rather than assuming the caller set it.
            Flag           = [ordered]@{ apply = 'Apply' }
            # Variable assignments arrive as one comma-separated string of name=value
            # pairs. A colour cannot contain a comma; the script rejects anything that
            # is not name=value before it reaches a query.
            List           = [ordered]@{ variableValues = 'VariableValues' }
            # Presence, not emptiness, decides whether the override block is written:
            # an empty string is how an operator clears it, and treating that as
            # "absent" would make clearing impossible. Every other optional field here
            # degrades on whitespace; this one must not.
            Verbatim       = [ordered]@{ customOverrides = 'CustomOverrides' }
            # RollbackScriptPath is the undo for the one UPDATE this makes, and it
            # is written whether or not anybody asked: a queued command that could
            # point it somewhere else could point it somewhere unwritable, and the
            # write would go ahead with the undo silently missing.
            Unreachable    = @('RollbackScriptPath', 'CommandTimeoutSeconds')
        }
    }

    if ([string]::IsNullOrWhiteSpace($Command)) { return $contracts }
    if (-not $contracts.Contains($Command)) { throw "Unknown command: $Command" }
    return $contracts[$Command]
}

function Split-CommandList {
    <#
        .SYNOPSIS
        One comma-separated field of a queued document, as an array.

        .DESCRIPTION
        Written out twice word for word before this existed -- once for the
        anonymizer's keep list and once for the theme's variable assignments.

        Comma-separated rather than a JSON array so that the queued document stays a
        flat map of scalars like every other field, and so that a hand-written
        command is still hand-writable.

        Blanks are dropped and an all-blank value yields nothing, which is what lets
        the caller read "nothing survived" as "the field was not stated".

        .PARAMETER Value
        The raw field value.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    return @($Value.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { ![string]::IsNullOrWhiteSpace($_) })
}

function Resolve-CommandArguments {
    <#
        .SYNOPSIS
        The script one queued command runs, and the arguments to splat at it.

        .DESCRIPTION
        This was a switch inside the scriptblock handed to Start-Job, which put it in
        a different runspace from every test in this repository: nothing could call
        it, so what it did was asserted by matching the text of its own source. The
        payload-to-argument step was written out five times, the comma-split list
        parser twice word for word, and three different rules governed a blank value
        with nothing saying which was meant where.

        Binding here rather than inside the job also moves a refusal to before the
        job starts, into the loop's own try, so a command the agent will not run
        comes back as a failed result carrying the reason rather than as a job that
        died.

        .PARAMETER Command
        The parsed command document.

        .PARAMETER DeployRoot
        Where the agent keeps the deployment scripts. A Runtime value, and also what
        the caller joins the returned Script onto.

        .PARAMETER StepLogPath
        The deploy timeline this command should write, for the one contract that asks
        for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $false)][string]$DeployRoot,
        [Parameter(Mandatory = $false)][string]$StepLogPath
    )

    # Read through PSObject throughout: Set-StrictMode -Version Latest makes a
    # missing property a terminating error, and a queued document is a JSON file that
    # may have been written before any field here existed.
    $present = @($Command.PSObject.Properties.Name)
    if ($present -notcontains 'command') {
        throw "The queued document names no command."
    }

    $name = [string]$Command.command
    $contract = Get-CommandContract -Command $name

    if (-not $contract.Contains('Script')) {
        throw "The contract for '$name' names no script to run."
    }

    # A section name that is not a binding kind binds nothing at all, silently:
    # `Flags` where `Flag` was meant drops -Apply, and every queued run becomes a dry
    # run that reports success. Refusing is the only outcome that says so.
    #
    # The sections that bind nothing are asked for rather than spelled out here.
    # They were two names compared inline, which is the shape that makes adding a
    # third an edit in two files where only one of them refuses.
    $kinds = Get-CommandBindingKind
    $sections = Get-CommandContractSection
    foreach ($section in @($contract.Keys)) {
        if ($sections -contains $section) { continue }
        if ($kinds -notcontains $section) {
            throw "The contract for '$name' declares a '$section' section, which is neither a binding kind ($($kinds -join ', ')) nor a section that binds nothing ($($sections -join ', '))."
        }
    }

    $binding = @{}
    foreach ($kind in $kinds) {
        $binding[$kind] = if ($contract.Contains($kind)) { $contract[$kind] } else { [ordered]@{} }
    }

    $arguments = @{}

    foreach ($field in @($binding.Required.Keys)) {
        if ($present -notcontains $field -or [string]::IsNullOrWhiteSpace([string]$Command.$field)) {
            throw "$name requires $field."
        }
        $arguments[$binding.Required[$field]] = [string]$Command.$field
    }

    foreach ($field in @($binding.Optional.Keys)) {
        if ($present -notcontains $field) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$Command.$field)) { continue }
        $arguments[$binding.Optional[$field]] = [string]$Command.$field
    }

    foreach ($field in @($binding.Flag.Keys)) {
        if ($present -notcontains $field) { continue }
        if (-not $Command.$field) { continue }
        $arguments[$binding.Flag[$field]] = $true
    }

    foreach ($field in @($binding.List.Keys)) {
        if ($present -notcontains $field) { continue }
        $values = @(Split-CommandList -Value ([string]$Command.$field))
        if ($values.Count -eq 0) { continue }
        $arguments[$binding.List[$field]] = $values
    }

    foreach ($field in @($binding.Verbatim.Keys)) {
        if ($present -notcontains $field) { continue }
        $arguments[$binding.Verbatim[$field]] = [string]$Command.$field
    }

    $runtime = @{ DeployRoot = $DeployRoot; StepLogPath = $StepLogPath }
    foreach ($value in @($binding.Runtime.Keys)) {
        if (-not $runtime.ContainsKey($value)) {
            throw "The contract for '$name' asks for a runtime value named '$value', which this agent does not have."
        }
        if ([string]::IsNullOrWhiteSpace($runtime[$value])) { continue }
        $arguments[$binding.Runtime[$value]] = $runtime[$value]
    }

    return @{
        Script    = [string]$contract.Script
        Arguments = $arguments
    }
}

function Invoke-CommandJob {
    <#
    .SYNOPSIS
        Run one contract script in a background job, with a timeout, and report
        how it went.

    .DESCRIPTION
        The command runner production hands Invoke-CommandQueuePass. The pass
        decides what to run; this is the one step of a command that happens
        somewhere a test of the pass cannot follow, so it does nothing but start
        the job, wait for it, read it and clean it up.

        A job rather than a call so that a script which hangs can be stopped. The
        poll is a scheduled task that fires every minute, and a deploy that never
        returned would hold every command queued behind it.

        It reports rather than throws. The pass turns a timeout or a failure into
        the message the dispatching workflow prints, and it needs the output in
        hand first whichever way the script went: the output of a failed deploy
        is the reason anybody opens the log.

    .PARAMETER DeployRoot
        Where the agent keeps the deployment scripts. ScriptName is joined onto it.

    .PARAMETER ScriptName
        The bare file name the command's contract names.

    .PARAMETER Arguments
        What to splat at the script. It crosses into the job through the
        serializer Start-Job puts every argument through, which is why
        Resolve-CommandArguments builds it from strings, booleans and string
        arrays and nothing else.

    .PARAMETER TimeoutSeconds
        How long to wait before stopping the job.

    .OUTPUTS
        Output, everything the job wrote as one string; HasTimedOut; and Failure, the
        reason the job failed, or empty when it did not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeployRoot,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $false)][hashtable]$Arguments = @{},
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    # Three lines, and that is the point. Start-Job runs this in its own runspace,
    # where nothing defined above is in scope and no test can reach: whatever lives
    # here can only ever be checked by matching its own source text. So the deciding
    # is done before the job starts -- see Resolve-CommandArguments -- and what
    # crosses into the runspace is a script name and a hashtable of arguments, both
    # of which survive the serializer Start-Job puts them through.
    $jobScript = {
        param($DeployRoot, $ScriptName, $Arguments)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        & (Join-Path $DeployRoot $ScriptName) @Arguments

        if (-not $?) { throw "Command script reported failure." }
    }

    $job = Start-Job -ScriptBlock $jobScript -ArgumentList $DeployRoot, $ScriptName, $Arguments
    try {
        $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds

        # Surface the command's output into the scheduled-task log regardless of
        # outcome, and keep a copy to upload so the workflow can print it too.
        #
        # -ErrorAction Continue is load-bearing. The agent runs with
        # $ErrorActionPreference = 'Stop', and Receive-Job re-emits a failed job's
        # error as an error record -- which would become terminating and abandon
        # this assignment, throwing away the output of exactly the failed deploy
        # we wanted to read. Continue keeps it non-terminating so *>&1 can fold it
        # into the captured text; the job's real outcome is judged below from
        # $job.State, not from whether this line errored.
        $output = ''
        try {
            $output = (Receive-Job -Job $job -ErrorAction Continue *>&1 | ForEach-Object {
                Write-Host $_
                [string]$_
            }) -join "`n"
        }
        catch {
            $output = "(could not read the command's output: $($_.Exception.Message))"
        }

        $hasTimedOut = $false
        $failure = ''
        if ($null -eq $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $hasTimedOut = $true
        }
        elseif ($job.State -eq 'Failed') {
            $failure = "Command script reported failure."
            $failedChild = $job.ChildJobs | Where-Object { $_.JobStateInfo.Reason } | Select-Object -First 1
            if ($failedChild) { $failure = $failedChild.JobStateInfo.Reason.Message }
        }

        return [pscustomobject]@{
            Output   = $output
            HasTimedOut = $hasTimedOut
            Failure  = $failure
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CommandQueuePass {
    <#
    .SYNOPSIS
        One poll of the queue: refresh the scripts, then run, report and retire
        every pending command.

    .DESCRIPTION
        This is everything the scheduled task does each minute. It used to be the
        body of this script, after the definitions, calling GCS and Start-Job by
        name, so nothing could run it without a bucket and a VM and the promises
        below were held by matching its source text. Its three edges are
        parameters now. Production passes New-GcsQueueTransport, Invoke-CommandJob
        and Sync-DeploymentScripts; the CommandQueuePass Pester suite passes a
        dictionary, a recorder and a stand-in, then reads each result back with
        the reader the dispatching workflow uses.

        What it promises:

          The refresh runs before anything is listed, so a fix reaches the command
          about to run, and a refresh that fails is a warning, never a reason to
          stop draining the queue.

          A command the agent will not run -- an unknown verb, a missing field --
          comes back as a failed result naming why, and the runner never starts.

          The log is written before the result, because the workflow stops polling
          the moment the result appears.

          Every command is retired, whether or not its result could be written;
          see Complete-QueuedCommand.

        Commands are not claimed before they run, so two passes that overlap both
        run whatever both of them listed. That is open item 19 in
        Documentation/Training/DevOps-Open-Items-Rock-CICD.md, and the transport is
        where a claim would go.

    .PARAMETER Transport
        The queue transport: List, Read, Write and Remove. See New-GcsQueueTransport.

    .PARAMETER Runner
        Runs one contract script. Takes DeployRoot, ScriptName, Arguments and
        TimeoutSeconds by name and returns Output, HasTimedOut and Failure. See
        Invoke-CommandJob.

    .PARAMETER RefreshScripts
        Brings the scripts under DeployRoot up to date. Takes Prefix and
        Destination by name. See Sync-DeploymentScripts.

    .PARAMETER DeployRoot
        Where the agent keeps the deployment scripts and the per-command step logs.

    .PARAMETER BootstrapPrefix
        Where the refresh reads the scripts from.

    .PARAMETER PendingPrefix
        The queue. Every .json object the transport lists under it is a command.

    .PARAMETER ResultsPrefix
        Where each result is written, under the same file name as its command.

    .PARAMETER LogsPrefix
        Where each command's redacted output is written, before its result.

    .PARAMETER CompletionAttempts
        Passed to Complete-QueuedCommand as Attempts.

    .PARAMETER CompletionRetryDelaySeconds
        Passed to Complete-QueuedCommand as RetryDelaySeconds. Zero in tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Transport,
        [Parameter(Mandatory = $true)][scriptblock]$Runner,
        [Parameter(Mandatory = $true)][scriptblock]$RefreshScripts,
        [Parameter(Mandatory = $true)][string]$DeployRoot,
        [Parameter(Mandatory = $true)][string]$BootstrapPrefix,
        [Parameter(Mandatory = $true)][string]$PendingPrefix,
        [Parameter(Mandatory = $true)][string]$ResultsPrefix,
        [Parameter(Mandatory = $true)][string]$LogsPrefix,
        [Parameter(Mandatory = $false)][int]$CompletionAttempts = 3,
        [Parameter(Mandatory = $false)][int]$CompletionRetryDelaySeconds = 5
    )

    # Refreshing is an improvement to the agent, not a precondition for it: a GCS blip must
    # not stop the queue draining, because that would turn a transient network error into a
    # fleet that will not respond to stop or destroy at all -- strictly worse than the stale
    # scripts this exists to avoid.
    try {
        & $RefreshScripts -Prefix $BootstrapPrefix -Destination $DeployRoot
    }
    catch {
        Write-Warning "Could not refresh deployment scripts from ${BootstrapPrefix}: $($_.Exception.Message). Continuing with the copies already on disk."
    }

    $commands = & $Transport.List -Prefix $PendingPrefix | Where-Object { $_ -like '*.json' }
    foreach ($commandObject in $commands) {
        $fileName = Split-Path $commandObject -Leaf
        $resultObject = "$ResultsPrefix$fileName"
        $commandId = $fileName
        $result = $null
        $stepLogPath = Get-StepLogPath -DeployRoot $DeployRoot -CommandObjectName $commandObject
        $commandOutput = ''
        $commandSecrets = @()

        try {
            $commandJson = & $Transport.Read -ObjectName $commandObject
            $command = $commandJson | ConvertFrom-Json
            $commandId = $command.commandId
            Write-Host "Processing PR environment command ${CommandId}: $($command.command)"

            # Unknown verbs are refused here rather than inside the job, so the result
            # says "Unknown command" instead of reporting that a job failed.
            $timeoutSeconds = [int](Get-CommandContract -Command ([string]$command.command)).TimeoutSeconds
            if (($command.PSObject.Properties.Name -contains 'timeoutSeconds') -and $command.timeoutSeconds) {
                $timeoutSeconds = [int]$command.timeoutSeconds
            }

            $commandSecrets = Get-CommandSecrets -Command $command

            # Bound before the job starts, because the job is a runspace this script and
            # its tests cannot reach. A command whose fields do not satisfy its contract
            # is refused here, by this try, and comes back as a failed result naming the
            # field -- not as a job that died.
            $plan = Resolve-CommandArguments -Command $command -DeployRoot $DeployRoot -StepLogPath $stepLogPath

            # The output is kept before the outcome is judged: both throws below land
            # in the catch, and the finally still has to upload what the script printed
            # on its way to failing -- that is the log somebody is about to read.
            $run = & $Runner -DeployRoot $DeployRoot -ScriptName $plan.Script -Arguments $plan.Arguments -TimeoutSeconds $timeoutSeconds
            $commandOutput = [string]$run.Output

            if ($run.HasTimedOut) {
                throw "Command '$($command.command)' timed out after $timeoutSeconds seconds and was terminated."
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$run.Failure)) {
                throw "Command '$($command.command)' failed: $($run.Failure)"
            }

            $prNumber = $null
            if ($command.PSObject.Properties.Name -contains 'prNumber') { $prNumber = $command.prNumber }
            $result = [ordered]@{ commandId = $commandId; prNumber = $prNumber; command = $command.command; status = "succeeded"; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
        }
        catch {
            $result = [ordered]@{ commandId = $commandId; status = "failed"; error = $_.Exception.Message; completedAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
        }
        finally {
            # Upload the output before the result. The workflow stops polling the
            # moment the result object appears, so writing the result first would
            # race the log it is meant to point at.
            $logObject = "$LogsPrefix$commandId.log"
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
                & $Transport.Write -ObjectName $logObject -Text $redactedOutput -ContentType 'text/plain; charset=utf-8' | Out-Null
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
            Complete-QueuedCommand -Transport $Transport `
                -CommandObjectName $commandObject `
                -ResultObjectName $resultObject `
                -ResultJson $resultJson `
                -Attempts $CompletionAttempts `
                -RetryDelaySeconds $CompletionRetryDelaySeconds
        }
    }
}

# The scheduled task's whole job. Everything the pass reaches outside its own
# process arrives through these three arguments, which is what lets the
# CommandQueuePass Pester suite run this same function against a bucket held in
# memory.
$transport = New-GcsQueueTransport

Invoke-CommandQueuePass -Transport $transport `
    -Runner ${function:Invoke-CommandJob} `
    -RefreshScripts ${function:Sync-DeploymentScripts} `
    -DeployRoot $DeployRoot `
    -BootstrapPrefix $BootstrapPrefix `
    -PendingPrefix $PendingPrefix `
    -ResultsPrefix $ResultsPrefix `
    -LogsPrefix $LogsPrefix
