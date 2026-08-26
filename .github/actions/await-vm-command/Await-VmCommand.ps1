<#
.SYNOPSIS
    Polls for a queued VM command's result, prints what the VM reported, and sets
    the step's exit code from it.

.DESCRIPTION
    This is a script rather than PowerShell inlined into action.yml for the same
    reason Write-VmCommand.ps1 is. PowerShell embedded in YAML is a string that
    nothing can run until a runner expands it, so the only check it ever got was
    a parse from .github/scripts/extract-powershell-blocks.py. Parsing is not
    running: it says the log tail slices without an error, and says nothing about
    which sixty lines it takes.

    The three functions below are the parts with a wrong answer available to
    them. Tests/PrTestEnvironments/Pester/AwaitCommand.Tests.ps1 executes them.

    Kept to Windows PowerShell 5.1 syntax, matching its sibling.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-PositiveInteger {
    <#
    .SYNOPSIS
        Parses a count that has to be a positive whole number.
    .DESCRIPTION
        Parsed, not cast. A workflow_dispatch input is a string whatever its
        declared type, and two callers pass one straight through. `[int]'abc'`
        throws a message naming neither the input nor the action, and `[int]''`
        is 0, which turns the poll into a loop that never runs and then reports a
        timeout the VM had nothing to do with.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 1) {
        throw "$Name must be a positive whole number; got '$Value'."
    }

    return $parsed
}

function Get-LogTail {
    <#
    .SYNOPSIS
        The last lines of a log, for the job summary.
    .DESCRIPTION
        The summary has a size limit and the failure is at the end, so only the
        tail goes in. Splitting on `\r?\n` rather than trusting the VM's line
        endings: the agent runs on Windows and the runner reading this is Linux.
    .OUTPUTS
        An array of lines. A log shorter than MaxLines comes back whole.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $false)][int]$MaxLines = 60
    )

    $lines = @($Text -split "`r?`n")
    if ($lines.Count -le $MaxLines) {
        return $lines
    }

    return $lines[-$MaxLines..-1]
}

function Show-CommandLog {
    <#
    .SYNOPSIS
        Downloads the VM's output log, prints it, and optionally appends its tail
        to the job summary.
    .DESCRIPTION
        The command's own output lives on the VM. The agent uploads a redacted
        copy beside the result so a failure can be diagnosed from this log rather
        than over RDP. Older agents set no logObject, so a missing log is
        unremarkable rather than an error.
    .OUTPUTS
        The workspace path of the downloaded log, or an empty string when there
        was none to download. The caller publishes it as the log-path output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$LogObject = '',
        [Parameter(Mandatory = $false)][switch]$AppendToSummary
    )

    if ([string]::IsNullOrWhiteSpace($LogObject)) {
        Write-Host "The VM reported no output log. If this persists, re-run the bootstrap workflow so the VM picks up the current queue agent."
        return ''
    }

    $logUri = "gs://$Bucket/$LogObject"
    gsutil -q cp $logUri command-output.log 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not download the command output from $logUri."
        return ''
    }

    $logText = Get-Content command-output.log -Raw
    Write-Host "::group::Command output from the VM"
    Write-Host $logText
    Write-Host "::endgroup::"

    if ($AppendToSummary -and $env:GITHUB_STEP_SUMMARY) {
        $tail = Get-LogTail -Text $logText
        "<details><summary>Command output from the VM (last $($tail.Count) lines)</summary>" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        "" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        "``````" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        ($tail -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        "``````" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        "</details>" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
    }

    return (Resolve-Path command-output.log).Path
}

# Dot-sourcing this file to test the functions must not start polling. action.yml
# sets AWAIT_INVOKED to a literal; a Pester run does not.
#
# Deliberately not AWAIT_BUCKET. Guarding on an input the caller supplies means a
# workflow that resolves `bucket` to an empty string gets a step that exits 0
# having polled nothing, which the job reads as the VM command succeeding. With
# the marker, an empty bucket builds gs:///... , every cp fails, and the loop ends
# on the timeout error below.
if ([string]::IsNullOrWhiteSpace($env:AWAIT_INVOKED)) {
    return
}

$bucket = $env:AWAIT_BUCKET
$label = $env:AWAIT_LABEL

$attempts = Get-PositiveInteger -Value $env:AWAIT_ATTEMPTS -Name 'attempts'
$interval = Get-PositiveInteger -Value $env:AWAIT_INTERVAL -Name 'interval-seconds'

$resultUri = "gs://$bucket/pr-environments/$($env:AWAIT_QUEUE)/results/$($env:AWAIT_COMMAND_ID).json"

for ($i = 0; $i -lt $attempts; $i++) {
    gsutil -q cp $resultUri result.json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $result = Get-Content result.json -Raw | ConvertFrom-Json
        $result | ConvertTo-Json -Depth 10

        $logObject = ''
        if ($result.PSObject.Properties.Name -contains 'logObject') {
            $logObject = [string]$result.logObject
        }

        if ($result.status -eq 'succeeded') {
            $logPath = Show-CommandLog -Bucket $bucket -LogObject $logObject
            "log-path=$logPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
            exit 0
        }

        $hint = if ([string]::IsNullOrWhiteSpace($env:AWAIT_FAILURE_HINT)) { '' } else { " $($env:AWAIT_FAILURE_HINT)" }
        Write-Host "::error::$label failed on the VM: $($result.error)$hint"
        if ($env:GITHUB_STEP_SUMMARY) {
            "### $label failed" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            "" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            "``````" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            "$($result.error)" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            "``````" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            "" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
        }
        $logPath = Show-CommandLog -Bucket $bucket -LogObject $logObject -AppendToSummary
        "log-path=$logPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        exit 1
    }
    Start-Sleep -Seconds $interval
}

# No result object at all means the queue worker never ran: the VM is off, the
# scheduled task is missing, or its service account lost bucket access. Say so,
# because "timed out" alone sends people to the wrong place.
Write-Host "::error::No result for $label after $($attempts * $interval) seconds. Check that $bucket is reachable and that the 'Rock PR Environment Command Queue' scheduled task is running on the target VM against queue '$($env:AWAIT_QUEUE)'."
exit 1
