<#
    The installer and the agent are two files, and the only thing joining them is
    a string. Install-PrEnvironmentCommandQueueTask.ps1 writes the scheduled task's
    command line once, at bootstrap, and that line is then the agent's entire
    invocation for as long as the task exists. Nothing re-reads it and nothing
    validates it: schtasks accepts any string, and PowerShell only objects to an
    unknown parameter when the task first fires, on a box nobody is watching, to a
    stream nothing collects.

    So a parameter renamed on one side and not the other is a silent failure with a
    long fuse. That is the specific risk the -BootstrapPrefix passthrough adds: the
    whole point of it is that production installs with a different value, and an
    installer that spells it wrong would leave production quietly syncing staging's
    scripts -- the exact outcome the parameter exists to prevent, reached through
    the parameter meant to prevent it.

    Both tests here work on the parsed syntax tree rather than by running anything.
    The installer shells out to schtasks.exe, which does not exist off Windows, and
    the agent's first act after its guards is to ask the GCE metadata server for a
    token. Neither is available to this suite, and neither is what is being tested.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    $script:InstallerScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Install-PrEnvironmentCommandQueueTask.ps1'

    function Get-ScriptParameterNames {
        param([string]$Path)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        if ($null -eq $ast.ParamBlock) {
            return @()
        }
        return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    function Get-TaskCommandLine {
        # The source text the installer assigns to $taskCommand: the literal string
        # that becomes the scheduled task's invocation. Read from the syntax tree
        # rather than by regex over the whole file, so a mention of the variable in
        # a comment or a log line cannot be mistaken for the assignment itself.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:InstallerScript, [ref]$null, [ref]$null)

        $assignment = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$taskCommand'
        }, $true) | Select-Object -First 1

        if ($null -eq $assignment) {
            return ''
        }
        return $assignment.Right.Extent.Text
    }
}

Describe 'The scheduled task command line' {

    It 'names only parameters the agent actually has' {
        # The failure this exists for: -BootstrapPrefix on one side and, say,
        # -ScriptPrefix on the other. schtasks stores it, the task fires, PowerShell
        # rejects the argument, and the agent has been dead for a week before the
        # first missed deploy makes anyone look.
        $taskCommand = Get-TaskCommandLine
        $taskCommand | Should -Not -BeNullOrEmpty -Because 'the installer must still build a task command line'

        $named = [regex]::Matches($taskCommand, '\s-([A-Za-z][A-Za-z0-9]*)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notin @('NoProfile', 'ExecutionPolicy', 'File') } |
            Select-Object -Unique

        $named | Should -Not -BeNullOrEmpty -Because 'a task command line that passes nothing is not passing the queue name either'

        $agentParameters = Get-ScriptParameterNames -Path $script:AgentScript
        foreach ($parameter in $named) {
            $agentParameters | Should -Contain $parameter -Because "the installed task passes -$parameter and the agent has no such parameter"
        }
    }

    It 'passes the bootstrap prefix through' {
        # Not covered by the test above: an installer that simply drops the argument
        # names no parameter the agent lacks, so it passes -- and every host installed
        # by it silently runs on the default prefix.
        $taskCommand = Get-TaskCommandLine

        $taskCommand | Should -Match '-QueueName'
        $taskCommand | Should -Match '-BootstrapPrefix'

        Get-ScriptParameterNames -Path $script:InstallerScript |
            Should -Contain 'BootstrapPrefix' -Because 'the installer cannot forward a value nobody can give it'
    }
}

Describe 'The agent bootstrap prefix guard' {

    BeforeAll {
        $script:GuardDeployRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'rock-prefix-guard'

        # The guard sits above every function definition and above the first network
        # call, so a rejected prefix throws before the script can reach the metadata
        # server. A prefix the guard accepts fails later and differently, which is
        # what the accepted case below asserts on.
        function Invoke-AgentWithPrefix {
            param([string]$Prefix)

            # A bucket name that cannot resolve, on purpose. An accepted prefix
            # carries on past the guard into the real poll loop, and pointed at the
            # live bucket that loop would list the staging queue and claim a pending
            # command -- a unit test taking a deploy off the VM that was meant to run
            # it. Failing at the first request is the whole point of the value.
            try {
                & $script:AgentScript -BucketName 'rock-pester-guard-no-such-bucket' `
                    -DeployRoot $script:GuardDeployRoot `
                    -BootstrapPrefix $Prefix 3>$null 4>$null 6>$null | Out-Null
                return $null
            }
            catch {
                return $_.Exception.Message
            }
        }
    }

    It 'accepts the prefix the test VM already runs on' {
        # Back-compat, stated as a test. The installed task on connect-srv-test was
        # written before this parameter existed and keeps running without it, so the
        # default has to stay valid or the box stops refreshing entirely.
        $message = Invoke-AgentWithPrefix -Prefix 'pr-environments/bootstrap/latest/'

        $message | Should -Not -Match 'BootstrapPrefix must'
    }

    It 'accepts the production prefix' {
        $message = Invoke-AgentWithPrefix -Prefix 'pr-environments/bootstrap/prod/'

        $message | Should -Not -Match 'BootstrapPrefix must'
    }

    It 'refuses an empty prefix' {
        # An empty prefix lists the whole bucket, and every object ending in .ps1
        # anywhere in it becomes something this host downloads, parses and runs.
        $message = Invoke-AgentWithPrefix -Prefix ''

        $message | Should -Match 'BootstrapPrefix must'
    }

    It 'refuses a prefix with no trailing slash' {
        # GCS prefixes are string matches, not directories: 'bootstrap/prod' also
        # matches 'bootstrap/prod-old/' and anything else sharing those characters.
        $message = Invoke-AgentWithPrefix -Prefix 'pr-environments/bootstrap/prod'

        $message | Should -Match 'BootstrapPrefix must'
    }

    It 'refuses a prefix outside pr-environments' {
        $message = Invoke-AgentWithPrefix -Prefix 'some-other-place/scripts/'

        $message | Should -Match 'BootstrapPrefix must'
    }

    AfterAll {
        # The agent creates its queue directory as soon as the guards pass, so the
        # two accepted cases leave one behind.
        if (Test-Path $script:GuardDeployRoot) {
            Remove-Item -LiteralPath $script:GuardDeployRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
