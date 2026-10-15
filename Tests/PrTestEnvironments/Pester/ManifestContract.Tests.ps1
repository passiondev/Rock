<#
    env.json is a contract between scripts that never call each other.

    Three scripts write it: Deploy-PrEnvironment.ps1 for a PR site,
    Deploy-RockEnvironment.ps1 for staging and production, and
    Stop-PrEnvironment.ps1 when a PR site is stopped. Three read it, each on its
    own schedule: Invoke-PrEnvironmentCleanup.ps1 decides what to stop and destroy,
    Invoke-SandboxRefreshWithPrEnvironments.ps1 decides whose app pool to stop
    under a restore, and Invoke-PrEnvironmentCertificateRenewal.ps1 decides which
    hosts to stop IIS for and request a certificate for. Each side spelled the
    field names and the directory out for itself, and nothing held the two
    spellings together. A writer that renamed a field, or moved the file, would
    have passed every test this repository had.

    So the writers here are the real functions, writing to a simulated disk, and
    the readers are the real functions, reading what was written. No manifest is
    built by hand. Where an assertion does name a field -- cleanup's status and
    prNumber, renewal's hostName -- it is the one the reader's own body reads at
    that point, which the body does outside any function this could lift. A writer
    and a reader that drift apart fail here, because the reader stops finding what
    the writer wrote.

    Why tests and not a schema module both sides import: ADR-0001. The bootstrap
    ships Deployment/PrTestEnvironments/*.ps1 and nothing else, so a module would
    never reach the VM. The contract has to live where it can be checked, and
    that is here.

    The disk is laid out by each script's own parameter defaults, read from its
    param block, because the defaults are what runs. Nothing that starts these
    scripts passes a root: Invoke-PrEnvironmentCommandQueue.ps1 marks
    EnvironmentRoot Unreachable for deploy, stop and renew-certificate, no
    workflow sends deploy-environment's optional roots, and cleanup and the
    sandbox refresh are not queue verbs at all, only run by hand. C:\X\Y maps to
    $TestDrive/C/X/Y by splitting the string, never by Join-Path on a drive
    letter -- on Linux that resolves through a provider with no C: drive and
    returns $null. See DeploymentTarget.Tests.ps1 for the longer version.

    That mapping is what found the reason this suite exists. Renewal's default
    roots used to include C:\RockBackups, where Resolve-DeploymentTarget puts the
    InPlace manifest -- production's -- precisely so renewal would never see it.
    The production bootstrap publishes this whole directory, renewal included, to
    production's queue. A renew-certificate command there would have walked to
    production's manifest, stopped W3SVC for the HTTP-01 challenge, and rebound
    production's https binding.

    Every script is named here, at the call site, as ADR-0004 asks.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:PrDeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-PrEnvironment.ps1'
    $script:EnvironmentDeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    $script:StopScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Stop-PrEnvironment.ps1'
    $script:CleanupScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCleanup.ps1'
    $script:SandboxRefreshScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-SandboxRefreshWithPrEnvironments.ps1'
    $script:RenewalScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCertificateRenewal.ps1'

    function Get-ScriptParameterDefault {
        <#
            .SYNOPSIS
            The default a script's own param block gives one parameter, as a value.

            .DESCRIPTION
            Read from the AST rather than by running the script, because running
            one deploys a website. SafeGetValue evaluates constants and array
            literals and refuses anything else, so a default that became an
            expression -- an environment variable, a computed path -- fails here
            loudly instead of being read as its source text.

            Output is unrolled. A caller wanting a list wraps the call in @(), and
            an empty default comes back as nothing at all.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Name
        )

        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
        if ($parameter.Count -ne 1) {
            throw "$Path declares no script parameter -$Name."
        }
        if ($null -eq $parameter[0].DefaultValue) {
            throw "$Path gives -$Name no default, so there is no root the VM would use without being told."
        }

        return $parameter[0].DefaultValue.SafeGetValue()
    }

    function ConvertTo-SimulatedVmPath {
        <#
            .SYNOPSIS
            Where a Windows path on the VM lands on this suite's simulated disk.

            .DESCRIPTION
            By string splitting, not Join-Path on the drive letter: see the
            header. Two Windows paths that are the same directory map to the same
            place, and two that differ do not, which is the only property the
            suite relies on.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][string]$WindowsPath
        )

        $path = $Root
        foreach ($segment in (($WindowsPath -replace ':', '') -split '\\')) {
            if ([string]::IsNullOrWhiteSpace($segment)) {
                continue
            }
            $path = Join-Path $path $segment
        }
        return $path
    }
}

Describe 'env.json, from the scripts that write it to the scripts that read it' {

    BeforeAll {
        # The writers. Everything they need is a parameter, so -Supplied is empty:
        # what goes into a manifest is what the caller passed, not something read
        # out of the deploy script's scope.
        . (Import-ScriptFunction -Path $script:PrDeployScript -Name 'Write-EnvironmentManifest')
        . (Import-ScriptFunction -Path $script:EnvironmentDeployScript -Name 'Resolve-DeploymentTarget', 'Write-DeploymentManifest')
        . (Import-ScriptFunction -Path $script:StopScript -Name 'Write-StoppedManifest', 'ConvertTo-ManifestHashtable')

        # Every writer stamps its own time. Pinned so the readers' answers can be
        # compared to a date rather than to "some time during this test run".
        # Noon, so the date survives whatever zone the runner is in, and a day
        # past the 12th, so a month/day swap fails to parse instead of passing:
        # pwsh 7's ConvertFrom-Json turns these strings into DateTimes on the way
        # back in, and Get-ManifestActivityUtc re-parses them as text, which
        # Windows PowerShell 5.1 on the VM never has to do.
        Mock Get-Date { $script:Clock }

        $script:PrDeployRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
            -WindowsPath (Get-ScriptParameterDefault -Path $script:PrDeployScript -Name 'EnvironmentRoot')
        $script:StopRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
            -WindowsPath (Get-ScriptParameterDefault -Path $script:StopScript -Name 'EnvironmentRoot')
        $script:EnvironmentDeployRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
            -WindowsPath (Get-ScriptParameterDefault -Path $script:EnvironmentDeployScript -Name 'EnvironmentRoot')
        $script:EnvironmentBackupRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
            -WindowsPath (Get-ScriptParameterDefault -Path $script:EnvironmentDeployScript -Name 'BackupRoot')

        # pr-<n> and <root>\<name> are composed in each script's top-level body,
        # not in a function, so they are spelled here the way the bodies spell
        # them. The readers walk their root recursively, so the leaf directory
        # name is not something any of them depends on.
        $script:Pr14Path = Join-Path $script:PrDeployRoot 'pr-14'
        $script:Pr15Path = Join-Path $script:PrDeployRoot 'pr-15'
        New-Item -ItemType Directory -Path $script:Pr14Path, $script:Pr15Path -Force | Out-Null

        # Pool and site names unlike the ones the readers would derive for
        # themselves. The sandbox refresh falls back to rock-pr-<n> when a
        # manifest carries no pool name, so a manifest written as rock-pr-14
        # would read back correctly whether or not the field was found.
        $script:Clock = [DateTime]::new(2026, 10, 14, 12, 0, 0, [DateTimeKind]::Utc)
        $script:Pr14Manifest = Join-Path $script:Pr14Path 'env.json'
        Write-EnvironmentManifest -Path $script:Pr14Manifest -PrNumber 14 -Sha 'aaaaaaa' `
            -ArtifactGcsPath 'gs://bucket/pr-14.zip' -HostName 'pr-14.example.test' `
            -SiteName 'site-14-as-deployed' -AppPoolName 'pool-14-as-deployed' `
            -EnvironmentPath $script:Pr14Path -SitePath (Join-Path $script:Pr14Path 'site')

        # Deployed in January and stopped in August: the two dates cleanup has to
        # tell apart. Stopped through the stop script's own root, so a stop that
        # looked somewhere other than where the deploy wrote fails to find the
        # manifest rather than quietly writing a second one.
        $script:Clock = [DateTime]::new(2026, 1, 15, 12, 0, 0, [DateTimeKind]::Utc)
        Write-EnvironmentManifest -Path (Join-Path $script:Pr15Path 'env.json') -PrNumber 15 -Sha 'bbbbbbb' `
            -ArtifactGcsPath 'gs://bucket/pr-15.zip' -HostName 'pr-15.example.test' `
            -SiteName 'rock-pr-15' -AppPoolName 'rock-pr-15' `
            -EnvironmentPath $script:Pr15Path -SitePath (Join-Path $script:Pr15Path 'site')

        $script:Clock = [DateTime]::new(2026, 8, 20, 12, 0, 0, [DateTimeKind]::Utc)
        $stopPath = Join-Path $script:StopRoot 'pr-15'
        $script:Pr15Manifest = Join-Path $stopPath 'env.json'
        Write-StoppedManifest -Path $script:Pr15Manifest -PrNumber 15 -SiteName 'rock-pr-15' `
            -AppPoolName 'rock-pr-15' -EnvironmentPath $stopPath

        # Staging, as staging-deploy.yml deploys it: DedicatedSite, at the deploy
        # script's default root.
        $script:Clock = [DateTime]::new(2026, 10, 15, 12, 0, 0, [DateTimeKind]::Utc)
        $stagingPath = Join-Path $script:EnvironmentDeployRoot 'staging'
        $stagingTarget = Resolve-DeploymentTarget -Mode 'DedicatedSite' -EnvironmentName 'staging' `
            -EnvironmentPath $stagingPath -BackupRoot $script:EnvironmentBackupRoot
        New-Item -ItemType Directory -Path (Split-Path -Parent $stagingTarget.ManifestPath) -Force | Out-Null
        Write-DeploymentManifest -Target $stagingTarget -EnvironmentName 'staging' -Mode 'DedicatedSite' `
            -Sha 'ccccccc' -ArtifactGcsPath 'gs://bucket/staging.zip' -HostName 'staging.example.test' `
            -EnvironmentPath $stagingPath
        $script:StagingManifest = $stagingTarget.ManifestPath

        # Production, as production-deploy.yml deploys it: InPlace, sending no
        # backupRoot, so the script's default decides where the manifest goes.
        # The pool is named so Resolve-DeploymentTarget has no reason to ask IIS.
        # The directory is created here because on the VM Invoke-InPlaceOverlay
        # creates it, and that is not under test.
        $script:Clock = [DateTime]::new(2026, 10, 16, 12, 0, 0, [DateTimeKind]::Utc)
        $productionSite = Join-Path $TestDrive 'inetpub-wwwroot'
        New-Item -ItemType Directory -Path $productionSite -Force | Out-Null
        $productionTarget = Resolve-DeploymentTarget -Mode 'InPlace' -EnvironmentName 'production' `
            -EnvironmentPath (Join-Path $script:EnvironmentDeployRoot 'production') `
            -TargetSitePath $productionSite -TargetAppPoolName 'RockProdPool' -BackupRoot $script:EnvironmentBackupRoot
        New-Item -ItemType Directory -Path (Split-Path -Parent $productionTarget.ManifestPath) -Force | Out-Null
        Write-DeploymentManifest -Target $productionTarget -EnvironmentName 'production' -Mode 'InPlace' `
            -Sha 'ddddddd' -ArtifactGcsPath 'gs://bucket/production.zip' -HostName 'production.example.test' `
            -EnvironmentPath (Join-Path $script:EnvironmentDeployRoot 'production')
        $script:ProductionManifest = $productionTarget.ManifestPath
        $script:ProductionSite = $productionSite
    }

    It 'wrote every manifest the readers are about to look for' {
        # Each reader assertion below includes a "does not find" somewhere. A
        # writer that wrote nothing would pass all of those, so the files are
        # proved present first.
        foreach ($manifest in $script:Pr14Manifest, $script:Pr15Manifest, $script:StagingManifest, $script:ProductionManifest) {
            $manifest | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $manifest | Should -BeTrue
        }
    }

    Context 'Invoke-PrEnvironmentCleanup.ps1' {

        BeforeAll {
            # The walk and the stop-or-destroy decision are in the script's body,
            # so what is lifted is the two functions that turn a file into the
            # status, PR number and activity time the body acts on.
            . (Import-ScriptFunction -Path $script:CleanupScript -Name 'ConvertTo-ManifestHashtable', 'Get-ManifestActivityUtc')

            $script:CleanupRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
                -WindowsPath (Get-ScriptParameterDefault -Path $script:CleanupScript -Name 'EnvironmentRoot')

            function Read-CleanupManifest {
                param([Parameter(Mandatory = $true)][string]$Path)
                return ConvertTo-ManifestHashtable -Json (Get-Content -Raw -Path $Path)
            }
        }

        It 'walks the tree PR deploys write into' {
            $script:CleanupRoot | Should -Not -BeNullOrEmpty
            $script:Pr14Manifest.StartsWith($script:CleanupRoot + [IO.Path]::DirectorySeparatorChar) | Should -BeTrue
            $script:Pr15Manifest.StartsWith($script:CleanupRoot + [IO.Path]::DirectorySeparatorChar) | Should -BeTrue
        }

        It 'reads a deployed PR environment as idle since its deploy' {
            $manifest = Read-CleanupManifest -Path $script:Pr14Manifest

            $manifest.prNumber | Should -Be 14
            $manifest.status | Should -Be 'deployed'
            (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-10-14'
        }

        It 'reads a stopped PR environment as idle since its stop, not its deploy' {
            # Cleanup destroys a stopped environment DestroyAfterDays after its
            # activity time. Read from the deploy, this one is seven months idle
            # and goes on the next pass; read from the stop, it has its grace
            # period. Only a manifest the stop script actually merged into can
            # show which one cleanup sees.
            $manifest = Read-CleanupManifest -Path $script:Pr15Manifest

            $manifest.prNumber | Should -Be 15
            $manifest.status | Should -Be 'stopped'
            (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-08-20'
        }

        It 'finds no PR number on staging, so it never stops or destroys it' {
            # Staging sits in the same tree. Cleanup acts only on a manifest with
            # a PR number, and staging's writer has to keep not writing one, or
            # cleanup stops staging after six idle hours.
            $manifest = Read-CleanupManifest -Path $script:StagingManifest

            $manifest.Count | Should -BeGreaterThan 0
            $manifest.ContainsKey('prNumber') | Should -BeFalse
        }
    }

    Context 'Invoke-SandboxRefreshWithPrEnvironments.ps1' {

        BeforeAll {
            . (Import-ScriptFunction -Path $script:SandboxRefreshScript `
                    -Name 'Get-PrEnvironmentManifests', 'ConvertTo-ManifestHashtable' `
                    -Supplied 'EnvironmentRoot')

            $script:EnvironmentRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
                -WindowsPath (Get-ScriptParameterDefault -Path $script:SandboxRefreshScript -Name 'EnvironmentRoot')

            # It says so on the host when it leaves staging alone. Not under test.
            Mock Write-Host { }

            $script:RefreshEnvironments = @(Get-PrEnvironmentManifests)
        }

        It 'finds every PR environment, running or stopped, and nothing else' {
            # Stopped ones too: the refresh restores the catalog every PR site
            # shares, and records which pools were running so it restarts only
            # those. Staging has its own catalog and is left up.
            $numbers = @($script:RefreshEnvironments | ForEach-Object { $_.prNumber } | Sort-Object)

            ($numbers -join ',') | Should -Be '14,15'
        }

        It 'stops the app pool the deploy recorded' {
            $pr14 = @($script:RefreshEnvironments | Where-Object { $_.prNumber -eq 14 })

            $pr14.Count | Should -Be 1
            $pr14[0].appPoolName | Should -BeExactly 'pool-14-as-deployed'
            $pr14[0].siteName | Should -BeExactly 'site-14-as-deployed'
        }
    }

    Context 'Invoke-PrEnvironmentCertificateRenewal.ps1' {

        BeforeAll {
            . (Import-ScriptFunction -Path $script:RenewalScript -Name 'Get-DeployedPrEnvironmentManifests' `
                    -Supplied 'EnvironmentRoot', 'AdditionalManifestRoots')

            # The roots renew-certificate actually runs with. The queue contract
            # gives the agent no way to pass either one, so these defaults are the
            # whole of what renewal searches on any VM that runs it.
            $script:EnvironmentRoot = ConvertTo-SimulatedVmPath -Root $TestDrive `
                -WindowsPath (Get-ScriptParameterDefault -Path $script:RenewalScript -Name 'EnvironmentRoot')
            $script:AdditionalManifestRoots = @(
                Get-ScriptParameterDefault -Path $script:RenewalScript -Name 'AdditionalManifestRoots' |
                    ForEach-Object { ConvertTo-SimulatedVmPath -Root $TestDrive -WindowsPath $_ })

            function Get-RenewalHostName {
                return @(Get-DeployedPrEnvironmentManifests | ForEach-Object { [string]$_.hostName })
            }
        }

        It 'renews a deployed PR environment' {
            Get-RenewalHostName | Should -Contain 'pr-14.example.test'
        }

        It 'renews staging, which is deployed as its own site' {
            Get-RenewalHostName | Should -Contain 'staging.example.test'
        }

        It 'leaves a stopped PR environment alone' {
            # Its host still has a manifest and a DNS name. Requesting a
            # certificate for a site that is not serving would fail the HTTP-01
            # challenge every week.
            Get-RenewalHostName | Should -Not -Contain 'pr-15.example.test'
        }

        It 'never reaches the production manifest at its own defaults' {
            # The reason this suite was written. Resolve-DeploymentTarget puts the
            # InPlace manifest under the backup root so that renewal cannot find
            # it. The production bootstrap ships this script to production's
            # queue, and renewal's defaults used to include that same backup root:
            # a renew-certificate there would have stopped W3SVC on production
            # and rebound its https binding.
            Test-Path -LiteralPath $script:ProductionManifest | Should -BeTrue

            # Staging first, from the same walk, so "not found" cannot be a walk
            # that found nothing at all.
            $hosts = Get-RenewalHostName
            $hosts | Should -Contain 'staging.example.test'
            $hosts | Should -Not -Contain 'production.example.test'
        }

        Context 'when an operator names the backup root by hand' {

            BeforeAll {
                $script:DefaultManifestRoots = $script:AdditionalManifestRoots
                $script:AdditionalManifestRoots = @($script:EnvironmentBackupRoot)

                # The backup root holds each InPlace environment's manifest at
                # <root>\<name>\env.json, beside timestamped copies of the site.
                # A manifest nested inside one of those copies is a stale record,
                # and renewal must not act on it. Made by the real writer and then
                # moved, so its shape is a real manifest's.
                $retiredTarget = Resolve-DeploymentTarget -Mode 'InPlace' -EnvironmentName 'retired' `
                    -EnvironmentPath (Join-Path $script:EnvironmentDeployRoot 'retired') `
                    -TargetSitePath $script:ProductionSite -TargetAppPoolName 'RetiredPool' -BackupRoot $script:EnvironmentBackupRoot
                New-Item -ItemType Directory -Path (Split-Path -Parent $retiredTarget.ManifestPath) -Force | Out-Null
                Write-DeploymentManifest -Target $retiredTarget -EnvironmentName 'retired' -Mode 'InPlace' `
                    -Sha 'eeeeeee' -ArtifactGcsPath 'gs://bucket/retired.zip' -HostName 'retired.example.test' `
                    -EnvironmentPath (Join-Path $script:EnvironmentDeployRoot 'retired')

                $backupCopy = Join-Path (Split-Path -Parent $script:ProductionManifest) '20261001T120000Z-ddddddd'
                New-Item -ItemType Directory -Path $backupCopy -Force | Out-Null
                Move-Item -LiteralPath $retiredTarget.ManifestPath -Destination (Join-Path $backupCopy 'env.json')
            }

            AfterAll {
                $script:AdditionalManifestRoots = $script:DefaultManifestRoots
            }

            It 'finds the InPlace manifest, so the parameter still does what it says' {
                Get-RenewalHostName | Should -Contain 'production.example.test'
            }

            It 'reads one level down and no further' {
                Get-RenewalHostName | Should -Not -Contain 'retired.example.test'
            }
        }
    }
}
