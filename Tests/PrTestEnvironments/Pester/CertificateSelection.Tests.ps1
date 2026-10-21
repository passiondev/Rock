<#
    Which certificate a deploy binds to the site, decided twice.

    Deploy-RockEnvironment.ps1 and Deploy-PrEnvironment.ps1 each carry their own
    copy of this selector, and test_shared_powershell_helpers.py lists the pair as
    deliberately divergent -- they differ in the friendly name they mint under.
    Divergent text is fine. Divergent ranking is not, and that is what this file
    holds together.

    The ranking is the whole function. On 2026-08-10 it sorted on expiry alone, so
    the self-signed placeholder -- minted for two years -- outranked every real
    Let's Encrypt certificate, which lasts ninety days. pr-4 served a real
    certificate at 16:57 UTC, was redeployed at 19:44, and came back on the
    self-signed wildcard. Renewal kept reporting success the whole time.

    A substring assertion can see that a two-key sort is written down. It cannot
    see which certificate comes out, which is the only thing that mattered.

    The certificate store is faked. Issuer, Subject, NotAfter and Thumbprint are
    plain values on a real X509Certificate2, so the fake is faithful for
    everything asserted here. DnsNameList is not a string collection on a real
    certificate, so these tests drive the filter through Subject instead of
    asserting anything about that branch.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    function New-FakeCertificate {
        param(
            [string]$Subject,
            [string]$Issuer,
            [datetime]$NotAfter,
            [string]$Thumbprint
        )

        return [pscustomobject]@{
            Subject     = $Subject
            Issuer      = $Issuer
            NotAfter    = $NotAfter
            Thumbprint  = $Thumbprint
            DnsNameList = @()
        }
    }

    $script:HostHeader = 'pr-14.staging.connect.passion.team'
    $script:Wildcard = 'CN=*.staging.connect.passion.team'

    # New-SelfSignedCertificate is a Windows PKI cmdlet, and these tests run on the
    # same Linux runner as the rest of the suite so they can gate every pull request.
    # Pester will only mock a command it can resolve, so a stub stands in where the
    # real one is absent. It is never called through to: the one test that reaches
    # this path mocks it.
    if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
        function global:New-SelfSignedCertificate {
            param(
                [string[]]$DnsName,
                [string]$CertStoreLocation,
                [string]$FriendlyName,
                [datetime]$NotAfter
            )

            throw 'stub: this should always be mocked'
        }
    }
}

Describe '<Function>' -ForEach @(
    @{ Script = 'Deploy-RockEnvironment.ps1'; Function = 'Get-EnvironmentCertificateThumbprint' }
    @{ Script = 'Deploy-PrEnvironment.ps1'; Function = 'Get-PrEnvironmentCertificateThumbprint' }
) {
    BeforeAll {
        . (Import-ScriptFunction `
            -Path (Get-RepositoryPath "Deployment/PrTestEnvironments/$Script") `
            -Name $Function)

        $script:Selector = $Function
    }

    It 'returns an explicit thumbprint without consulting the store at all' {
        # The caller can name a certificate. Doing a store lookup anyway would let
        # the ranking below override an operator's explicit choice.
        Mock Get-ChildItem { throw 'the store should not have been read' } -ParameterFilter { "$Path" -like 'Cert:*' }

        & $script:Selector -HostHeader $script:HostHeader -Thumbprint 'ABC123' | Should -Be 'ABC123'
    }

    It 'prefers a CA-issued certificate over the longer-lived self-signed placeholder' {
        # The 2026-08-10 regression, in one assertion. The placeholder outlives the
        # real certificate by years, so any ranking that leads with expiry picks it.
        Mock Get-ChildItem -ParameterFilter { "$Path" -like 'Cert:*' } -MockWith {
            @(
                New-FakeCertificate -Subject $script:Wildcard -Issuer $script:Wildcard `
                    -NotAfter (Get-Date).AddYears(2) -Thumbprint 'SELFSIGNED'
                New-FakeCertificate -Subject $script:Wildcard -Issuer "CN=R3, O=Let's Encrypt" `
                    -NotAfter (Get-Date).AddDays(60) -Thumbprint 'LETSENCRYPT'
            )
        }

        & $script:Selector -HostHeader $script:HostHeader | Should -Be 'LETSENCRYPT'
    }

    It 'prefers the later expiry among certificates from a real authority' {
        Mock Get-ChildItem -ParameterFilter { "$Path" -like 'Cert:*' } -MockWith {
            @(
                New-FakeCertificate -Subject $script:Wildcard -Issuer "CN=R3, O=Let's Encrypt" `
                    -NotAfter (Get-Date).AddDays(10) -Thumbprint 'EXPIRING'
                New-FakeCertificate -Subject $script:Wildcard -Issuer "CN=R3, O=Let's Encrypt" `
                    -NotAfter (Get-Date).AddDays(80) -Thumbprint 'FRESH'
            )
        }

        & $script:Selector -HostHeader $script:HostHeader | Should -Be 'FRESH'
    }

    It 'ignores a certificate that has already expired' {
        Mock Get-ChildItem -ParameterFilter { "$Path" -like 'Cert:*' } -MockWith {
            @(
                New-FakeCertificate -Subject $script:Wildcard -Issuer "CN=R3, O=Let's Encrypt" `
                    -NotAfter (Get-Date).AddDays(-1) -Thumbprint 'EXPIRED'
                New-FakeCertificate -Subject $script:Wildcard -Issuer $script:Wildcard `
                    -NotAfter (Get-Date).AddYears(2) -Thumbprint 'SELFSIGNED'
            )
        }

        & $script:Selector -HostHeader $script:HostHeader | Should -Be 'SELFSIGNED'
    }

    It 'looks for the wildcard that covers the host, not the host itself' {
        # Every environment is a subdomain and one wildcard covers the fleet. A
        # selector that searched for the literal host would find nothing and mint a
        # fresh placeholder on every deploy.
        Mock Get-ChildItem -ParameterFilter { "$Path" -like 'Cert:*' } -MockWith {
            @(
                New-FakeCertificate -Subject $script:Wildcard -Issuer "CN=R3, O=Let's Encrypt" `
                    -NotAfter (Get-Date).AddDays(60) -Thumbprint 'WILDCARD'
            )
        }

        & $script:Selector -HostHeader $script:HostHeader | Should -Be 'WILDCARD'
    }

    It 'mints a placeholder when the store holds nothing usable' {
        # HTTPS has to keep answering even with no real certificate available, or a
        # run of failed renewals takes the binding down outright.
        Mock Get-ChildItem -ParameterFilter { "$Path" -like 'Cert:*' } -MockWith { @() }
        Mock New-SelfSignedCertificate { [pscustomobject]@{ Thumbprint = 'MINTED' } }

        & $script:Selector -HostHeader $script:HostHeader | Should -Be 'MINTED'

        Should -Invoke New-SelfSignedCertificate -Times 1 -Exactly
    }
}

Describe 'Ensure-Website, which binds the certificate chosen above' {
    <#
        Staging's second run of Invoke-DedicatedSiteReplace, on 2026-10-20,
        deployed, passed its health check, and then failed on "The property
        'BackupPath' cannot be found on this object". Something inside the
        replace had joined its return value. The overlay's robocopy output had
        been contained that morning, and by elimination the one statement left
        on that path that could still emit was this function's last line: a
        method call on an IIS binding, whose return value PowerShell hands to
        the caller unless something discards it.

        The binding is faked, so this cannot say what the real method returns.
        It holds that whatever it returns goes nowhere.
    #>

    BeforeAll {
        . (Import-ScriptFunction `
            -Path (Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1') `
            -Name @('Ensure-Website', 'Get-EnvironmentCertificateThumbprint'))

        # WebAdministration cmdlets, absent off Windows, stubbed for the reason
        # New-SelfSignedCertificate is above. The parameters are the ones
        # Ensure-Website passes, so a mock's filter can see them. New-Website and
        # New-WebBinding are never reached: the site and both bindings exist.
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
        if (-not (Get-Command New-Website -ErrorAction SilentlyContinue)) {
            function global:New-Website {
                param([string]$Name, [string]$PhysicalPath, [string]$ApplicationPool, [int]$Port, [string]$HostHeader)
                throw 'stub: this should always be mocked'
            }
        }
    }

    BeforeEach {
        $script:Bound = @()

        $script:HttpsBinding = [pscustomobject]@{ bindingInformation = "*:443:$($script:HostHeader)" }
        $script:HttpsBinding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value {
            param($Thumbprint, $StoreName)
            $script:Bound += "$StoreName/$Thumbprint"
            return 'an object IIS handed back'
        }

        Mock Test-Path { $true } -ParameterFilter { $Path -like 'IIS:\Sites\*' }
        Mock Set-ItemProperty { }
        Mock Get-WebBinding -ParameterFilter { $Protocol -eq 'http' } -MockWith {
            [pscustomobject]@{ bindingInformation = "*:80:$($script:HostHeader)" }
        }
        Mock Get-WebBinding -ParameterFilter { $Protocol -eq 'https' } -MockWith { $script:HttpsBinding }
        Mock Get-EnvironmentCertificateThumbprint { 'LETSENCRYPT' }
    }

    It 'binds the certificate to the HTTPS binding' {
        Ensure-Website -Name 'rock-staging' -PhysicalPath 'C:\inetpub\staging' `
            -HostHeader $script:HostHeader -PoolName 'rock-staging' | Out-Null

        $script:Bound | Should -Be @('My/LETSENCRYPT')
    }

    It 'hands nothing back, whatever the binding returns' {
        $output = @(Ensure-Website -Name 'rock-staging' -PhysicalPath 'C:\inetpub\staging' `
                -HostHeader $script:HostHeader -PoolName 'rock-staging')

        $output | Should -HaveCount 0 -Because 'Invoke-DedicatedSiteReplace calls this and returns a record; anything this emits lands in that record'
    }
}
