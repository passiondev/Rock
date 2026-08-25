<#
    The deploy timeline is the only record of a production cutover, and until this
    suite existed it was not durable.

    Measured on the staging rehearsal of 2026-08-25 (command
    deploy-staging-32794680054-1): the deploy succeeded, ran 15m24s, and uploaded a
    916-byte log covering the first 2m38s. It stops on the line

        [2026-08-25T01:11:44Z +00:02:38] Stopping app pool rock-staging. The site is offline from here.

    followed by five blank lines and nothing else. Every step after it -- the site
    replace, the ACL grant, the preserved-file restore, the app pool start, the
    health check, "Done." -- executed, because the command reported success and that
    requires reaching the end of the try block. All of it was lost between the job
    and the bucket.

    The cause was not redaction (a literal .Replace guarded on length), the 200000
    character cap (tail-preserving, and the log was 916 bytes), a timeout (1800s
    allowed against a 924s run), a preference change (there is none), a stale script
    (the GCS and repository copies matched on md5), or a second agent instance (both
    objects were metageneration 1, written 256ms apart). It is the job stream itself
    dropping records.

    So these tests do not assert anything about the stream. Write-DeployStep writes
    the timeline to a file on the box, which is ordinary I/O and cannot be dropped by
    whatever the stream is doing, and the agent appends that file to whatever the
    capture gave it. The fix is deliberately indifferent to the mechanism, because
    the mechanism is still unexplained and the production cutover is not waiting on
    an explanation.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name 'Write-DeployStep')

    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    . (Import-ScriptFunction -Path $script:AgentScript -Name 'Get-CommandLogText', 'Get-StepLogPath')

    # Write-DeployStep stamps against this. The tests below read the file, not the
    # clock, so any fixed start will do.
    $script:DeployStartedUtc = (Get-Date).ToUniversalTime()
}

Describe 'Write-DeployStep' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("deploystep-" + [guid]::NewGuid().ToString("n"))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:LogPath = Join-Path $script:TempRoot 'steps.log'
    }

    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'appends the stamped line to the step log' {
        $script:DeployStepLogPath = $script:LogPath
        Write-DeployStep "Stopping app pool rock-staging."

        $script:LogPath | Should -Exist
        (Get-Content $script:LogPath -Raw) | Should -Match 'Stopping app pool rock-staging\.'
    }

    It 'stamps the file line the same way it stamps the host line' {
        $script:DeployStepLogPath = $script:LogPath
        Write-DeployStep "Done."

        # Absolute UTC then elapsed, because the reader is correlating against GCS
        # object times and an IIS log that are in neither local time nor elapsed.
        (Get-Content $script:LogPath -Raw).Trim() |
            Should -Match '^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \+\d{2}:\d{2}:\d{2}\] Done\.$'
    }

    It 'accumulates every step in order rather than overwriting' {
        $script:DeployStepLogPath = $script:LogPath
        Write-DeployStep "first"
        Write-DeployStep "second"
        Write-DeployStep "third"

        $lines = @(Get-Content $script:LogPath)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match 'first'
        $lines[1] | Should -Match 'second'
        $lines[2] | Should -Match 'third'
    }

    It 'still writes the host line when no step log is configured' {
        $script:DeployStepLogPath = $null
        { Write-DeployStep "no file configured" } | Should -Not -Throw
    }

    It 'does not fail the deploy when the step log cannot be written' {
        # An unwritable log is not a reason to abandon a production cutover
        # half-way through, with the app pool already stopped.
        $script:DeployStepLogPath = Join-Path $script:TempRoot 'no-such-directory/steps.log'
        { Write-DeployStep "unwritable" } | Should -Not -Throw
    }
}

Describe 'Get-CommandLogText' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("deploystep-" + [guid]::NewGuid().ToString("n"))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:LogPath = Join-Path $script:TempRoot 'steps.log'
    }

    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns the capture unchanged when there is no step log' {
        Get-CommandLogText -CaptureText 'captured' -StepLogPath $script:LogPath |
            Should -Be 'captured'
    }

    It 'returns the capture unchanged when no step log path was configured' {
        Get-CommandLogText -CaptureText 'captured' -StepLogPath '' | Should -Be 'captured'
    }

    It 'appends the recovered timeline under a marker that says where it came from' {
        Set-Content -Path $script:LogPath -Value "[stamp] Stopping app pool.`n[stamp] Done." -NoNewline

        $merged = Get-CommandLogText -CaptureText 'captured' -StepLogPath $script:LogPath

        $merged | Should -Match 'captured'
        $merged | Should -Match 'deploy timeline'
        $merged | Should -Match 'Done\.'
    }

    It 'keeps the timeline even when the capture came back empty' {
        Set-Content -Path $script:LogPath -Value "[stamp] Done." -NoNewline

        Get-CommandLogText -CaptureText '' -StepLogPath $script:LogPath |
            Should -Match 'Done\.'
    }

    It 'ignores an empty step log rather than appending an empty section' {
        Set-Content -Path $script:LogPath -Value '' -NoNewline

        Get-CommandLogText -CaptureText 'captured' -StepLogPath $script:LogPath |
            Should -Be 'captured'
    }

    It 'returns the capture when the step log cannot be read' {
        # Same reasoning as the deploy side: a log problem must never be reported
        # as a deploy problem.
        Get-CommandLogText -CaptureText 'captured' -StepLogPath (Join-Path $script:TempRoot 'nope/steps.log') |
            Should -Be 'captured'
    }
}

Describe 'Get-StepLogPath' {
    BeforeEach {
        # A real directory rather than C:\RockDeploy. Join-Path resolves the drive,
        # and on a non-Windows runner drive C: does not exist, so a literal Windows
        # root silently returns nothing and every assertion below compares $null to
        # $null. The agent itself only ever runs on Windows, where the idiom is fine.
        $script:DeployRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'RockDeploy'
    }

    It 'drops the pending object''s .json extension rather than burying it mid-name' {
        # $CommandId is still the pending object's file name at the point this is
        # called, so naming from it directly produced the extension mid-name:
        # deploy-staging-1234-1.json-steps.log.
        $path = Get-StepLogPath -DeployRoot $script:DeployRoot -CommandObjectName 'deploy-staging-1234-1.json'

        (Split-Path $path -Leaf) | Should -Be 'deploy-staging-1234-1-steps.log'
    }

    It 'takes the leaf of a fully prefixed object name' {
        $path = Get-StepLogPath -DeployRoot $script:DeployRoot -CommandObjectName 'pr-environments/commands-prod/pending/deploy-prod-99-1.json'

        (Split-Path $path -Leaf) | Should -Be 'deploy-prod-99-1-steps.log'
    }

    It 'keeps the timeline under the deploy root so a reboot cannot clear it' {
        $path = Get-StepLogPath -DeployRoot $script:DeployRoot -CommandObjectName 'anything.json'

        $path | Should -Match 'RockDeploy'
        $path | Should -Match 'logs'
    }

    It 'gives two commands two different files' {
        $first = Get-StepLogPath -DeployRoot $script:DeployRoot -CommandObjectName 'deploy-staging-1.json'
        $second = Get-StepLogPath -DeployRoot $script:DeployRoot -CommandObjectName 'deploy-staging-2.json'

        $first | Should -Not -Be $second
    }
}

Describe 'The dry run plan' {
    BeforeAll {
        $source = Get-Content -Path $script:DeployScript -Raw

        # The dry-run block is the InPlace/-not $Apply guard up to its own `return`.
        # Matched from the source rather than executed: it lives in the script's main
        # body, not in a function, so there is nothing to import and call.
        $script:DryRunBlock = [regex]::Match(
            $source, '(?s)-not \$Apply\) \{(.*?)return').Groups[1].Value
    }

    It 'is where this test thinks it is' {
        $script:DryRunBlock | Should -Not -BeNullOrEmpty
        $script:DryRunBlock | Should -Match 'DRY RUN'
    }

    It 'writes every line of the plan through Write-DeployStep' {
        # A dry run is step 6 of the production runbook -- the one that proves the
        # agent is alive before anybody deploys. The operator reads its plan to
        # confirm the backup root and the site path before ticking apply. Write-Host
        # is exactly what the staging rehearsal proved can vanish between the job and
        # the bucket, so the plan must not depend on it.
        # Comments are excluded deliberately. -match is case-insensitive in
        # PowerShell, so prose about "a dry run" in a comment reads as a plan line
        # and the test fails on its own explanation.
        $planLines = $script:DryRunBlock -split "`n" |
            Where-Object { $_.TrimStart() -notlike '#*' } |
            Where-Object { $_ -cmatch 'DRY RUN|Would ' }

        $planLines.Count | Should -BeGreaterThan 4
        foreach ($line in $planLines) {
            $line | Should -Match 'Write-DeployStep'
        }
    }
}
