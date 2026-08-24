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

    $script:HostHeader = 'pr-14.rock-dev.connect.passion.team'
    $script:Wildcard = 'CN=*.rock-dev.connect.passion.team'

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
