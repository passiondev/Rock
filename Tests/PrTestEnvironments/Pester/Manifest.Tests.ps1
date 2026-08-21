<#
    Every PR environment keeps a manifest on the VM, and the cleanup job reads it
    to decide what to destroy. Two functions stand between that JSON and an
    irreversible delete, and until now nothing ran either of them.

    ConvertTo-ManifestHashtable exists because Windows PowerShell 5.1 has no
    `ConvertFrom-Json -AsHashtable`. It is copied into three scripts rather than
    shared, deliberately -- the bootstrap ships this directory with
    `gsutil cp Deployment/PrTestEnvironments/*.ps1`, so a module would never reach
    the VM. test_shared_powershell_helpers.py holds the three copies identical as
    text. This file runs all three, so "identical" also means "behaves the same".
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeploymentDir = Join-Path $PSScriptRoot '../../../Deployment/PrTestEnvironments'
    $script:CleanupScript = Join-Path $script:DeploymentDir 'Invoke-PrEnvironmentCleanup.ps1'

    . (Import-ScriptFunction -Path $script:CleanupScript -Name 'Get-ManifestActivityUtc')
}

Describe 'ConvertTo-ManifestHashtable' {
    # All three copies, run against the same expectations. A copy that drifts in
    # behaviour fails here even if it still passes the text-identity check.
    $copies = @(
        @{ Script = 'Invoke-PrEnvironmentCleanup.ps1' }
        @{ Script = 'Invoke-SandboxRefreshWithPrEnvironments.ps1' }
        @{ Script = 'Stop-PrEnvironment.ps1' }
    )

    Context '<Script>' -ForEach $copies {
        BeforeAll {
            . (Import-ScriptFunction `
                -Path (Join-Path $PSScriptRoot "../../../Deployment/PrTestEnvironments/$Script") `
                -Name 'ConvertTo-ManifestHashtable')
        }

        It 'produces a hashtable, which is the whole reason it exists' {
            # Get-ManifestActivityUtc calls ContainsKey. A PSCustomObject has no such
            # method, so a conversion that quietly returned one would fail at the
            # point of use rather than here.
            $result = ConvertTo-ManifestHashtable -Json '{"prNumber": 14, "status": "stopped"}'

            $result | Should -BeOfType [hashtable]
            $result.ContainsKey('prNumber') | Should -BeTrue
            $result['status'] | Should -Be 'stopped'
        }

        It 'returns an empty hashtable rather than null for nothing' {
            # The caller indexes into the result immediately. Null would throw at a
            # site with no context about which manifest was empty.
            foreach ($empty in '', '   ', $null) {
                $result = ConvertTo-ManifestHashtable -Json $empty
                $result | Should -BeOfType [hashtable]
                $result.Count | Should -Be 0
            }
        }

        It 'keeps nested values reachable' {
            $result = ConvertTo-ManifestHashtable -Json '{"site": {"name": "pr-14"}}'

            $result['site'].name | Should -Be 'pr-14'
        }

        It 'throws on malformed JSON instead of returning a half-read manifest' {
            # A manifest truncated by a failed upload should stop the run. Silently
            # treating it as empty would read as "no activity ever" and hand the
            # environment straight to the destroy branch.
            { ConvertTo-ManifestHashtable -Json '{"prNumber": 14' } | Should -Throw
        }
    }
}

Describe 'Get-ManifestActivityUtc' {
    It 'reads the deploy timestamp when that is all there is' {
        $manifest = @{ deployedAtUtc = '2026-08-01T12:00:00Z' }

        (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-08-01'
    }

    It 'reads the stop timestamp when that is all there is' {
        $manifest = @{ stoppedAtUtc = '2026-08-19T12:00:00Z' }

        (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-08-19'
    }

    It 'treats the most recent timestamp as the activity, not the first one it finds' {
        # The bug this test was written for. The function walked a fixed property
        # order -- lastLifecycleAtUtc, deployedAtUtc, stoppedAtUtc, destroyedAtUtc --
        # and returned the first one present. Nothing in the repository has ever
        # written lastLifecycleAtUtc, so deployedAtUtc always won and stoppedAtUtc
        # was never read.
        #
        # Invoke-PrEnvironmentCleanup.ps1:128 destroys a stopped environment once
        # the idle span reaches DestroyAfterDays. An environment deployed months ago
        # and stopped this morning reported months of idleness, so it was destroyed
        # on the next cleanup pass instead of after its grace period. The grace
        # period was effectively zero for every long-lived environment.
        $manifest = @{
            deployedAtUtc = '2026-01-01T00:00:00Z'
            stoppedAtUtc  = '2026-08-20T00:00:00Z'
        }

        (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-08-20'
    }

    It 'ignores a property that is present but blank' {
        $manifest = @{ deployedAtUtc = '   '; stoppedAtUtc = '2026-08-19T12:00:00Z' }

        (Get-ManifestActivityUtc -Manifest $manifest).ToString('yyyy-MM-dd') | Should -Be '2026-08-19'
    }

    It 'reports something ancient when the manifest records no activity at all' {
        # Not compared against DateTime::MinValue: the function converts through
        # ToUniversalTime, and an Unspecified MinValue is read as local time, so the
        # exact value depends on the machine's zone. Ancient is the contract.
        $result = Get-ManifestActivityUtc -Manifest @{}

        $result.Year | Should -Be 1
    }

    It 'works on the output of the conversion, which is how it is actually called' {
        $json = '{"prNumber": 14, "status": "stopped", "deployedAtUtc": "2026-01-01T00:00:00Z", "stoppedAtUtc": "2026-08-20T00:00:00Z"}'
        . (Import-ScriptFunction -Path $script:CleanupScript -Name 'ConvertTo-ManifestHashtable')

        $activity = Get-ManifestActivityUtc -Manifest (ConvertTo-ManifestHashtable -Json $json)

        $activity.ToString('yyyy-MM-dd') | Should -Be '2026-08-20'
    }
}
