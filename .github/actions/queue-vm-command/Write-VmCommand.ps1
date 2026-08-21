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

# Dot-sourcing this file to test the functions must not run the upload. The
# action sets VMQ_BUCKET; a Pester run does not.
if ([string]::IsNullOrWhiteSpace($env:VMQ_BUCKET)) {
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

$destination = "gs://$($env:VMQ_BUCKET)/pr-environments/$($env:VMQ_QUEUE)/pending/$($env:VMQ_COMMAND_ID).json"
gsutil cp command.json $destination
if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the command to $destination. The queue never received it, so nothing will run and the wait that follows would report a timeout instead."
}

Write-Host "Queued '$($env:VMQ_COMMAND)' as $($env:VMQ_COMMAND_ID) on queue '$($env:VMQ_QUEUE)'."
