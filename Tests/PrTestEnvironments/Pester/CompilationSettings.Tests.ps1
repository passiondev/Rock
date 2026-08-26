<#
    Set-ProductionCompilationSettings turns ASP.NET debug mode off on the server.

    Production was measured on 2026-08-26 still running with debug="true": ASP.NET
    was serving MicrosoftAjax.debug.js at 320KB where the release build is roughly
    100KB, and a 414KB script bundle unminified at 45 characters per line. Bundling
    was already happening. Minification is the part debug="true" turns off.

    The setting is applied to the deployed copy rather than committed to
    RockWeb/web.config, because upstream owns that file and edits it most releases.
    A fork-local change there conflicts at every merge and can be resolved away
    without anything failing. It also keeps debug="true" for a developer running
    Rock out of Visual Studio, which is where that setting belongs.

    Two things are worth more than the rest of this file. The pair must stay a
    pair -- debug="false" without an execution timeout puts a 110 second default
    back in front of a 95-107s cold start. And the transform has to be idempotent,
    because it runs against the previous deploy's output every single time.

    The last Context runs against the real RockWeb/web.config rather than a
    fixture. Fixtures prove the regex handles the shape someone wrote down here;
    only the shipped file proves it handles the shape that ships.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name 'Set-ProductionCompilationSettings')

    $script:Minimal = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web>
    <compilation debug="true" targetFramework="4.7.2" />
    <httpRuntime maxRequestLength="102400" targetFramework="4.7.2" />
  </system.web>
</configuration>
'@
}

Describe 'Set-ProductionCompilationSettings' {

    Context 'a web.config that is still in debug mode' {
        BeforeAll {
            $script:Result = Set-ProductionCompilationSettings -WebConfig $script:Minimal
        }

        It 'turns debug off' {
            $script:Result | Should -Match '<compilation[^>]*debug="false"'
            $script:Result | Should -Not -Match 'debug="true"'
        }

        It 'states an execution timeout at the same time' {
            # Not a separate concern. debug="true" sets the timeout to 30,000,000
            # seconds, so the 110 second default has never applied on this fork.
            # Turning debug off brings it back, in front of a cold start measured
            # at 95-107s.
            $script:Result | Should -Match '<httpRuntime[^>]*executionTimeout="600"'
        }

        It 'leaves the attributes it was not asked about alone' {
            $script:Result | Should -Match 'maxRequestLength="102400"'
            $script:Result | Should -Match 'targetFramework="4.7.2"'
        }

        It 'still parses as XML' {
            { [xml]$script:Result } | Should -Not -Throw
        }
    }

    Context 'the same file a second time, which is what a redeploy hands it' {
        It 'produces exactly what it produced the first time' {
            $once = Set-ProductionCompilationSettings -WebConfig $script:Minimal
            $twice = Set-ProductionCompilationSettings -WebConfig $once

            $twice | Should -BeExactly $once
        }

        It 'does not accumulate a second executionTimeout' {
            $config = $script:Minimal
            1..3 | ForEach-Object { $config = Set-ProductionCompilationSettings -WebConfig $config }

            ([regex]::Matches($config, 'executionTimeout=')).Count | Should -Be 1
        }

        It 'overwrites a timeout that is already there rather than adding one' {
            $existing = $script:Minimal -replace '<httpRuntime ', '<httpRuntime executionTimeout="110" '
            $result = Set-ProductionCompilationSettings -WebConfig $existing

            $result | Should -Match 'executionTimeout="600"'
            $result | Should -Not -Match 'executionTimeout="110"'
        }
    }

    Context 'shapes the shipped file does not currently have' {
        It 'adds debug="false" to a compilation element that states no debug at all' {
            $noDebug = $script:Minimal -replace ' debug="true"', ''
            $result = Set-ProductionCompilationSettings -WebConfig $noDebug

            $result | Should -Match '<compilation[^>]*debug="false"'
        }

        It 'honours a caller that wants a different timeout' {
            $result = Set-ProductionCompilationSettings -WebConfig $script:Minimal -ExecutionTimeoutSeconds 900
            $result | Should -Match 'executionTimeout="900"'
        }
    }

    Context 'the RockWeb/web.config that actually ships' {
        BeforeAll {
            # Anchored on the directory, which is what Get-RepositoryPath is for.
            # A missing web.config under it fails here, in BeforeAll, by name.
            $script:Shipped = Get-Content (Join-Path (Get-RepositoryPath 'RockWeb') 'web.config') -Raw
            $script:Applied = Set-ProductionCompilationSettings -WebConfig $script:Shipped
        }

        It 'finds exactly one compilation element to act on' {
            # Two would mean the replace hit the wrong one somewhere. Zero would
            # mean upstream moved it and this function is a no-op nobody noticed.
            ([regex]::Matches($script:Shipped, '<compilation\b')).Count | Should -Be 1
            ([regex]::Matches($script:Shipped, '<httpRuntime\b')).Count | Should -Be 1
        }

        It 'leaves no debug="true" anywhere in it' {
            $script:Applied | Should -Not -Match 'debug="true"'
        }

        It 'gives it the timeout' {
            $script:Applied | Should -Match '<httpRuntime[^>]*executionTimeout="600"'
        }

        It 'is still a valid config file afterwards' {
            { [xml]$script:Applied } | Should -Not -Throw
        }

        It 'changes those two lines and nothing else' {
            # The blast radius, stated as a number. This function runs against a
            # 41KB file holding connection bindings, assembly redirects and
            # handler registrations, and a regex that reached one of those would
            # break the site rather than slow it down.
            $before = $script:Shipped -split "`r?`n"
            $after = $script:Applied -split "`r?`n"

            $after.Count | Should -Be $before.Count -Because 'no line should be added or removed'

            $changed = @(0..($before.Count - 1) | Where-Object { $before[$_] -ne $after[$_] })
            $changed.Count | Should -Be 2 -Because "it changed: $(($changed | ForEach-Object { $after[$_].Trim() }) -join ' | ')"
        }
    }
}
