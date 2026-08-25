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

    These tests call the real function with the network edge mocked, because the
    distinction being asserted -- did the delete still happen -- is invisible to a
    test that reads source text.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    . (Import-ScriptFunction -Path $script:AgentScript -Name 'Invoke-WithRetry', 'Complete-QueuedCommand')

    $script:CommandObject = 'pr-environments/commands-prod/pending/abc123.json'
    $script:ResultObject = 'pr-environments/commands-prod/results/abc123.json'

    # Defined once here and steered by the script-scoped counters below. Redefining
    # a function inside an It leaks it into every It after it, which is its own way
    # of going green while asserting nothing.
    $script:WriteFailuresRemaining = 0
    $script:RemoveFailuresRemaining = 0
    $script:Written = @()
    $script:Removed = @()
    $script:WriteAttempts = 0
    $script:RemoveAttempts = 0

    function script:Write-GcsObjectText {
        param([string]$ObjectName, [string]$Text, [string]$ContentType)

        $script:WriteAttempts++
        if ($script:WriteFailuresRemaining -gt 0) {
            $script:WriteFailuresRemaining--
            throw "simulated GCS 503 on write"
        }
        $script:Written += $ObjectName
    }

    function script:Remove-GcsObject {
        param([string]$ObjectName)

        $script:RemoveAttempts++
        if ($script:RemoveFailuresRemaining -gt 0) {
            $script:RemoveFailuresRemaining--
            throw "simulated GCS 503 on delete"
        }
        $script:Removed += $ObjectName
    }

    function script:Reset-Counters {
        $script:WriteFailuresRemaining = 0
        $script:RemoveFailuresRemaining = 0
        $script:Written = @()
        $script:Removed = @()
        $script:WriteAttempts = 0
        $script:RemoveAttempts = 0
    }

    # RetryDelaySeconds 0 throughout: the backoff is real in production and there is
    # nothing to learn from waiting for it here.
    function script:Complete-TestCommand {
        param([int]$Attempts = 3)

        Complete-QueuedCommand -CommandObjectName $script:CommandObject `
            -ResultObjectName $script:ResultObject `
            -ResultJson '{"status":"success"}' `
            -Attempts $Attempts `
            -RetryDelaySeconds 0 `
            -WarningAction SilentlyContinue
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
        $script:WriteAttempts | Should -Be 1 -Because 'a write that worked should not be repeated'
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
    }

    It 'retries a delete that fails and then succeeds' {
        # The delete is the safety-critical half, so a transient failure there is
        # worth more than one attempt.
        $script:RemoveFailuresRemaining = 2

        Complete-TestCommand

        $script:RemoveAttempts | Should -Be 3
        $script:Removed | Should -Contain $script:CommandObject
    }

    It 'says so loudly when the command could not be retired' {
        # The one outcome the agent cannot fix by itself. It has to reach a human,
        # because what happens next is the command running again on the next poll.
        $script:RemoveFailuresRemaining = 99

        $warnings = @()
        Complete-QueuedCommand -CommandObjectName $script:CommandObject `
            -ResultObjectName $script:ResultObject `
            -ResultJson '{"status":"success"}' `
            -Attempts 2 `
            -RetryDelaySeconds 0 `
            -WarningVariable warnings `
            -WarningAction SilentlyContinue

        $warnings | Should -Not -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'run again'
    }

    It 'does not report a result it failed to write' {
        $script:WriteFailuresRemaining = 99

        $warnings = @()
        Complete-QueuedCommand -CommandObjectName $script:CommandObject `
            -ResultObjectName $script:ResultObject `
            -ResultJson '{"status":"success"}' `
            -Attempts 2 `
            -RetryDelaySeconds 0 `
            -WarningVariable warnings `
            -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'result'
    }
}

Describe 'Removing the command object' {

    BeforeAll {
        . (Import-ScriptFunction -Path $script:AgentScript -Name 'Remove-GcsObject')

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
