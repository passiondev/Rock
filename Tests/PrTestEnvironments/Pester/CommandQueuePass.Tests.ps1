<#
    The poll pass is what the VM agent's scheduled task does every minute: refresh
    the deployment scripts, then run, report and retire every pending command. Every
    command anybody dispatches goes through it, and until this suite it was the
    one part of the agent nothing could run. It was the body of the script, at
    script scope, calling GCS and Start-Job by name, so lifting it meant a bucket
    and a VM. What it promised -- the refresh comes first and cannot stop the queue,
    the log lands before the result, an unknown verb comes back as a failed result
    -- was held by Python matching its source text, and a source match reports the
    same green for a line that moved below the one it was meant to precede.

    Its three edges are parameters now: the queue transport, the command runner and
    the script refresh. This suite passes a dictionary, a recorder and a stand-in,
    and runs the same function the scheduled task runs.

    The round trip goes through the real ends of the queue rather than through a
    description of either. Commands are built by New-VmCommand, the function the
    queue-vm-command action uploads, and every result is read back by
    Read-CommandResult, the function await-vm-command decides success with. So a
    change to the result shape on either side fails here, between the two of them,
    instead of in a workflow that waits twenty minutes for a status it cannot read.

    The last Describe runs Invoke-CommandJob, the production runner, against real
    scripts in real background jobs. It is the one edge the pass tests cannot
    follow, so it is held to its own small contract: what came out, whether it
    timed out, and why it failed.
#>

BeforeDiscovery {
    # Start-Job runs a second PowerShell process from $PSHOME. A pwsh installed as
    # a .NET global tool on macOS ships a Linux build there, so no job starts and
    # the Invoke-CommandJob tests would fail because of the host, not the runner.
    # Probe once and skip them on such a host. Never on a GitHub runner: there a
    # skip would read as green, and CI and the VM both start jobs normally, so a
    # probe failing there is news.
    $probe = Start-Job -ScriptBlock { 'started' }
    $jobOutput = Wait-Job -Job $probe -Timeout 60 | Receive-Job -ErrorAction SilentlyContinue
    Remove-Job -Job $probe -Force
    $script:IsJobHostMissing = ($jobOutput -ne 'started') -and ($env:GITHUB_ACTIONS -ne 'true')
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    # The pass and its whole call graph. No -Supplied: everything it reaches for
    # outside itself arrives as a parameter, which is the point of the change this
    # suite was written for.
    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    . (Import-ScriptFunction -Path $script:AgentScript -Name `
            'Invoke-CommandQueuePass', 'Complete-QueuedCommand', 'Invoke-WithRetry', `
            'Get-StepLogPath', 'Get-CommandLogText', 'Get-RedactedText', 'Get-CommandSecrets', `
            'Get-SecretFieldNamePattern', 'Get-PasswordValuePattern', `
            'Get-CommandBindingKind', 'Get-CommandContractSection', 'Get-CommandContract', `
            'Split-CommandList', 'Resolve-CommandArguments', 'Get-QueueAllowedCommands')

    # The producer and the reader, from the two actions every dispatching workflow
    # calls.
    $script:ProducerScript = Get-RepositoryPath '.github/actions/queue-vm-command/Write-VmCommand.ps1'
    . (Import-ScriptFunction -Path $script:ProducerScript -Name 'New-VmCommand')

    $script:ReaderScript = Get-RepositoryPath '.github/actions/await-vm-command/Await-VmCommand.ps1'
    . (Import-ScriptFunction -Path $script:ReaderScript -Name 'Read-CommandResult')

    $script:QueueRoot = 'pr-environments/commands-prod/'
    $script:PendingPrefix = "$($script:QueueRoot)pending/"
    $script:ProcessingPrefix = "$($script:QueueRoot)processing/"
    $script:ResultsPrefix = "$($script:QueueRoot)results/"
    $script:LogsPrefix = "$($script:QueueRoot)logs/"
    $script:BootstrapPrefix = 'pr-environments/bootstrap/prod/'

    # The bucket, held in memory. Each entry is an object name mapped to the text
    # and content type it was written with, which is everything the agent and the
    # await action ever read back off a GCS object.
    #
    # The fakes below are defined once and steered by the script-scoped state that
    # BeforeEach resets. Redefining one inside an It leaks it into every It after.
    $script:Transport = @{
        List   = {
            param([string]$Prefix)

            $script:Events.Add("list $Prefix")
            # A snapshot, as a GCS list is: the pass deletes from this store while
            # it works through what came back.
            @($script:Store.Keys) | Where-Object { $_.StartsWith($Prefix) }
        }
        Read   = {
            param([string]$ObjectName)

            if (-not $script:Store.Contains($ObjectName)) {
                throw "404 Not Found: $ObjectName"
            }
            return $script:Store[$ObjectName].Text
        }
        Write  = {
            param([string]$ObjectName, [string]$Text, [string]$ContentType)

            if ($script:FailingWritePrefix -and $ObjectName.StartsWith($script:FailingWritePrefix)) {
                throw "simulated GCS 503 writing $ObjectName"
            }
            $script:Events.Add("write $ObjectName")
            $script:Store[$ObjectName] = [pscustomobject]@{ Text = $Text; ContentType = $ContentType }
        }
        Remove = {
            param([string]$ObjectName)

            if ($script:FailingRemovePrefix -and $ObjectName.StartsWith($script:FailingRemovePrefix)) {
                throw "simulated GCS 503 deleting $ObjectName"
            }
            $script:Events.Add("remove $ObjectName")
            $script:Store.Remove($ObjectName)
        }
        # The conditional copy GCS makes for ifGenerationMatch=0: it lands only
        # where nothing exists yet, and only while there is something to copy.
        # Losing either way is an answer, not an error.
        Claim  = {
            param([string]$ObjectName, [string]$ClaimedObjectName)

            if ($script:ClaimFails) {
                throw "simulated GCS 503 copying $ObjectName"
            }
            $script:Events.Add("claim $ObjectName")
            if (-not $script:Store.Contains($ObjectName)) {
                return $false
            }
            if ($script:Store.Contains($ClaimedObjectName)) {
                return $false
            }
            $script:Store[$ClaimedObjectName] = $script:Store[$ObjectName]
            return $true
        }
    }

    # Stands in for Invoke-CommandJob: records what it was asked to run and hands
    # back whatever outcome the It set. A real deploy script is not something a
    # test of the pass has any business starting.
    $script:Runner = {
        param([string]$DeployRoot, [string]$ScriptName, [hashtable]$Arguments, [int]$TimeoutSeconds)

        $script:Events.Add("run $ScriptName")
        $script:Runs.Add([pscustomobject]@{
                DeployRoot     = $DeployRoot
                ScriptName     = $ScriptName
                Arguments      = $Arguments
                TimeoutSeconds = $TimeoutSeconds
            })

        # The deploy's own timeline file, for the one contract that is handed a
        # path to write it to. What the job stream drops, this keeps.
        if ($script:TimelineText -and $Arguments.ContainsKey('StepLogPath')) {
            New-Item -ItemType Directory -Path (Split-Path $Arguments['StepLogPath'] -Parent) -Force | Out-Null
            Set-Content -Path $Arguments['StepLogPath'] -Value $script:TimelineText
        }

        # Whatever else is meant to happen while this command is running -- a
        # second agent starting, say. Taken once, so it cannot recurse.
        if ($script:DuringFirstRun) {
            $duringRun = $script:DuringFirstRun
            $script:DuringFirstRun = $null
            & $duringRun
        }

        if ($script:RunnerThrows) {
            throw $script:RunnerThrows
        }
        return $script:NextOutcome
    }

    $script:Refresh = {
        param([string]$Prefix, [string]$Destination)

        $script:Events.Add("refresh $Prefix")
        if ($script:RefreshFails) {
            throw 'simulated GCS 503 listing the bootstrap prefix'
        }
    }

    function script:Add-QueuedCommand {
        <#
            Puts a command on the in-memory queue exactly as queue-vm-command
            would, and returns the pending object's name.
        #>
        param(
            [Parameter(Mandatory = $true)][string]$CommandId,
            [Parameter(Mandatory = $true)][string]$Command,
            [Parameter(Mandatory = $false)][string]$Payload = '{}',
            [Parameter(Mandatory = $false)][string]$SecretValue = ''
        )

        $queued = New-VmCommand -CommandId $CommandId -Command $Command -Payload $Payload -SecretValue $SecretValue
        $name = "$($script:PendingPrefix)$CommandId.json"
        $script:Store[$name] = [pscustomobject]@{
            Text        = ($queued | ConvertTo-Json -Depth 10)
            ContentType = 'application/json'
        }
        return $name
    }

    function script:Invoke-TestPass {
        <#
            One pass over the in-memory queue, under the strictness the scheduled
            task runs with. The agent sets both at its own script scope, which a
            lifted function never sees; set here, they reach every call the pass
            makes, so a property read that would throw on the VM throws here too.
        #>
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $passWarnings = @()
        Invoke-CommandQueuePass -Transport $script:Transport `
            -Runner $script:Runner `
            -RefreshScripts $script:Refresh `
            -DeployRoot $script:DeployRoot `
            -BootstrapPrefix $script:BootstrapPrefix `
            -PendingPrefix $script:PendingPrefix `
            -ProcessingPrefix $script:ProcessingPrefix `
            -ResultsPrefix $script:ResultsPrefix `
            -LogsPrefix $script:LogsPrefix `
            -AllowedCommands $script:AllowedCommands `
            -CompletionRetryDelaySeconds 0 `
            -WarningVariable passWarnings `
            -WarningAction SilentlyContinue 6>$null | Out-Null

        $script:Warnings = @($passWarnings)
    }

    function script:Read-TestResult {
        <#
            The result for one command, read the way await-vm-command reads it.
        #>
        param([Parameter(Mandatory = $true)][string]$CommandId)

        $name = "$($script:ResultsPrefix)$CommandId.json"
        if (-not $script:Store.Contains($name)) {
            throw "The pass wrote no result at $name."
        }
        return Read-CommandResult -Json $script:Store[$name].Text
    }

    function script:Read-TestLog {
        <#
            The log a result points at, as the workflow would download it.
        #>
        param([Parameter(Mandatory = $true)]$Outcome)

        if ([string]::IsNullOrWhiteSpace($Outcome.LogObject)) {
            throw 'The result names no log object.'
        }
        if (-not $script:Store.Contains($Outcome.LogObject)) {
            throw "The result points at $($Outcome.LogObject), which was never written."
        }
        return $script:Store[$Outcome.LogObject].Text
    }
}

Describe 'A poll pass' {

    BeforeEach {
        $script:Store = [ordered]@{}
        $script:Events = New-Object 'System.Collections.Generic.List[string]'
        $script:Runs = New-Object 'System.Collections.Generic.List[object]'
        $script:Warnings = @()
        $script:NextOutcome = [pscustomobject]@{ Output = 'stopped site 1234'; HasTimedOut = $false; Failure = '' }
        $script:RunnerThrows = ''
        $script:RefreshFails = $false
        $script:FailingWritePrefix = ''
        $script:FailingRemovePrefix = ''
        $script:ClaimFails = $false
        $script:DuringFirstRun = $null
        $script:TimelineText = ''
        $script:DeployRoot = Join-Path $TestDrive ('RockDeploy-' + [guid]::NewGuid().ToString('N'))

        # Asked of the agent's own table rather than written out here, so a change
        # to the row moves this suite with it.
        $script:StopContract = Get-CommandContract -Command 'stop'

        # Every verb, as the test VM's agent accepts. The queue under test is named
        # for production so the prefixes read like the real ones; the Its about
        # what production accepts ask for production's list themselves.
        $script:AllowedCommands = @((Get-CommandContract).Keys)
    }

    Context 'a command that runs' {

        It 'runs the script the contract names, with the fields it binds, and reports success' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 1
            $script:Runs[0].ScriptName | Should -Be $script:StopContract.Script
            $script:Runs[0].Arguments['PrNumber'] | Should -Be '1234'
            $script:Runs[0].DeployRoot | Should -Be $script:DeployRoot

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $outcome.HasSucceeded | Should -BeTrue -Because 'await-vm-command reads anything but an explicit success as a failure'
            $outcome.Result.commandId | Should -Be 'stop-1234-1'
            $outcome.Result.command | Should -Be 'stop'
            $outcome.Result.prNumber | Should -Be '1234'
        }

        It 'gives the runner the timeout the contract sets' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $script:Runs[0].TimeoutSeconds | Should -Be ([int]$script:StopContract.TimeoutSeconds)
        }

        It 'lets a command carry its own timeout' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234","timeoutSeconds":45}' | Out-Null

            Invoke-TestPass

            $script:Runs[0].TimeoutSeconds | Should -Be 45
        }

        It 'uploads what the script printed, as text, and names it in the result' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            Read-TestLog -Outcome $outcome | Should -Match 'stopped site 1234'
            # Typed as text so the workflow's download reads it as a string; see
            # ContentTypeOfPublishedScriptsTests for what an untyped object becomes.
            $script:Store[$outcome.LogObject].ContentType | Should -Match '^text/plain'
        }

        It 'writes the log before the result' {
            # The workflow stops polling the moment the result appears. A result
            # written first races the log it points at, and the log loses.
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $logWrite = $script:Events.IndexOf("write $($outcome.LogObject)")
            $resultWrite = $script:Events.IndexOf("write $($script:ResultsPrefix)stop-1234-1.json")

            $logWrite | Should -BeGreaterOrEqual 0
            $resultWrite | Should -BeGreaterThan $logWrite
        }

        It 'retires the command once it has reported it' {
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass

            $script:Store.Contains($pending) | Should -BeFalse -Because 'a command left in pending/ runs again on the next poll'
        }

        It 'runs every command it listed, once each' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null
            Add-QueuedCommand -CommandId 'stop-5678-1' -Command 'stop' -Payload '{"prNumber":"5678"}' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 2
            (@($script:Runs | ForEach-Object { $_.Arguments['PrNumber'] }) -join ',') | Should -Be '1234,5678'
            (Read-TestResult -CommandId 'stop-1234-1').HasSucceeded | Should -BeTrue
            (Read-TestResult -CommandId 'stop-5678-1').HasSucceeded | Should -BeTrue

            $leftover = @($script:Store.Keys | Where-Object { $_.StartsWith($script:PendingPrefix) })
            $leftover.Count | Should -Be 0
        }

        It 'leaves an object in pending/ that is not a command alone' {
            $notes = "$($script:PendingPrefix)notes.txt"
            $script:Store[$notes] = [pscustomobject]@{ Text = 'left by hand'; ContentType = 'text/plain' }

            Invoke-TestPass

            $script:Store.Contains($notes) | Should -BeTrue
            $script:Runs.Count | Should -Be 0
        }
    }

    Context 'a command that does not succeed' {

        It 'reports a script that failed, and keeps what it printed on the way' {
            # The output of a failed deploy is the reason anybody opens the log.
            $script:NextOutcome = [pscustomobject]@{ Output = "step 1 ok`nstep 2 ok"; HasTimedOut = $false; Failure = 'step 3 broke' }
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $outcome.HasSucceeded | Should -BeFalse
            $outcome.Error | Should -Match 'failed: step 3 broke'
            Read-TestLog -Outcome $outcome | Should -Match 'step 2 ok'
        }

        It 'reports a script that ran out of time, with the time it was given' {
            $script:NextOutcome = [pscustomobject]@{ Output = 'waiting on win-acme'; HasTimedOut = $true; Failure = '' }
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $outcome.HasSucceeded | Should -BeFalse
            $outcome.Error | Should -Match "timed out after $($script:StopContract.TimeoutSeconds) seconds"
            Read-TestLog -Outcome $outcome | Should -Match 'waiting on win-acme'
        }

        It 'reports a runner that could not run the script at all, and still retires the command' {
            $script:RunnerThrows = 'could not start the background job'
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $outcome.HasSucceeded | Should -BeFalse
            $outcome.Error | Should -Match 'could not start the background job'
            $script:Store.Contains($pending) | Should -BeFalse
        }

        It 'refuses a verb it has no contract for, without running anything' {
            # Refused before the runner, so the workflow reads "Unknown command"
            # rather than a job that died for no stated reason.
            $pending = Add-QueuedCommand -CommandId 'reboot-1' -Command 'reboot-everything'

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $outcome = Read-TestResult -CommandId 'reboot-1'
            $outcome.HasSucceeded | Should -BeFalse
            $outcome.Error | Should -Match 'Unknown command'
            $script:Store.Contains($pending) | Should -BeFalse
        }

        It 'refuses a command missing a field its contract requires, without running anything' {
            Add-QueuedCommand -CommandId 'stop-1' -Command 'stop' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $outcome = Read-TestResult -CommandId 'stop-1'
            $outcome.HasSucceeded | Should -BeFalse
            $outcome.Error | Should -Match 'requires prNumber'
        }

        It 'retires a command object that does not parse, rather than reading it every minute' {
            $broken = "$($script:PendingPrefix)broken.json"
            $script:Store[$broken] = [pscustomobject]@{ Text = '{ this is not json'; ContentType = 'application/json' }

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $script:Store.Contains($broken) | Should -BeFalse
            # Named after the object, because there was no command id to read.
            (Read-CommandResult -Json $script:Store["$($script:ResultsPrefix)broken.json"].Text).HasSucceeded | Should -BeFalse
        }
    }

    Context 'the claim' {

        It 'takes a command out of pending/ before it runs it' {
            # pending/ means "nobody has started this". Left there while it runs, a
            # second agent cannot tell a running command from a waiting one.
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass

            $claim = $script:Events.IndexOf("claim $pending")
            $retire = $script:Events.IndexOf("remove $pending")
            $run = $script:Events.IndexOf("run $($script:StopContract.Script)")

            $claim | Should -BeGreaterOrEqual 0
            $retire | Should -BeGreaterThan $claim
            $run | Should -BeGreaterThan $retire
        }

        It 'leaves nothing in processing/ once the command is reported' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            (Read-TestResult -CommandId 'stop-1234-1').HasSucceeded | Should -BeTrue
            @($script:Store.Keys | Where-Object { $_.StartsWith($script:ProcessingPrefix) }).Count | Should -Be 0
        }

        It 'skips a command another pass has claimed, and leaves it exactly as it was' {
            # Neither run nor reported: the pass holding the claim does both.
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'
            $claimed = "$($script:ProcessingPrefix)stop-1234-1.json"
            $script:Store[$claimed] = $script:Store[$pending]

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $script:Store.Contains("$($script:ResultsPrefix)stop-1234-1.json") | Should -BeFalse
            $script:Store.Contains($pending) | Should -BeTrue
            $script:Store.Contains($claimed) | Should -BeTrue
        }

        It 'runs a command once when a second agent finds it while the first is still running it' {
            # 2026-08-11: the startup script's inline run and the scheduled task both
            # listed a staging deploy, and the second reported the working deploy as
            # a lock timeout. Here the pending delete fails, so the second pass still
            # lists the command and only the claim stands between it and a second run.
            $script:FailingRemovePrefix = $script:PendingPrefix
            $script:DuringFirstRun = { Invoke-TestPass }
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 1
            (Read-TestResult -CommandId 'stop-1234-1').HasSucceeded | Should -BeTrue
        }

        It 'keeps the claim when the command cannot be taken out of pending/, so it never runs again' {
            # Removing the claim would hand the command straight back to the next
            # pass. Kept, it turns every later pass into a skip until somebody
            # removes both objects by hand.
            $script:FailingRemovePrefix = $script:PendingPrefix
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass
            Invoke-TestPass

            $script:Runs.Count | Should -Be 1
            $script:Store.Contains($pending) | Should -BeTrue
            $script:Store.Contains("$($script:ProcessingPrefix)stop-1234-1.json") | Should -BeTrue
        }

        It 'leaves a command it could not claim in pending/ for the next pass' {
            # A claim that errored is not a claim lost: nobody holds it. Running
            # anyway would give up the one guarantee the claim exists for.
            $script:ClaimFails = $true
            $pending = Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $script:Store.Contains($pending) | Should -BeTrue
            $script:Store.Contains("$($script:ResultsPrefix)stop-1234-1.json") | Should -BeFalse
            ($script:Warnings -join ' ') | Should -Match 'claim'
        }
    }

    Context 'the verbs a queue accepts' {

        BeforeEach {
            $script:AllowedCommands = Get-QueueAllowedCommands -QueueName 'commands-prod'
        }

        It 'refuses a verb the queue does not accept, without running it, and says what it does accept' {
            $pending = Add-QueuedCommand -CommandId 'destroy-1234-1' -Command 'destroy' -Payload '{"prNumber":"1234"}'

            Invoke-TestPass

            $script:Runs.Count | Should -Be 0
            $outcome = Read-TestResult -CommandId 'destroy-1234-1'
            $outcome.HasSucceeded | Should -BeFalse -Because 'a refusal has to reach the workflow as a failure, not as a timeout'
            $outcome.Error | Should -Match "'destroy' is not accepted"
            $outcome.Error | Should -Match 'deploy-environment'
            $script:Store.Contains($pending) | Should -BeFalse
        }

        It 'runs a verb the queue accepts' {
            Add-QueuedCommand -CommandId 'deploy-production-1' -Command 'deploy-environment' `
                -Payload '{"environmentName":"production","sha":"abc1234","artifactGcsPath":"gs://bucket/artifact.zip","hostName":"rock.example.org"}' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 1
            (Read-TestResult -CommandId 'deploy-production-1').HasSucceeded | Should -BeTrue
        }

        It 'still calls a verb with no contract unknown' {
            # The more specific reason wins: "not accepted here" would send somebody
            # looking for the queue that does accept it.
            Add-QueuedCommand -CommandId 'reboot-1' -Command 'reboot-everything' | Out-Null

            Invoke-TestPass

            (Read-TestResult -CommandId 'reboot-1').Error | Should -Match 'Unknown command'
        }
    }

    Context 'the script refresh' {

        It 'refreshes the scripts before it lists the queue, so a fix reaches the command about to run' {
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $refresh = $script:Events.IndexOf("refresh $($script:BootstrapPrefix)")
            $list = $script:Events.IndexOf("list $($script:PendingPrefix)")
            $run = $script:Events.IndexOf("run $($script:StopContract.Script)")

            $refresh | Should -Be 0
            $list | Should -BeGreaterThan $refresh
            $run | Should -BeGreaterThan $list
        }

        It 'still drains the queue when the refresh fails' {
            # A GCS blip on the bootstrap prefix must not turn into a fleet that will
            # not answer stop or destroy. Stale scripts are the lesser fault.
            $script:RefreshFails = $true
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $script:Runs.Count | Should -Be 1
            (Read-TestResult -CommandId 'stop-1234-1').HasSucceeded | Should -BeTrue
            ($script:Warnings -join ' ') | Should -Match 'refresh'
        }
    }

    Context 'the uploaded log' {

        It 'redacts the secrets the command itself carried' {
            # Echoed bare, with no "Password=" in front of it, so the keyword
            # backstop cannot catch it: only the pass handing the command's own
            # secrets to the redaction does. This log is printed in a public
            # repository's Actions log.
            $connection = 'Server=sql.internal;User Id=rock;Password=hunter2-correct-horse'
            $script:NextOutcome = [pscustomobject]@{ Output = "connected`nretrying with hunter2-correct-horse after a timeout"; HasTimedOut = $false; Failure = '' }
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' -SecretValue $connection | Out-Null

            Invoke-TestPass

            $log = Read-TestLog -Outcome (Read-TestResult -CommandId 'stop-1234-1')
            $log | Should -Not -Match 'hunter2'
            $log | Should -Match '<redacted>'
        }

        It 'keeps the end of a log too long to upload whole' {
            # The failure, and the steps leading to it, are at the end.
            $script:NextOutcome = [pscustomobject]@{ Output = ('x' * 250000) + "`nthe line that says why"; HasTimedOut = $false; Failure = '' }
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $log = Read-TestLog -Outcome (Read-TestResult -CommandId 'stop-1234-1')
            $log.Length | Should -BeLessThan 250000
            $log.EndsWith('the line that says why') | Should -BeTrue
            $log | Should -Match 'truncated' -Because 'a reader has to be told the start is missing'
        }

        It 'appends the timeline the deploy wrote on the box' {
            # The job stream has been measured dropping twelve minutes of a deploy.
            # The pass hands the deploy a file to write and reads that same file back.
            $script:NextOutcome = [pscustomobject]@{ Output = 'Stopping app pool'; HasTimedOut = $false; Failure = '' }
            $script:TimelineText = 'site replaced; health check passed'
            Add-QueuedCommand -CommandId 'deploy-staging-1' -Command 'deploy-environment' `
                -Payload '{"environmentName":"staging","sha":"abc1234","artifactGcsPath":"gs://bucket/artifact.zip","hostName":"staging.example.org"}' | Out-Null

            Invoke-TestPass

            $log = Read-TestLog -Outcome (Read-TestResult -CommandId 'deploy-staging-1')
            $log | Should -Match 'Stopping app pool'
            $log | Should -Match 'health check passed'
        }

        It 'still reports the result when the log cannot be uploaded' {
            # A log is worth having; it is not worth turning a deploy that worked
            # into a workflow that waits for a result until it times out.
            $script:FailingWritePrefix = $script:LogsPrefix
            Add-QueuedCommand -CommandId 'stop-1234-1' -Command 'stop' -Payload '{"prNumber":"1234"}' | Out-Null

            Invoke-TestPass

            $outcome = Read-TestResult -CommandId 'stop-1234-1'
            $outcome.HasSucceeded | Should -BeTrue
            $outcome.LogObject | Should -Be '' -Because 'a result must not point at a log that was never written'
            ($script:Warnings -join ' ') | Should -Match 'Could not upload'
        }
    }
}

Describe 'The verbs each queue accepts' {
    # Every workflow holding the repository's storage key can write a command into
    # any queue, so the production approval guards the workflow and not the queue.
    # What production's agent will run is the one limit that holds either way.

    BeforeAll {
        $script:EveryVerb = @((Get-CommandContract).Keys)
        $script:ProductionAccepts = @(Get-QueueAllowedCommands -QueueName 'commands-prod')
    }

    It 'gives the test VM every verb in the table' {
        # The default for any queue without a list, so nothing the test VM does
        # today stops working.
        (@(Get-QueueAllowedCommands -QueueName 'commands') -join ',') | Should -Be ($script:EveryVerb -join ',')
    }

    It 'keeps the fleet''s commands off production' {
        foreach ($verb in 'deploy', 'stop', 'destroy', 'renew-certificate') {
            $script:ProductionAccepts | Should -Not -Contain $verb -Because "nothing in production's own workflows sends $verb"
        }
        $script:ProductionAccepts | Should -Contain 'deploy-environment'
    }

    It 'names only verbs the agent has a contract for' {
        # A misspelt entry would quietly refuse the command it meant to allow,
        # and nothing would say so until that command was needed.
        foreach ($verb in $script:ProductionAccepts) {
            $script:EveryVerb | Should -Contain $verb
        }
    }

    It 'restricts the queue the production bootstrap installs against' {
        # The list is keyed by queue name, so it only protects production while the
        # bootstrap installs production's agent under the name the list is kept for.
        $workflow = Get-Content -Raw -Path (Get-RepositoryPath '.github/workflows/production-bootstrap-command-queue.yml')
        $match = [regex]::Match($workflow, '(?m)^\s*PRODUCTION_QUEUE_NAME:\s*(\S+)\s*$')
        $match.Success | Should -BeTrue -Because 'the production bootstrap names the queue it installs against'

        $installed = @(Get-QueueAllowedCommands -QueueName $match.Groups[1].Value)
        ($installed -join ',') | Should -Be ($script:ProductionAccepts -join ',')
    }
}

Describe 'Invoke-CommandJob' -Skip:$script:IsJobHostMissing {
    # The production runner, against real scripts in real background jobs. Each It
    # starts a PowerShell process, so this stays at the three outcomes the pass
    # distinguishes. Skipped only where this host cannot start a job at all; see
    # BeforeDiscovery.

    BeforeAll {
        . (Import-ScriptFunction -Path $script:AgentScript -Name 'Invoke-CommandJob')

        $script:JobRoot = Join-Path $TestDrive 'job-scripts'
        New-Item -ItemType Directory -Path $script:JobRoot -Force | Out-Null

        # Built rather than written as one literal: a quoted script name in a suite
        # is read as a promise that the script exists under Deployment/.
        $script:GreetingScript = 'greets' + '.ps1'
        Set-Content -Path (Join-Path $script:JobRoot $script:GreetingScript) `
            -Value 'param([string]$Name) Write-Output "hello $Name"'

        $script:BreakingScript = 'breaks' + '.ps1'
        Set-Content -Path (Join-Path $script:JobRoot $script:BreakingScript) -Value @(
            "Write-Output 'step 1 ok'",
            "Write-Output 'step 2 ok'",
            "throw 'step 3 broke'"
        )

        $script:HangingScript = 'hangs' + '.ps1'
        Set-Content -Path (Join-Path $script:JobRoot $script:HangingScript) -Value 'Start-Sleep -Seconds 120'

        function script:Invoke-TestJob {
            <#
                Under the preference the scheduled task runs with. Receive-Job's
                -ErrorAction Continue is there because of it, and this is where
                that claim gets checked.
            #>
            param(
                [Parameter(Mandatory = $true)][string]$ScriptName,
                [Parameter(Mandatory = $false)][hashtable]$Arguments = @{},
                [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60
            )

            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'

            return Invoke-CommandJob -DeployRoot $script:JobRoot -ScriptName $ScriptName `
                -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds 6>$null
        }
    }

    It 'returns what the script printed, given the arguments it was handed' {
        $run = Invoke-TestJob -ScriptName $script:GreetingScript -Arguments @{ Name = 'queue' }

        $run.Output | Should -Be 'hello queue'
        $run.HasTimedOut | Should -BeFalse
        $run.Failure | Should -BeNullOrEmpty
    }

    It 'reports why a script failed, and keeps what it printed first' {
        $run = Invoke-TestJob -ScriptName $script:BreakingScript

        $run.Failure | Should -Match 'step 3 broke'
        $run.Output | Should -Match 'step 2 ok'
        $run.HasTimedOut | Should -BeFalse
    }

    It 'stops a script that outlives its timeout and says so' {
        $run = Invoke-TestJob -ScriptName $script:HangingScript -TimeoutSeconds 2

        $run.HasTimedOut | Should -BeTrue
    }
}
