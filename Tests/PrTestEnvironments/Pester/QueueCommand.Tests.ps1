<#
    Six workflows put a command on the VM queue. Two of them echo the command
    into a public Actions log, and the command carries a SQL connection string
    with a plaintext password.

    Both echo loops were written as `if ($key -eq 'connectionString')`. The
    deploy producer calls the same secret `sandboxConnectionString`, so had it
    ever grown an echo -- by the ordinary route of copying a sibling that has
    one -- the password would have gone straight into a public log. The queue
    agent on the VM has redacted both names since it was written
    (Invoke-PrEnvironmentCommandQueue.ps1, Get-CommandSecrets). Only the
    workflow half knew one name.

    So this suite is not about tidying six similar steps into one. It is about a
    redaction rule that has to hold for a field name nobody has thought of yet.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:ActionScript = Join-Path $PSScriptRoot '../../../.github/actions/queue-vm-command/Write-VmCommand.ps1'
    . (Import-ScriptFunction -Path $script:ActionScript -Name 'New-VmCommand', 'Get-RedactedCommand')

    $script:Password = 'hunter2-correct-horse'
    $script:ConnectionString = "Data Source=tcp:10.0.0.5,1433;Initial Catalog=RockSandbox;User Id=rock;password=$($script:Password);Encrypt=true;"
}

Describe 'New-VmCommand' {
    It 'puts the envelope round a payload' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{"sha":"deadbeef"}'

        $command.commandId | Should -Be 'abc123'
        $command.command | Should -Be 'deploy'
        $command.sha | Should -Be 'deadbeef'
        $command.requestedAtUtc | Should -Not -BeNullOrEmpty
    }

    It 'stamps requestedAtUtc as a round-trippable UTC instant' {
        # The VM sorts the queue by this field. A locale-formatted date sorts
        # lexically wrong and the queue starts running commands out of order.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{}'

        $parsed = [datetime]::MinValue
        [datetime]::TryParse($command.requestedAtUtc, [ref]$parsed) | Should -BeTrue
        $command.requestedAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'accepts an empty payload' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'renew-certificate' -Payload '{}'

        $command.Keys | Should -Contain 'command'
        $command.command | Should -Be 'renew-certificate'
    }

    It 'treats a blank payload as an empty one' {
        # `payload: ${{ inputs.thing }}` renders to empty when the caller omits
        # it, which is a shape the action sees rather than a hypothetical.
        $command = New-VmCommand -CommandId 'abc123' -Command 'destroy' -Payload '   '

        $command.command | Should -Be 'destroy'
    }

    It 'keeps a number a number' {
        # prNumber reaches the VM as [int] today and Destroy-PrEnvironment.ps1
        # binds it to an [int] parameter.
        $command = New-VmCommand -CommandId 'abc123' -Command 'destroy' -Payload '{"prNumber":1234}'

        # Not -BeOfType [int]: pwsh 7 parses a JSON integer to [long] and Windows
        # PowerShell 5.1 to [int]. The invariant is that it stays a number, because
        # Destroy-PrEnvironment.ps1 binds it to an [int] parameter and a quoted
        # "1234" would arrive as a string.
        $command.prNumber | Should -Not -BeOfType [string]
        $command.prNumber | Should -Be 1234
    }

    It 'keeps a false boolean rather than dropping it' {
        # The VM reads `-contains 'apply' -and $Command.apply`, so present-and-false
        # and absent behave identically. Keeping it means the log shows the decision
        # that was made instead of leaving the reader to infer it from a silence.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy-environment' -Payload '{"apply":false}'

        $command.Keys | Should -Contain 'apply'
        $command.apply | Should -BeFalse
    }

    It 'drops a field whose value is empty' {
        # This is what replaces five copies of
        # `if (![string]::IsNullOrWhiteSpace($env:X)) { $command.x = $env:X }`.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy-environment' -Payload '{"targetSitePath":"","targetSiteName":"   ","mode":"InPlace"}'

        $command.Keys | Should -Not -Contain 'targetSitePath'
        $command.Keys | Should -Not -Contain 'targetSiteName'
        $command.mode | Should -Be 'InPlace'
    }

    It 'drops a null the same way' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{"hostName":null}'

        $command.Keys | Should -Not -Contain 'hostName'
    }

    It 'refuses a payload that is not valid JSON' {
        # The payload is built by string interpolation in the caller's YAML. A
        # value carrying a quote produces broken JSON, and the VM would reject
        # the command minutes later with no clue where it came from.
        { New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{"sha":"dead"beef"}' } |
            Should -Throw '*payload*'
    }

    It 'refuses a payload that is a JSON array' {
        { New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '["sha"]' } |
            Should -Throw '*object*'
    }

    It 'refuses a payload that tries to set the envelope itself' {
        # Otherwise a caller could quietly retarget the verb the action was asked
        # to queue, and the step name in the log would no longer describe the run.
        { New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{"command":"destroy"}' } |
            Should -Throw '*command*'
    }

    It 'places the secret under the field name the caller asked for' {
        # Two live names for one concept: the PR fleet's deploy verb reads
        # sandboxConnectionString, deploy-environment reads connectionString.
        # Renaming either means republishing the queue agent to the VM first.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{}' `
            -SecretField 'sandboxConnectionString' -SecretValue $script:ConnectionString

        $command.sandboxConnectionString | Should -Be $script:ConnectionString
    }

    It 'omits the secret field when no secret was supplied' {
        # Production deploys deliberately carry no connection string, so that the
        # one on the VM is the only one that exists.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy-environment' -Payload '{"mode":"InPlace"}' `
            -SecretField 'connectionString' -SecretValue ''

        $command.Keys | Should -Not -Contain 'connectionString'
    }
}

Describe 'Get-RedactedCommand' {
    It 'redacts the secret field the caller named' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{}' `
            -SecretField 'sandboxConnectionString' -SecretValue $script:ConnectionString

        $redacted = Get-RedactedCommand -Command $command

        ($redacted | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:Password))
    }

    It 'redacts connectionString under its own name too' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy-environment' -Payload '{}' `
            -SecretField 'connectionString' -SecretValue $script:ConnectionString

        $redacted = Get-RedactedCommand -Command $command

        $redacted.connectionString | Should -Be '<redacted>'
    }

    It 'redacts a secret-shaped field name it has never been told about' {
        # The point of the suite. Nobody adds a field called
        # `restoreConnectionString` and remembers to update a redaction loop in
        # a different file.
        foreach ($name in 'restoreConnectionString', 'adminPassword', 'apiToken', 'clientSecret', 'gcpCredential') {
            $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload "{`"$name`":`"$($script:Password)`"}"

            $redacted = Get-RedactedCommand -Command $command

            ($redacted | ConvertTo-Json -Depth 10) |
                Should -Not -Match ([regex]::Escape($script:Password)) -Because "$name reads as a secret"
        }
    }

    It 'matches a secret-shaped field name whatever its casing' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload "{`"SANDBOXCONNECTIONSTRING`":`"$($script:Password)`"}"

        $redacted = Get-RedactedCommand -Command $command

        ($redacted | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:Password))
    }

    It 'still strips a password out of a field that does not read as a secret' {
        # The backstop, and the one that matters, because it is the case where
        # the deny-list has already failed. Mirrors Get-RedactedText on the VM.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload "{`"notes`":`"connecting with $($script:ConnectionString)`"}"

        $redacted = Get-RedactedCommand -Command $command

        $redacted.notes | Should -Not -Match ([regex]::Escape($script:Password))
        $redacted.notes | Should -Match 'password=<redacted>'
    }

    It 'leaves the rest of the command readable' {
        # A redaction that blanks the whole command is safe and useless. The
        # reason these steps echo at all is so a person can see what was queued.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy-environment' -Payload '{"environmentName":"staging","mode":"InPlace"}' `
            -SecretField 'connectionString' -SecretValue $script:ConnectionString

        $redacted = Get-RedactedCommand -Command $command

        $redacted.commandId | Should -Be 'abc123'
        $redacted.command | Should -Be 'deploy-environment'
        $redacted.environmentName | Should -Be 'staging'
        $redacted.mode | Should -Be 'InPlace'
    }

    It 'does not mutate the command it was given' {
        # The caller uploads $command and echoes Get-RedactedCommand $command. In
        # that order, redacting in place would ship `<redacted>` to the VM as the
        # connection string and the deploy would fail on a bad password.
        $command = New-VmCommand -CommandId 'abc123' -Command 'deploy' -Payload '{}' `
            -SecretField 'connectionString' -SecretValue $script:ConnectionString

        $null = Get-RedactedCommand -Command $command

        $command.connectionString | Should -Be $script:ConnectionString
    }

    It 'keeps a number a number through the redaction' {
        $command = New-VmCommand -CommandId 'abc123' -Command 'destroy' -Payload '{"prNumber":1234}'

        $redacted = Get-RedactedCommand -Command $command

        $redacted.prNumber | Should -Be 1234
    }
}
