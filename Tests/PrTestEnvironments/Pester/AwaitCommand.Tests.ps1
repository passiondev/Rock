<#
    The wait was 97 lines of PowerShell inlined into
    .github/actions/await-vm-command/action.yml. Nothing could run it. The parse
    job in deployment-pipeline-tests.yml confirmed it had no syntax errors, which
    is a different claim from "it takes the right sixty lines".

    The log tail shows what the gap was. It slices sixty lines off the end for the
    job summary, and the questions worth asking of it are which sixty, in what
    order, and what it does at the boundaries: a log of exactly sixty lines, a
    shorter one, an empty one, one the VM wrote with Windows line endings while
    the runner reading it is Linux. A parse answers none of those. It reports the
    same success for a slice taken off the wrong end.

    The behaviour was right. That was not established by anything, and now it is.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:ActionScript = Get-RepositoryPath '.github/actions/await-vm-command/Await-VmCommand.ps1'
    . (Import-ScriptFunction -Path $script:ActionScript -Name 'Get-PositiveInteger', 'Get-LogTail', 'Show-CommandLog')
}

Describe 'Get-PositiveInteger' {
    It 'parses a count a caller passed as a string' {
        Get-PositiveInteger -Value '140' -Name 'attempts' | Should -Be 140
    }

    It 'rejects a value that is not a number, and names the input' {
        # `[int]'abc'` throws a message naming neither the input nor the action.
        { Get-PositiveInteger -Value 'abc' -Name 'attempts' } |
            Should -Throw -ExpectedMessage "attempts must be a positive whole number; got 'abc'."
    }

    It 'rejects an empty value rather than reading it as zero' {
        # This is the one that mattered. `[int]''` is 0, the poll loop never runs,
        # and the step reports a timeout the VM had nothing to do with.
        { Get-PositiveInteger -Value '' -Name 'attempts' } | Should -Throw
    }

    It 'rejects zero and negatives' {
        { Get-PositiveInteger -Value '0' -Name 'attempts' } | Should -Throw
        { Get-PositiveInteger -Value '-5' -Name 'interval-seconds' } | Should -Throw
    }
}

Describe 'Get-LogTail' {
    It 'returns a short log whole' {
        $log = (1..10 | ForEach-Object { "line $_" }) -join "`n"

        $tail = Get-LogTail -Text $log -MaxLines 60

        $tail.Count | Should -Be 10
        $tail[0] | Should -Be 'line 1'
        $tail[-1] | Should -Be 'line 10'
    }

    It 'returns the last lines of a long log, in order' {
        $log = (1..200 | ForEach-Object { "line $_" }) -join "`n"

        $tail = Get-LogTail -Text $log -MaxLines 60

        $tail.Count | Should -Be 60
        $tail[0] | Should -Be 'line 141'
        $tail[-1] | Should -Be 'line 200'
    }

    It 'reads a log the VM wrote with Windows line endings' {
        # The agent runs on Windows and the runner reading this is Linux.
        $log = "first`r`nsecond`r`nthird"

        $tail = Get-LogTail -Text $log -MaxLines 60

        $tail.Count | Should -Be 3
        $tail[-1] | Should -Be 'third'
    }

    It 'returns one empty line for an empty log rather than throwing' {
        (Get-LogTail -Text '' -MaxLines 60).Count | Should -Be 1
    }

    It 'takes exactly MaxLines when the log is exactly that long' {
        $log = (1..60 | ForEach-Object { "line $_" }) -join "`n"

        $tail = Get-LogTail -Text $log -MaxLines 60

        $tail.Count | Should -Be 60
        $tail[0] | Should -Be 'line 1'
    }
}

Describe 'Show-CommandLog' {
    BeforeAll {
        function gsutil { }
    }

    It 'says so plainly when the VM reported no log' {
        # Older agents set no logObject. That is unremarkable, not an error.
        Mock gsutil { }

        Show-CommandLog -Bucket 'b' -LogObject '' | Should -Be ''
        Should -Invoke gsutil -Times 0 -Exactly
    }

    It 'returns nothing when the log cannot be downloaded' {
        Mock gsutil { $global:LASTEXITCODE = 1 }

        Show-CommandLog -Bucket 'b' -LogObject 'logs/deploy.log' | Should -Be ''
    }

    It 'returns the downloaded log path' {
        Push-Location $TestDrive
        try {
            Mock gsutil {
                Set-Content -Path 'command-output.log' -Value 'the deploy said this'
                $global:LASTEXITCODE = 0
            }

            $path = Show-CommandLog -Bucket 'b' -LogObject 'logs/deploy.log'

            $path | Should -Not -BeNullOrEmpty
            (Get-Content $path -Raw).Trim() | Should -Be 'the deploy said this'
        }
        finally {
            Pop-Location
        }
    }
}
