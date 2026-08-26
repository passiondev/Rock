<#
    What the deploy leaves the staging and production site set to.

    Until 2026-08-26 the deploy set an app pool's runtime version and identity and
    stopped, so every other IIS default stood. Staging measured 16.07s for a first
    request and 0.25s for the next one that day. The machine did not change between
    those two numbers: IIS had ended the worker process after twenty idle minutes
    and the first visitor paid for a whole Rock start.

    These run the function rather than reading it, for the reason
    CertificateSelection.Tests.ps1 gives. A substring assertion can see that
    "idleTimeout" is written down somewhere in the file. It cannot see what value
    reached IIS, and the value is the entire point.

    Set-WarmSiteSettings is separate from Ensure-AppPool so that production can
    reach it. An InPlace deploy updates a site somebody else built, so it never
    calls Ensure-AppPool and never should -- restating a live site's identity is
    not a performance change. The last Context here is the one that holds that
    split in place.

    Deploy-PrEnvironment.ps1 is not covered, and gets none of this. Holding a dozen
    PR pools resident on one 32GB box is not the trade holding one staging pool is.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name 'Set-WarmSiteSettings')
}

Describe 'Set-WarmSiteSettings' {

    BeforeEach {
        # Property name -> value, and a flat ordered log beside it. The log exists
        # for one assertion: that the recycle schedule is cleared before it is
        # added. A hashtable cannot see that, and getting it backwards is the bug
        # that would show up as one 04:00 entry per deploy.
        $script:Applied = @{}
        $script:CallLog = @()

        Mock Test-Path { $true } -ParameterFilter { $Path -like 'IIS:\AppPools\*' }
        Mock Set-ItemProperty {
            $script:Applied[$Name] = $Value
            $script:CallLog += "set:$Name"
        }
        Mock Clear-ItemProperty { $script:CallLog += "clear:$Name" }
        Mock New-ItemProperty { $script:CallLog += "new:$Name" }
    }

    Context 'a pool and a site' {
        BeforeEach {
            Set-WarmSiteSettings -AppPoolName 'Rock-Staging' -SiteName 'Rock'
        }

        It 'never lets the pool shut down for being idle' {
            $script:Applied['processModel.idleTimeout'] | Should -Be ([TimeSpan]::Zero)
        }

        It 'starts the pool without waiting for a visitor to ask' {
            $script:Applied['startMode'] | Should -Be 'AlwaysRunning'
        }

        It 'allows longer to start than a cold Rock start takes' {
            # Measured at 95-107s on 2026-08-26. The IIS default is 90s, which would
            # end the startup AlwaysRunning just asked for and report it as a
            # process that failed rather than as a timeout.
            $script:Applied['processModel.startupTimeLimit'] |
                Should -BeGreaterThan ([TimeSpan]::FromSeconds(107))
        }

        It 'turns off the rolling recycle timer' {
            # Left at its 29-hour default the daily restart walks around the clock
            # and eventually lands mid-service.
            $script:Applied['recycling.periodicRestart.time'] | Should -Be ([TimeSpan]::Zero)
        }

        It 'clears the recycle schedule before adding to it' {
            $cleared = $script:CallLog.IndexOf('clear:recycling.periodicRestart.schedule')
            $added = $script:CallLog.IndexOf('new:recycling.periodicRestart.schedule')

            $cleared | Should -BeGreaterOrEqual 0 -Because 'without the clear, each deploy appends another entry'
            $added | Should -BeGreaterThan $cleared
        }

        It 'recycles at a fixed time outside the hour daylight saving repeats' {
            # Rock warns that a restart inside the repeated hour can run a scheduled
            # job twice, which is why this is 04:00 and not 03:00.
            Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'recycling.periodicRestart.schedule' -and $Value.value -eq '04:00:00'
            }
        }

        It 'asks IIS to warm the application rather than waiting for a request' {
            # AlwaysRunning starts the worker process and leaves the application
            # cold. Preload is the half that runs Application_Start.
            $script:Applied['applicationDefaults.preloadEnabled'] | Should -BeTrue
        }
    }

    Context 'a pool with no site named' {
        It 'configures the pool and asks for no preload' {
            Set-WarmSiteSettings -AppPoolName 'Rock-Staging'

            $script:Applied['startMode'] | Should -Be 'AlwaysRunning'
            $script:Applied['applicationDefaults.preloadEnabled'] | Should -BeNullOrEmpty
        }
    }

    Context 'a preload that the server cannot do' {
        It 'warns and carries on, because a cold start is not a failed deploy' {
            # Application Initialization is a role feature. A rebuilt VM that came
            # up without it should serve a slow first request, not fail the deploy
            # after the artifact is already copied over the live site.
            Mock Set-ItemProperty {
                if ($Name -eq 'applicationDefaults.preloadEnabled') {
                    throw 'The parameter "preloadEnabled" was not found'
                }
                $script:Applied[$Name] = $Value
            }

            { Set-WarmSiteSettings -AppPoolName 'Rock-Staging' -SiteName 'Rock' -WarningAction SilentlyContinue } |
                Should -Not -Throw

            $script:Applied['startMode'] | Should -Be 'AlwaysRunning' -Because 'the pool settings come first and should have landed'
        }
    }

    Context 'a pool that is not there' {
        It 'says so and writes nothing, rather than creating one' {
            # Reached on an InPlace production deploy, where the pool name comes
            # from a parameter. A typo should not mint a second empty pool beside
            # the real one and report success.
            Mock Test-Path { $false } -ParameterFilter { $Path -like 'IIS:\AppPools\*' }

            { Set-WarmSiteSettings -AppPoolName 'Typo' -SiteName 'Rock' -WarningAction SilentlyContinue } |
                Should -Not -Throw

            Should -Invoke Set-ItemProperty -Times 0 -Exactly
            Should -Invoke New-ItemProperty -Times 0 -Exactly
        }
    }
}

Describe 'Which deploy modes reach the warm settings' {

    BeforeAll {
        $script:Source = Get-Content (Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1') -Raw

        $errors = $null
        $tokens = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Source, [ref]$tokens, [ref]$errors)
    }

    It 'calls Set-WarmSiteSettings outside the DedicatedSite branch' {
        # This is the whole reason the function was split out of Ensure-AppPool.
        # Ensure-AppPool and Ensure-Website are called inside `if ($Mode -eq
        # 'DedicatedSite')`, so production -- which deploys InPlace -- never
        # reaches them. A well-meant tidy-up that folds this call back in beside
        # them would leave production exactly as slow as it was, and every test
        # above would still pass.
        $calls = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Set-WarmSiteSettings'
        }, $true)

        @($calls).Count | Should -Be 1 -Because 'one call on the shared path is what reaches both modes'

        $enclosing = $calls[0].Parent
        while ($null -ne $enclosing) {
            if ($enclosing -is [System.Management.Automation.Language.IfStatementAst]) {
                $condition = $enclosing.Clauses[0].Item1.Extent.Text
                $condition | Should -Not -Match "DedicatedSite" -Because 'production deploys InPlace and would be skipped'
            }
            $enclosing = $enclosing.Parent
        }
    }

    It 'still keeps identity out of the InPlace path' {
        # The other half of the split. An InPlace deploy updates a site somebody
        # else built, so restating its app pool identity is not the deploy's call.
        $identityCalls = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Ensure-AppPool', 'Ensure-Website')
        }, $true)

        @($identityCalls).Count | Should -BeGreaterThan 0

        foreach ($call in $identityCalls) {
            $guarded = $false
            $enclosing = $call.Parent
            while ($null -ne $enclosing) {
                if ($enclosing -is [System.Management.Automation.Language.IfStatementAst] -and
                    $enclosing.Clauses[0].Item1.Extent.Text -match 'DedicatedSite') {
                    $guarded = $true
                }
                $enclosing = $enclosing.Parent
            }
            $guarded | Should -BeTrue -Because "$($call.GetCommandName()) must stay inside the DedicatedSite branch"
        }
    }
}
