<#
    What the deploy leaves the staging and production app pool set to.

    Until 2026-08-26 Ensure-AppPool set the runtime version and the identity and
    stopped, so every other IIS default stood. Staging measured 16.07s for a first
    request and 0.25s for the next one that day. The machine did not change between
    those two numbers: IIS had ended the worker process after twenty idle minutes
    and the first visitor paid for a whole Rock start.

    These run the function rather than reading it, for the reason
    CertificateSelection.Tests.ps1 gives. A substring assertion can see that
    "idleTimeout" is written down somewhere in the file. It cannot see what value
    reached IIS, and the value is the entire point.

    Deploy-PrEnvironment.ps1 has its own Ensure-AppPool and is not covered here.
    That is deliberate and the divergence is on purpose -- holding a dozen PR pools
    resident on one 32GB box is not the same trade as holding one staging pool
    resident. If the PR fleet ever adopts these settings, it needs its own file.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name 'Ensure-AppPool', 'Ensure-Website')

    # The IIS cmdlets ship with the WebAdministration module on Windows and are
    # absent on the Linux runner these tests gate pull requests from. Pester only
    # mocks a command it can resolve, so stubs stand in. None is ever called
    # through to: every test that reaches one mocks it.
    # Each stub declares the real parameter names. A stub that swallowed them into
    # ValueFromRemainingArguments would leave $Protocol unbound inside the mock
    # bodies below, and the mock would answer every call the same way -- which is
    # a test that passes while exercising one branch.
    if (-not (Get-Command New-WebAppPool -ErrorAction SilentlyContinue)) {
        function global:New-WebAppPool {
            param([string]$Name)
            throw 'stub: this should always be mocked'
        }
    }
    if (-not (Get-Command New-Website -ErrorAction SilentlyContinue)) {
        function global:New-Website {
            param([string]$Name, [string]$PhysicalPath, [string]$ApplicationPool, [int]$Port, [string]$HostHeader)
            throw 'stub: this should always be mocked'
        }
    }
    if (-not (Get-Command Get-WebBinding -ErrorAction SilentlyContinue)) {
        function global:Get-WebBinding {
            param([string]$Name, [string]$Protocol)
            throw 'stub: this should always be mocked'
        }
    }
    if (-not (Get-Command New-WebBinding -ErrorAction SilentlyContinue)) {
        function global:New-WebBinding {
            param([string]$Name, [string]$Protocol, [int]$Port, [string]$HostHeader, [int]$SslFlags)
            throw 'stub: this should always be mocked'
        }
    }

    # Defined in the deploy script, not lifted, because these tests are about the
    # site and pool settings and not about which certificate wins.
    function global:Get-EnvironmentCertificateThumbprint {
        param([string]$HostHeader, [string]$Thumbprint)
        throw 'stub: this should always be mocked'
    }

    function script:New-FakeBinding {
        param([string]$BindingInformation)

        $binding = [pscustomobject]@{ bindingInformation = $BindingInformation }
        $binding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value { param($Thumbprint, $Store) }
        return $binding
    }
}

Describe 'Ensure-AppPool' {

    BeforeEach {
        # Property name -> value, and a flat ordered log beside it. The log exists
        # for one assertion: that the recycle schedule is cleared before it is
        # added. A hashtable cannot see that, and getting it backwards is the bug
        # that would show up as one 04:00 entry per deploy.
        $script:Applied = @{}
        $script:CallLog = @()

        Mock Test-Path { $true } -ParameterFilter { $Path -like 'IIS:\AppPools\*' }
        Mock New-WebAppPool { }
        Mock Set-ItemProperty {
            $script:Applied[$Name] = $Value
            $script:CallLog += "set:$Name"
        }
        Mock Clear-ItemProperty { $script:CallLog += "clear:$Name" }
        Mock New-ItemProperty { $script:CallLog += "new:$Name" }

        Ensure-AppPool -Name 'Rock-Staging'
    }

    It 'keeps the two settings it already had' {
        $script:Applied['managedRuntimeVersion'] | Should -Be 'v4.0'
        $script:Applied['processModel.identityType'] | Should -Be 'ApplicationPoolIdentity'
    }

    It 'never lets the pool shut down for being idle' {
        $script:Applied['processModel.idleTimeout'] | Should -Be ([TimeSpan]::Zero)
    }

    It 'starts the pool without waiting for a visitor to ask' {
        $script:Applied['startMode'] | Should -Be 'AlwaysRunning'
    }

    It 'allows longer to start than a cold Rock start takes' {
        # Measured at 95-107s on 2026-08-26. The IIS default is 90s, which would end
        # the startup AlwaysRunning just asked for and report it as a failure.
        $script:Applied['processModel.startupTimeLimit'] |
            Should -BeGreaterThan ([TimeSpan]::FromSeconds(107))
    }

    It 'turns off the rolling recycle timer' {
        # Left at its 29-hour default the daily restart walks around the clock and
        # eventually lands mid-service.
        $script:Applied['recycling.periodicRestart.time'] | Should -Be ([TimeSpan]::Zero)
    }

    It 'clears the recycle schedule before adding to it' {
        $cleared = $script:CallLog.IndexOf('clear:recycling.periodicRestart.schedule')
        $added = $script:CallLog.IndexOf('new:recycling.periodicRestart.schedule')

        $cleared | Should -BeGreaterOrEqual 0 -Because 'without the clear, each deploy appends another entry'
        $added | Should -BeGreaterThan $cleared
    }

    It 'recycles at a fixed time outside the hour daylight saving repeats' {
        # Rock warns that a restart inside the repeated hour can run a scheduled job
        # twice, which is why this is 04:00 and not 03:00.
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'recycling.periodicRestart.schedule' -and $Value.value -eq '04:00:00'
        }
    }

    It 'does not recreate a pool that is already there' {
        Should -Invoke New-WebAppPool -Times 0 -Exactly
    }
}

Describe 'Ensure-Website preload' {

    BeforeEach {
        $script:Applied = @{}

        Mock Test-Path { $true }
        Mock Get-WebBinding {
            if ($Protocol -eq 'https') {
                return (New-FakeBinding -BindingInformation '*:443:rock.example.org')
            }
            return (New-FakeBinding -BindingInformation '*:80:rock.example.org')
        }
        Mock New-Website { }
        Mock New-WebBinding { }
        Mock Get-EnvironmentCertificateThumbprint { 'AABBCC' }
    }

    It 'asks IIS to warm the application rather than waiting for a request' {
        # AlwaysRunning starts the worker process and leaves the application cold.
        # Preload is the half that runs Application_Start.
        Mock Set-ItemProperty { $script:Applied[$Name] = $Value }

        Ensure-Website -Name 'Rock' -PhysicalPath 'C:\Rock' -HostHeader 'rock.example.org' -PoolName 'Rock-Staging'

        $script:Applied['applicationDefaults.preloadEnabled'] | Should -BeTrue
    }

    It 'still binds the site when preload is unavailable' {
        # Application Initialization is a role feature. A rebuilt VM that came up
        # without it should serve a slow first request, not fail the deploy.
        Mock Set-ItemProperty {
            if ($Name -eq 'applicationDefaults.preloadEnabled') {
                throw 'The parameter "preloadEnabled" was not found'
            }
            $script:Applied[$Name] = $Value
        }

        { Ensure-Website -Name 'Rock' -PhysicalPath 'C:\Rock' -HostHeader 'rock.example.org' -PoolName 'Rock-Staging' -WarningAction SilentlyContinue } |
            Should -Not -Throw

        $script:Applied['applicationDefaults.preloadEnabled'] | Should -BeNullOrEmpty
    }
}
