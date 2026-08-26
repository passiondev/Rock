<#
.SYNOPSIS
    Builds a VM queue command, echoes it with the secrets removed, and uploads it.

.DESCRIPTION
    The queue protocol is a JSON object dropped into
    `gs://<bucket>/pr-environments/<queue>/pending/<commandId>.json`. Six
    workflows write one, and every one of them hand-rolled the envelope, the
    drop-if-empty rules and -- in two cases -- the redaction.

    This is a script rather than PowerShell inlined into action.yml so that the
    redaction can be loaded and executed by the Pester suite. PowerShell embedded
    in YAML is a string that nothing can run until a runner expands it, which is
    how the two echo loops came to key on `connectionString` while the producer
    holding the sandbox password called the same field `sandboxConnectionString`.
    See Tests/PrTestEnvironments/Pester/QueueCommand.Tests.ps1.

    Kept to Windows PowerShell 5.1 syntax. It only ever runs on the runner's
    pwsh 7 today, but the queue agent it talks to is 5.1 and these two halves get
    read together.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-VmCommand {
    <#
    .SYNOPSIS
        Merges the queue envelope with a caller's payload into one ordered command.
    .PARAMETER Payload
        A JSON object of command-specific fields. Fields whose value is null or
        blank are dropped, which is what replaces the drop-if-empty branches the
        callers used to carry. A false boolean is kept: the VM reads optional
        flags as `-contains 'apply' -and $Command.apply`, so present-and-false
        behaves as absent, and keeping it records the decision in the log.
    .PARAMETER SecretField
        The field name to place SecretValue under. Two live names exist for one
        concept -- the PR fleet's `deploy` verb reads sandboxConnectionString and
        `deploy-environment` reads connectionString -- and renaming either means
        republishing the queue agent to the VM before any deploy would work.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$CommandId,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $false)][string]$Payload = '{}',
        [Parameter(Mandatory = $false)][string]$SecretField = 'connectionString',
        [Parameter(Mandatory = $false)][string]$SecretValue = ''
    )

    # Declared here rather than at file scope. These functions are loaded on
    # their own by the Pester suite, which sees function definitions and nothing
    # else, so a file-scope constant reads as $null under test while working in
    # the action -- and `-match $null` is an empty pattern that matches anything.
    #
    # Envelope fields are the action's to set. A payload that overwrote one would
    # make the step name in the Actions log describe a different command than the
    # one that reached the VM.
    $envelopeFields = @('commandId', 'command', 'requestedAtUtc')

    $fields = $null
    if (![string]::IsNullOrWhiteSpace($Payload)) {
        try {
            $fields = $Payload | ConvertFrom-Json
        }
        catch {
            # The payload is assembled by string interpolation in the caller's
            # YAML, so a value carrying a quote lands here rather than being
            # rejected by the VM some minutes later with no clue of its origin.
            throw "The payload is not valid JSON: $($_.Exception.Message)"
        }

        if ($fields -isnot [System.Management.Automation.PSCustomObject]) {
            throw "The payload must be a JSON object, but it parsed as $($fields.GetType().Name)."
        }
    }

    # Not $command: PowerShell variable names are case-insensitive, so that name
    # is the [string]$Command parameter and the dictionary is coerced to a string.
    $queued = [ordered]@{
        commandId = $CommandId
        command   = $Command
    }

    if ($null -ne $fields) {
        foreach ($property in $fields.PSObject.Properties) {
            if ($envelopeFields -contains $property.Name) {
                throw "The payload must not set the envelope field '$($property.Name)'."
            }

            $value = $property.Value
            if ($null -eq $value) {
                continue
            }
            if (($value -is [string]) -and [string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $queued[$property.Name] = $value
        }
    }

    if (![string]::IsNullOrWhiteSpace($SecretValue)) {
        $queued[$SecretField] = $SecretValue
    }

    # Last, and in round-trippable form: the VM orders the queue by this field,
    # and a locale-formatted date sorts lexically wrong.
    $queued['requestedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')

    return $queued
}

function Get-RedactedCommand {
    <#
    .SYNOPSIS
        Returns a copy of a command safe to print into a public Actions log.
    .DESCRIPTION
        Rebuilt key by key rather than regex-scrubbed over the rendered JSON, so
        a password containing a quote cannot leak a fragment past a substitution.
        Two layers, matching Get-RedactedText on the queue agent: the field name,
        then the `password=` keyword as a backstop for a field the name rule
        misses.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]$Command
    )

    # A field whose *name* reads as a secret is redacted whatever it holds. This
    # is the half that has to work for a field name nobody has invented yet; the
    # password keyword below is the half that has to work when this one fails.
    # Local for the same reason as $envelopeFields above.
    $secretNamePattern = '(?i)(connectionstring|password|secret|token|credential)'

    $redacted = [ordered]@{}
    foreach ($key in $Command.Keys) {
        if ($key -match $secretNamePattern) {
            $redacted[$key] = '<redacted>'
            continue
        }

        $value = $Command[$key]
        if ($value -is [string]) {
            $redacted[$key] = [regex]::Replace($value, '(?i)(password\s*=\s*)([^;"''\r\n]+)', '${1}<redacted>')
            continue
        }

        $redacted[$key] = $value
    }

    return $redacted
}

function Assert-ValidQueueName {
    <#
    .SYNOPSIS
        Throws unless the queue name is one that can address a queue.
    .DESCRIPTION
        The name is concatenated into a GCS object path, so a name outside this
        shape writes the command somewhere no agent is polling. That failure is
        silent in the worst direction: the wait runs to its ceiling and reports a
        timeout, which reads as a dead VM rather than a misaddressed command.

        This check used to sit in a `run:` step in three workflows, one copy each,
        and callers that did not think to add it had none. Whoever builds the path
        should be the one to check it, and that is this script. The agent keeps its
        own copy on the far side, which is a different claim: this one says the
        command was addressed correctly, and that one says this VM was asked for
        work meant for it. Neither substitutes for the other.

        Deliberately the same pattern as the agent's. A producer laxer than the
        consumer can queue a command that is accepted here and ignored there.

        `-cnotmatch`, not `-notmatch`. PowerShell matches case-insensitively by
        default, so every copy of this check that existed accepted 'Commands'.
        GCS does not fold case: that command lands in `pr-environments/Commands/`
        while the agent polls `pr-environments/commands/`, and the wait reports a
        timeout for a VM that was healthy and never asked. A lowercase-only
        pattern enforced case-insensitively is the check appearing to work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QueueName
    )

    if ($QueueName -cnotmatch '^[a-z][a-z0-9-]{1,30}$') {
        throw "queue-name must be lowercase letters, digits and hyphens, starting with a letter: '$QueueName'."
    }
}

function Clear-StaleResult {
    <#
    .SYNOPSIS
        Removes a result left behind by an earlier command carrying this same id.
    .DESCRIPTION
        The command id is the whole of a command's identity. await-vm-command acts
        on the first `results/<commandId>.json` it can copy, and it has no way to
        tell this attempt's answer from one already sitting there. Nothing on the
        VM prunes results either: the agent deletes the *command* object when it
        picks the work up and leaves the result for the poller to find.

        So an id that repeats reads as an instant success or an instant failure
        that no VM produced. Every producer now puts github.run_attempt in the id,
        which is what stops the repeat. This is the half that does not depend on
        six workflows each remembering: clear the slot, then fill it.

        A result found here means two commands shared an id, which should not
        happen now. The caller says so in the log rather than passing over it.
    .OUTPUTS
        $true when a stale result was removed, $false when the slot was already
        empty, which is the normal case.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$ResultUri
    )

    gsutil -q stat $ResultUri
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    gsutil -q rm $ResultUri
    if ($LASTEXITCODE -ne 0) {
        # Deliberately fatal. Carrying on would queue the command with the old
        # answer still in place, and the wait would report that answer within
        # seconds while the VM was still working.
        throw "A result for this command id already exists at $ResultUri and could not be removed. The wait that follows would read it as this command's answer."
    }

    return $true
}

# Dot-sourcing this file to test the functions must not run the upload. action.yml
# sets VMQ_INVOKED to a literal; a Pester run does not.
#
# Deliberately not VMQ_BUCKET. Guarding on an input the caller supplies means a
# workflow that resolves `bucket` to an empty string gets a step that exits 0
# having queued nothing, and the failure then surfaces as a wait that times out
# somewhere else. With the marker, the upload below fails where it happened.
if ([string]::IsNullOrWhiteSpace($env:VMQ_INVOKED)) {
    return
}

# The field name is defaulted on New-VmCommand's parameter and nowhere else.
# action.yml defaults the input too, so VMQ_SECRET_FIELD is never blank on a real
# run and this branch only has effect when the script is invoked by hand -- but a
# second literal here is a second place to forget, and one field name drifting
# from another is the exact defect this action was built to stop. Omitting the
# argument lets the parameter default apply rather than restating it.
$arguments = @{
    CommandId   = $env:VMQ_COMMAND_ID
    Command     = $env:VMQ_COMMAND
    Payload     = $env:VMQ_PAYLOAD
    SecretValue = $env:VMQ_SECRET_VALUE
}
if (![string]::IsNullOrWhiteSpace($env:VMQ_SECRET_FIELD)) {
    $arguments.SecretField = $env:VMQ_SECRET_FIELD
}

$queuedCommand = New-VmCommand @arguments

$queuedCommand | ConvertTo-Json -Depth 10 | Out-File -FilePath command.json -Encoding utf8

Get-RedactedCommand -Command $queuedCommand | ConvertTo-Json -Depth 10

Assert-ValidQueueName -QueueName $env:VMQ_QUEUE

$queuePrefix = "gs://$($env:VMQ_BUCKET)/pr-environments/$($env:VMQ_QUEUE)"

if (Clear-StaleResult -ResultUri "$queuePrefix/results/$($env:VMQ_COMMAND_ID).json") {
    Write-Host "::warning::A result for command id $($env:VMQ_COMMAND_ID) was already in the queue and has been removed. Two commands have shared an id."
}

$destination = "$queuePrefix/pending/$($env:VMQ_COMMAND_ID).json"
gsutil cp command.json $destination
if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the command to $destination. The queue never received it, so nothing will run and the wait that follows would report a timeout instead."
}

Write-Host "Queued '$($env:VMQ_COMMAND)' as $($env:VMQ_COMMAND_ID) on queue '$($env:VMQ_QUEUE)'."
