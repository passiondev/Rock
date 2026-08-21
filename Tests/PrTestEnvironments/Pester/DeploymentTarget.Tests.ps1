<#
    Which site a deploy acts on is the single most consequential decision
    Deploy-RockEnvironment.ps1 makes, and until now it was thirty lines of
    top-level script that nothing could call.

    Two of its outcomes are unrecoverable if wrong. Deploying InPlace to the
    wrong path overwrites a live site. Writing the manifest under
    $EnvironmentRoot puts production into the tree the certificate renewal job
    walks -- and that job stops and starts every site it finds a manifest for,
    so a misplaced manifest turns a routine renewal into a production outage.
    The comment in the script has always said "never under $EnvironmentRoot".
    Nothing checked it.

    These run against the shipped function body, loaded by AST so the script
    itself never executes.

    On paths, and why none of these use a drive letter: Join-Path resolves the
    qualifier through the provider, so on a Linux runner `Join-Path 'C:\x' 'y'`
    finds no drive C and returns $null. An assertion written with Windows
    literals then compares $null to $null and passes having checked nothing.
    Every path here is built from $TestDrive for that reason, and every one is
    asserted non-empty before it is compared. It does mean these tests cannot
    speak to Windows path semantics; they check which root a path is composed
    from, which is where the damage lives.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Join-Path $PSScriptRoot '../../../Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name 'Resolve-DeploymentTarget')
}

Describe 'Resolve-DeploymentTarget' {

    BeforeEach {
        # Two roots that must never be confused for one another: the tree the
        # certificate renewal job walks, and the one it does not.
        $script:EnvironmentRoot = Join-Path $TestDrive 'RockTestEnvs'
        $script:EnvironmentPath = Join-Path $script:EnvironmentRoot 'staging'
        $script:BackupRoot = Join-Path $TestDrive 'RockBackups'

        $script:Common = @{
            EnvironmentName = 'staging'
            EnvironmentPath = $script:EnvironmentPath
            BackupRoot      = $script:BackupRoot
        }
    }

    Context 'DedicatedSite' {

        BeforeEach {
            # A dedicated site is derived entirely from its own name. Reaching IIS
            # here would make the decision depend on server state it has no reason
            # to read.
            Mock Get-ItemProperty { throw 'IIS should not be consulted for a dedicated site.' }
        }

        It 'names the IIS site and app pool after the environment' {
            $target = Resolve-DeploymentTarget -Mode 'DedicatedSite' @script:Common

            $target.SiteName | Should -Be 'rock-staging'
            $target.AppPoolName | Should -Be 'rock-staging'
        }

        It 'puts the site inside the environment path' {
            $target = Resolve-DeploymentTarget -Mode 'DedicatedSite' @script:Common

            $target.SitePath | Should -Not -BeNullOrEmpty
            $target.SitePath | Should -Be (Join-Path $script:EnvironmentPath 'site')
        }

        It 'puts the manifest beside the site it describes' {
            $target = Resolve-DeploymentTarget -Mode 'DedicatedSite' @script:Common

            $target.ManifestPath | Should -Not -BeNullOrEmpty
            $target.ManifestPath | Should -Be (Join-Path $script:EnvironmentPath 'env.json')
        }

        It 'never consults IIS' {
            Resolve-DeploymentTarget -Mode 'DedicatedSite' @script:Common

            Should -Not -Invoke Get-ItemProperty
        }

        It 'refuses a TargetSitePath rather than ignoring it' {
            # env-deploy-command.yml forwards targetSitePath whenever the workflow
            # input is non-empty and never checks it against the mode. Dropping it
            # silently means a deploy that lands somewhere other than where its
            # operator asked, and reports success either way.
            { Resolve-DeploymentTarget -Mode 'DedicatedSite' -TargetSitePath 'C:\inetpub\wwwroot' @script:Common } |
                Should -Throw '*TargetSitePath*DedicatedSite*'
        }

        It 'refuses a TargetAppPoolName rather than ignoring it' {
            { Resolve-DeploymentTarget -Mode 'DedicatedSite' -TargetAppPoolName 'Rock' @script:Common } |
                Should -Throw '*TargetAppPoolName*DedicatedSite*'
        }
    }

    Context 'InPlace' {

        BeforeEach {
            # A real directory rather than a mocked Test-Path: Pester builds its
            # mock from the real command's metadata, so a catch-all Test-Path mock
            # also intercepts Pester's own internal calls and fails them on
            # parameter binding. The question under test is whether the directory
            # is there, and $TestDrive can answer that honestly.
            $script:SitePath = Join-Path $TestDrive 'wwwroot'
            New-Item -ItemType Directory -Path $script:SitePath -Force | Out-Null
            $script:MissingPath = Join-Path $TestDrive 'not-a-directory'

            # The IIS: drive is the one thing that cannot exist here.
            Mock Get-ItemProperty { [pscustomobject]@{ Value = 'RockProdPool' } }
        }

        It 'requires a target path, because there is nothing to derive one from' {
            { Resolve-DeploymentTarget -Mode 'InPlace' @script:Common } |
                Should -Throw '*TargetSitePath is required*'
        }

        It 'refuses a target path that is not on the disk' {
            { Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:MissingPath @script:Common } |
                Should -Throw '*does not exist*'
        }

        It 'deploys into the path it was given' {
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath @script:Common

            $target.SitePath | Should -Be $script:SitePath
        }

        It 'uses the IIS site it was named' {
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath `
                -TargetSiteName 'Rock' @script:Common

            $target.SiteName | Should -Be 'Rock'
        }

        It 'asks IIS which app pool fronts the site when none was named' {
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath `
                -TargetSiteName 'Rock' @script:Common

            $target.AppPoolName | Should -Be 'RockProdPool'
            Should -Invoke Get-ItemProperty -Times 1
        }

        It 'prefers an app pool it was named over the one IIS reports' {
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath `
                -TargetSiteName 'Rock' -TargetAppPoolName 'Explicit' @script:Common

            $target.AppPoolName | Should -Be 'Explicit'
            Should -Not -Invoke Get-ItemProperty
        }

        It 'keeps the manifest out of the environment root' {
            # Invoke-PrEnvironmentCertificateRenewal.ps1 walks $EnvironmentRoot and
            # stops and starts every site whose manifest it finds there. A
            # production manifest in that tree makes a routine renewal an outage.
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath @script:Common

            $target.ManifestPath | Should -Not -BeNullOrEmpty
            $target.ManifestPath | Should -Not -BeLike "$($script:EnvironmentRoot)*"
        }

        It 'puts the manifest under the backup root instead' {
            $target = Resolve-DeploymentTarget -Mode 'InPlace' -TargetSitePath $script:SitePath @script:Common

            $target.ManifestPath | Should -Not -BeNullOrEmpty
            $target.ManifestPath | Should -Be (Join-Path (Join-Path $script:BackupRoot 'staging') 'env.json')
        }
    }
}
