<#
    The command object in pending/ is the only thing deciding whether a command
    runs once or runs forever. The agent lists that prefix every sixty seconds and
    takes whatever is there, so a command is retired by being deleted and by
    nothing else.

    Until this suite existed, the agent finished a command like this:

        Write-GcsObjectText -ObjectName $resultObject -Text $resultJson
        Remove-GcsObject -ObjectName $commandObject

    Two statements, no try/catch, under $ErrorActionPreference = 'Stop'. Any failure
    of the first skips the second. The command stays pending, the scheduled task
    fires a minute later, and the same command runs again -- and again, for as long
    as the box is up. On a `deploy-environment` command that means re-extracting the
    site and re-entering migrations on top of a run already in progress.

    A transient 503 is enough to start it. Nothing has to be misconfigured.

    So the write is retried and the delete happens either way. The failure that
    trades down to is the dispatching workflow polling until it times out with no
    result: a false red on work that ran exactly once, which is recoverable by
    reading a log. The behaviour it replaces is not recoverable by anything.

    The claim changed what "retired" means without changing why. A command now
    leaves pending/ for processing/ before it runs, and the processing/ object is
    what stops a second pass from claiming it. So the claim may only go once the
    command is out of pending/: removed while the command is still listed, it
    hands that command straight back to the next pass.

    These tests call the real function with the queue handed to it as a
    transport -- the same hashtable New-GcsQueueTransport builds over GCS --
    because the distinction being asserted, did the delete still
    happen, is invisible to a test that reads source text. They used to shadow
    Write-GcsObjectText and Remove-GcsObject by name; the transport is that same
    edge, passed in rather than shadowed. CommandQueuePass.Tests.ps1 covers the
    poll pass that calls this.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    . (Import-ScriptFunction -Path $script:AgentScript `
            -Name 'Invoke-WithRetry', 'Complete-QueuedCommand')

    $script:CommandObject = 'pr-environments/commands-prod/pending/abc123.json'
    $script:ClaimObject = 'pr-environments/commands-prod/processing/abc123.json'
    $script:ResultObject = 'pr-environments/commands-prod/results/abc123.json'

    # Defined once here and steered by the script-scoped counters below. Redefining
    # a stand-in inside an It leaks it into every It after it, which is its own way
    # of going green while asserting nothing.
    $script:WriteFailuresRemaining = 0
    $script:RemoveFailuresRemaining = @{}
    $script:Written = @()
    $script:Removed = @()
    $script:WriteAttempts = 0
    $script:RemoveAttempts = @()

    # Only the two operations Complete-QueuedCommand uses. If it started reaching
    # for List or Read, the call would fail here on a missing key, which is the
    # point: retiring a command has no business reading the queue.
    $script:Transport = @{
        Write  = {
            param([string]$ObjectName, [string]$Text, [string]$ContentType)

            $script:WriteAttempts++
            if ($script:WriteFailuresRemaining -gt 0) {
                $script:WriteFailuresRemaining--
                throw "simulated GCS 503 on write"
            }
            $script:Written += $ObjectName
        }
        # Failures are counted per object, because the two deletes have to be
        # told apart: which one failed decides whether the other may happen.
        Remove = {
            param([string]$ObjectName)

            $script:RemoveAttempts += $ObjectName
            if ($script:RemoveFailuresRemaining.ContainsKey($ObjectName) -and $script:RemoveFailuresRemaining[$ObjectName] -gt 0) {
                $script:RemoveFailuresRemaining[$ObjectName]--
                throw "simulated GCS 503 on delete"
            }
            $script:Removed += $ObjectName
        }
    }

    function script:Reset-Counters {
        $script:WriteFailuresRemaining = 0
        $script:RemoveFailuresRemaining = @{}
        $script:Written = @()
        $script:Removed = @()
        $script:WriteAttempts = 0
        $script:RemoveAttempts = @()
    }

    function script:Get-RemoveAttemptCount {
        param([string]$ObjectName)

        return @($script:RemoveAttempts | Where-Object { $_ -eq $ObjectName }).Count
    }

    # RetryDelaySeconds 0 throughout: the backoff is real in production and there is
    # nothing to learn from waiting for it here.
    function script:Complete-TestCommand {
        param([int]$Attempts = 3)

        $completionWarnings = @()
        Complete-QueuedCommand -Transport $script:Transport `
            -CommandObjectName $script:CommandObject `
            -ClaimObjectName $script:ClaimObject `
            -ResultObjectName $script:ResultObject `
            -ResultJson '{"status":"success"}' `
            -Attempts $Attempts `
            -RetryDelaySeconds 0 `
            -WarningVariable completionWarnings `
            -WarningAction SilentlyContinue

        $script:Warnings = @($completionWarnings)
    }
}

Describe 'Completing a queued command' {

    BeforeEach {
        Reset-Counters
    }

    It 'writes the result and retires the command' {
        Complete-TestCommand

        $script:Written | Should -Contain $script:ResultObject
        $script:Removed | Should -Contain $script:CommandObject
        $script:Removed | Should -Contain $script:ClaimObject
        $script:WriteAttempts | Should -Be 1 -Because 'a write that worked should not be repeated'
    }

    It 'removes the claim only after the command is out of pending/' {
        Complete-TestCommand

        [array]::IndexOf($script:Removed, $script:ClaimObject) |
            Should -BeGreaterThan ([array]::IndexOf($script:Removed, $script:CommandObject))
    }

    It 'retries a write that fails and then succeeds' {
        $script:WriteFailuresRemaining = 2

        Complete-TestCommand

        $script:WriteAttempts | Should -Be 3
        $script:Written | Should -Contain $script:ResultObject
        $script:Removed | Should -Contain $script:CommandObject
    }

    It 'retires the command even when the result can never be written' {
        # The whole reason this file exists. Before the fix, this case left the
        # command in pending/ and the deploy ran again every minute.
        $script:WriteFailuresRemaining = 99

        Complete-TestCommand

        $script:Written | Should -BeNullOrEmpty
        $script:Removed | Should -Contain $script:CommandObject -Because 'a command that cannot be reported must still not run a second time'
        $script:Removed | Should -Contain $script:ClaimObject
    }

    It 'retries a delete that fails and then succeeds' {
        # The delete is the safety-critical half, so a transient failure there is
        # worth more than one attempt.
        $script:RemoveFailuresRemaining[$script:CommandObject] = 2

        Complete-TestCommand

        Get-RemoveAttemptCount -ObjectName $script:CommandObject | Should -Be 3
        $script:Removed | Should -Contain $script:CommandObject
        $script:Removed | Should -Contain $script:ClaimObject
    }

    It 'keeps the claim, and says so, when the command could not be taken out of pending/' {
        # The one outcome the agent cannot fix by itself. Kept, the claim makes
        # every later pass skip the command; removed, it would hand the command
        # to the next pass to run again. Either way somebody has to clear it.
        $script:RemoveFailuresRemaining[$script:CommandObject] = 99

        Complete-TestCommand -Attempts 2

        $script:Removed | Should -Not -Contain $script:ClaimObject
        Get-RemoveAttemptCount -ObjectName $script:ClaimObject | Should -Be 0
        ($script:Warnings -join ' ') | Should -Match 'will not run again'
        ($script:Warnings -join ' ') | Should -Match 'by hand'
    }

    It 'says so when the claim could not be removed, though the command is retired' {
        $script:RemoveFailuresRemaining[$script:ClaimObject] = 99

        Complete-TestCommand -Attempts 2

        $script:Removed | Should -Contain $script:CommandObject
        ($script:Warnings -join ' ') | Should -Match ([regex]::Escape($script:ClaimObject))
    }

    It 'does not report a result it failed to write' {
        $script:WriteFailuresRemaining = 99

        Complete-TestCommand -Attempts 2

        ($script:Warnings -join ' ') | Should -Match 'result'
    }
}

Describe 'Removing the command object' {

    BeforeAll {
        . (Import-ScriptFunction -Path $script:AgentScript -Name 'Remove-GcsObject', 'Get-GcsErrorStatusCode' `
                -Supplied 'Invoke-GcsRequest', 'BucketName')

        $script:BucketName = 'connect-file-storage'
        $script:DeleteCalls = 0
        $script:NextStatusCode = 0

        function script:Invoke-GcsRequest {
            param([string]$Uri, [string]$Method, $Body, [string]$ContentType)

            $script:DeleteCalls++
            if ($script:NextStatusCode -eq 0) { return $null }

            $exception = [System.Exception]::new("simulated HTTP $script:NextStatusCode")
            $exception | Add-Member -NotePropertyName Response `
                -NotePropertyValue ([pscustomobject]@{ StatusCode = $script:NextStatusCode }) -Force
            throw $exception
        }
    }

    BeforeEach {
        $script:DeleteCalls = 0
        $script:NextStatusCode = 0
    }

    It 'treats an object that is already gone as removed' {
        # Reached by another route -- a hand cleanup, or a second agent. There is
        # nothing left to re-run the command from, so this is success.
        $script:NextStatusCode = 404

        { Remove-GcsObject -ObjectName 'pr-environments/commands-prod/pending/gone.json' } |
            Should -Not -Throw
    }

    It 'reports a delete that was actually refused' {
        # 403 is the shape a scope or IAM problem arrives in, and it is the one case
        # where the command really is still pending and really will run again.
        $script:NextStatusCode = 403

        { Remove-GcsObject -ObjectName 'pr-environments/commands-prod/pending/denied.json' } |
            Should -Throw
    }

    It 'does not swallow a server error into silence' {
        $script:NextStatusCode = 503

        { Remove-GcsObject -ObjectName 'pr-environments/commands-prod/pending/flaky.json' } |
            Should -Throw
    }
}

Describe 'Claiming the command object' {
    # The one GCS call that makes the claim exclusive. A copy to processing/ that
    # only lands where nothing exists yet, so of two passes racing for one
    # command exactly one gets it. A lost race is an answer, not an error; only
    # a call that failed for some other reason is.
    #
    # A copy can also land without its answer reaching the agent. Every later
    # pass would then lose the race to that copy, so the command would never
    # run. The claim carries a token to tell that copy apart from another
    # pass's.

    BeforeAll {
        . (Import-ScriptFunction -Path $script:AgentScript `
                -Name 'Copy-GcsObjectIfAbsent', 'Get-GcsObjectMetadata', 'Get-GcsErrorStatusCode' `
                -Supplied 'Invoke-GcsRequest', 'BucketName')

        $script:BucketName = 'connect-file-storage'

        function script:New-TestGcsError {
            param([int]$StatusCode)

            $exception = [System.Exception]::new("simulated HTTP $StatusCode")
            $exception | Add-Member -NotePropertyName Response `
                -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode }) -Force
            return $exception
        }

        # POST is the copy, and fails with $script:CopyError when that is set.
        # GET reads the destination back, and answers as $script:Destination
        # says: ours, theirs, untagged, absent or unreadable.
        function script:Invoke-GcsRequest {
            param([string]$Uri, [string]$Method = 'GET', $Body, [string]$ContentType)

            $script:Requests += [pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body }

            if ($Method -eq 'POST') {
                $script:SentClaimToken = ($Body | ConvertFrom-Json).metadata.claimToken
                if ($script:CopyError) { throw $script:CopyError }
                return $null
            }

            switch ($script:Destination) {
                'ours' { return [pscustomobject]@{ metadata = [pscustomobject]@{ claimToken = $script:SentClaimToken } } }
                'theirs' { return [pscustomobject]@{ metadata = [pscustomobject]@{ claimToken = 'another-pass' } } }
                'untagged' { return [pscustomobject]@{} }
                'absent' { throw (New-TestGcsError -StatusCode 404) }
                'unreadable' { throw (New-TestGcsError -StatusCode 503) }
            }
            throw "The test did not say what is at the destination."
        }

        function script:Copy-TestClaim {
            Copy-GcsObjectIfAbsent -ObjectName 'pr-environments/commands-prod/pending/abc123.json' `
                -DestinationObjectName 'pr-environments/commands-prod/processing/abc123.json'
        }
    }

    BeforeEach {
        $script:Requests = @()
        $script:CopyError = $null
        $script:SentClaimToken = $null
        $script:Destination = $null
    }

    It 'copies only where nothing exists yet, and says it won' {
        Copy-TestClaim | Should -BeTrue

        $script:Requests.Count | Should -Be 1
        $script:Requests[0].Method | Should -Be 'POST'
        $script:Requests[0].Uri | Should -BeLike '*/b/connect-file-storage/o/pr-environments%2Fcommands-prod%2Fpending%2Fabc123.json/copyTo/b/connect-file-storage/o/pr-environments%2Fcommands-prod%2Fprocessing%2Fabc123.json*'
        $script:Requests[0].Uri | Should -Match 'ifGenerationMatch=0' -Because 'without the precondition both passes win'
    }

    It 'tags each claim with a token of its own' {
        Copy-TestClaim | Out-Null
        $firstToken = $script:SentClaimToken
        Copy-TestClaim | Out-Null

        $firstToken | Should -Not -BeNullOrEmpty
        $script:SentClaimToken | Should -Not -Be $firstToken
    }

    It 'reports a claim another pass already holds as lost' {
        $script:CopyError = New-TestGcsError -StatusCode 412

        Copy-TestClaim | Should -BeFalse
    }

    It 'reports a command that is already gone as lost' {
        # Claimed and taken out of pending/ by another pass between this one's
        # list and its copy.
        $script:CopyError = New-TestGcsError -StatusCode 404

        Copy-TestClaim | Should -BeFalse
    }

    It 'reports a copy that was refused, without reading the destination back' {
        # 403 is a scope or IAM problem: nobody holds the claim, so the command
        # has to stay pending rather than be skipped as somebody else's. A
        # refusal is GCS's answer, so there is nothing to find out by reading.
        $script:CopyError = New-TestGcsError -StatusCode 403

        { Copy-TestClaim } | Should -Throw -ExpectedMessage '*stays in pending/*'
        $script:Requests.Count | Should -Be 1
    }

    It 'counts a copy that landed but whose answer was lost as won' {
        $script:CopyError = New-TestGcsError -StatusCode 503
        $script:Destination = 'ours'

        Copy-TestClaim | Should -BeTrue -Because 'every later pass would lose to this copy, so nothing would ever run the command'
        $script:Requests[1].Method | Should -Be 'GET'
        $script:Requests[1].Uri | Should -BeLike '*/b/connect-file-storage/o/pr-environments%2Fcommands-prod%2Fprocessing%2Fabc123.json?fields=metadata'
    }

    It 'reads the destination back when the connection dropped with no answer at all' {
        $script:CopyError = [System.Net.WebException]::new('The operation has timed out')
        $script:Destination = 'ours'

        Copy-TestClaim | Should -BeTrue
    }

    It 'reports a claim that another pass made while the copy failed as lost' {
        $script:CopyError = New-TestGcsError -StatusCode 503
        $script:Destination = 'theirs'

        Copy-TestClaim | Should -BeFalse
    }

    It 'reports an untagged claim as lost' {
        # An agent from before the token claims without one.
        $script:CopyError = New-TestGcsError -StatusCode 503
        $script:Destination = 'untagged'

        Copy-TestClaim | Should -BeFalse
    }

    It 'does not read a server error as a lost race when nothing landed' {
        $script:CopyError = New-TestGcsError -StatusCode 503
        $script:Destination = 'absent'

        { Copy-TestClaim } | Should -Throw -ExpectedMessage '*stays in pending/*'
    }

    It 'says the claim may be holding the command when it cannot read the destination back' {
        $script:CopyError = New-TestGcsError -StatusCode 503
        $script:Destination = 'unreadable'

        { Copy-TestClaim } | Should -Throw -ExpectedMessage '*pr-environments/commands-prod/processing/abc123.json*nothing will run*'
    }
}

Describe 'Invoke-WithRetry' {

    It 'returns nothing when the action succeeds' {
        $result = Invoke-WithRetry -Action { } -Attempts 3 -RetryDelaySeconds 0

        $result | Should -BeNullOrEmpty
    }

    It 'returns the last error message when every attempt fails' {
        $result = Invoke-WithRetry -Action { throw 'nope' } -Attempts 2 -RetryDelaySeconds 0

        $result | Should -Match 'nope'
    }

    It 'stops as soon as an attempt succeeds' {
        $script:Tries = 0
        Invoke-WithRetry -Action {
            $script:Tries++
            if ($script:Tries -lt 2) { throw 'not yet' }
        } -Attempts 5 -RetryDelaySeconds 0 | Out-Null

        $script:Tries | Should -Be 2
    }
}
