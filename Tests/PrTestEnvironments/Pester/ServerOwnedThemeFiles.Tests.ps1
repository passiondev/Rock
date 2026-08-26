<#
    Everything an organisation has ever changed about a legacy LESS theme lives
    in two files: _variable-overrides.less and _css-overrides.less. Upstream
    ships an empty pair in every theme and never touches them again.

    Production's copies carry the brand palette and the Pro Font Awesome wiring.
    The artifact's copies carry neither, and they have the same names, so both
    deployment modes get them wrong in opposite directions unless something
    intervenes -- InPlace overwrites production's with upstream's empty pair, and
    the DedicatedSite overlay skips production's because the artifact already put
    a file there. That is why staging renders in stock Rock blue.

    Get-ServerOwnedThemeFilePaths is what both modes ask, and the property that
    makes it safe to use as a robocopy exclusion is that it only ever returns
    paths that exist. A path returned for a theme the server does not have would
    exclude that theme's override file from the copy, and theme.less imports the
    file unconditionally, so the theme would stop compiling altogether.

    These run against the shipped function body, loaded by AST so the script
    itself never executes. Paths are built from $TestDrive: Join-Path resolves
    the qualifier through the provider, so a Windows literal on a Linux runner
    returns $null and an assertion comparing $null to $null passes having checked
    nothing.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name @(
        'Get-ServerOwnedThemeFilePaths',
        'ConvertTo-NativePath',
        'Resolve-SharedAssetSource',
        'Sync-ServerOwnedAssets',
        'Ensure-Directory',
        'Write-DeployStep'))

    $script:OverrideFiles = @('_variable-overrides.less', '_css-overrides.less')

    # Defined here rather than inside the Describe: Pester 5 runs an It in a
    # scope that does not see functions declared in the Describe body.
    function New-ThemeFile {
        param([string]$Theme, [string]$FileName, [string]$Content = 'x')
        $styles = Join-Path (Join-Path (Join-Path $script:SiteRoot 'Themes') $Theme) 'Styles'
        New-Item -ItemType Directory -Path $styles -Force | Out-Null
        Set-Content -Path (Join-Path $styles $FileName) -Value $Content -NoNewline
    }
}

Describe 'Get-ServerOwnedThemeFilePaths' {

    BeforeEach {
        # $TestDrive is scoped to the Describe, not to the It, so without this
        # every test inherits the theme tree the previous one built and the
        # "does not return a path for a file the site does not have" assertions
        # pass or fail on whatever ran before them.
        $script:SiteRoot = Join-Path $TestDrive 'site'
        $script:SiteRoot | Should -Not -BeNullOrEmpty
        if (Test-Path $script:SiteRoot) { Remove-Item $script:SiteRoot -Recurse -Force }
    }

    It 'finds both override files in a theme that has both' {
        New-ThemeFile -Theme 'Rock' -FileName '_variable-overrides.less'
        New-ThemeFile -Theme 'Rock' -FileName '_css-overrides.less'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found | Should -HaveCount 2
        $found | Should -Contain 'Themes/Rock/Styles/_variable-overrides.less'
        $found | Should -Contain 'Themes/Rock/Styles/_css-overrides.less'
    }

    It 'finds every theme, not just the first' {
        # Production customises Stark as well as Rock, and Stark is the theme the
        # login page renders in -- the first thing anyone sees.
        New-ThemeFile -Theme 'Rock' -FileName '_variable-overrides.less'
        New-ThemeFile -Theme 'Stark' -FileName '_variable-overrides.less'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found | Should -Contain 'Themes/Rock/Styles/_variable-overrides.less'
        $found | Should -Contain 'Themes/Stark/Styles/_variable-overrides.less'
    }

    It 'does not return a path for a file the site does not have' {
        # The safety property. This path becomes a robocopy /XF exclusion on the
        # InPlace branch, so returning it for a theme v19 introduces would stop
        # the artifact delivering the file and leave the theme unable to compile.
        New-ThemeFile -Theme 'Rock' -FileName '_variable-overrides.less'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found | Should -Not -Contain 'Themes/Rock/Styles/_css-overrides.less'
        $found | Should -HaveCount 1
    }

    It 'ignores a theme directory that has no Styles folder' {
        $themeDirectory = Join-Path (Join-Path $script:SiteRoot 'Themes') 'Empty'
        New-Item -ItemType Directory -Path $themeDirectory -Force | Out-Null

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found | Should -HaveCount 0
    }

    It 'returns nothing rather than throwing when the site root does not exist' {
        # The DedicatedSite caller passes the base site's path, and that path is
        # discovered from IIS and can legitimately be absent. A throw here would
        # fail a deploy over a theme file.
        $missing = Join-Path $TestDrive 'no-such-site'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $missing -FileNames $script:OverrideFiles)

        $found | Should -HaveCount 0
    }

    It 'returns nothing rather than throwing when the site root is empty' {
        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot '' -FileNames $script:OverrideFiles)

        $found | Should -HaveCount 0
    }

    It 'returns nothing when the site has no Themes directory at all' {
        New-Item -ItemType Directory -Path $script:SiteRoot -Force | Out-Null

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found | Should -HaveCount 0
    }

    It 'skips a blank filename rather than matching the Styles directory itself' {
        # Test-Path on a joined empty leaf answers for the directory, which would
        # put 'Themes/Rock/Styles/' into a /XF exclusion list.
        New-ThemeFile -Theme 'Rock' -FileName '_variable-overrides.less'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames @('', '_variable-overrides.less'))

        $found | Should -HaveCount 1
        $found[0] | Should -Be 'Themes/Rock/Styles/_variable-overrides.less'
    }

    It 'uses forward slashes, so the result concatenates with $ServerOwnedDirectories' {
        # Both lists are handed to the same functions. $ServerOwnedDirectories is
        # written with forward slashes for the reason its own comment gives.
        New-ThemeFile -Theme 'Rock' -FileName '_variable-overrides.less'

        $found = @(Get-ServerOwnedThemeFilePaths -SiteRoot $script:SiteRoot -FileNames $script:OverrideFiles)

        $found[0] | Should -Not -Match '\\'
    }
}

Describe 'Sync-ServerOwnedAssets with a path that names a file' {

    <#
        The restore pass was written for Assets/Fonts/FontAwesome, a directory.
        The theme overrides are single files inside directories the artifact owns
        and keeps writing, so they cannot be handled the same way.

        robocopy takes two directories and an optional file filter. Pointing it at
        a file as though it were a directory does not fail loudly -- it reports a
        result and moves nothing -- so the split between the two shapes is the
        whole of the behaviour, and getting it wrong leaves staging on stock Rock
        blue with a deploy log that says the restore succeeded.

        robocopy does not exist off Windows, so it is stubbed here and the call is
        captured. That checks how the shipped function invokes it, which is where
        this can go wrong; it does not check what robocopy then does with those
        arguments.
    #>

    BeforeAll {
        function robocopy {
            $script:RobocopyCalls += , @($args)
            # 1 is robocopy for "files were copied". Anything over 7 is a failure
            # the function is supposed to throw on.
            $global:LASTEXITCODE = 1
        }

        # Write-DeployStep stamps elapsed time against this. Nothing here reads the
        # log, so any fixed start will do -- but it has to exist, or every call
        # through the function under test dies subtracting from $null.
        $script:DeployStartedUtc = (Get-Date).ToUniversalTime()
    }

    BeforeEach {
        $script:RobocopyCalls = @()

        $script:Source = Join-Path $TestDrive 'base'
        $script:Destination = Join-Path $TestDrive 'new'
        foreach ($root in @($script:Source, $script:Destination)) {
            if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        }
        # Both roots have to exist before the call: the function resolves them to
        # compare them, and Resolve-Path on a missing path is a terminating error.
        # A real deploy has already extracted the artifact to the destination.
        New-Item -ItemType Directory -Path $script:Destination -Force | Out-Null

        $script:StylesRelative = 'Themes/Rock/Styles'
        $sourceStyles = Join-Path (Join-Path $script:Source 'Themes/Rock') 'Styles'
        New-Item -ItemType Directory -Path $sourceStyles -Force | Out-Null
        Set-Content -Path (Join-Path $sourceStyles '_variable-overrides.less') `
            -Value '@brand-color: #00b8e4;' -NoNewline
    }

    It 'copies the parent directory and names the file as a filter' {
        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @("$script:StylesRelative/_variable-overrides.less")

        $script:RobocopyCalls | Should -HaveCount 1
        $call = $script:RobocopyCalls[0]

        # Two directories, then the leaf as a filter. Passing the file itself as
        # either directory is the mistake this exists to catch.
        $call[0] | Should -Not -Match '_variable-overrides\.less$'
        $call[1] | Should -Not -Match '_variable-overrides\.less$'
        $call | Should -Contain '_variable-overrides.less'
    }

    It 'does not recurse when the path names a file' {
        # /E from the Styles directory with a filename filter would rake that
        # filter across everything beneath it. Each path is meant to move one file.
        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @("$script:StylesRelative/_variable-overrides.less")

        $script:RobocopyCalls[0] | Should -Not -Contain '/E'
    }

    It 'still recurses when the path names a directory' {
        # Font Awesome is a directory and has to keep working exactly as before.
        $fonts = Join-Path $script:Source 'Assets/Fonts/FontAwesome'
        New-Item -ItemType Directory -Path $fonts -Force | Out-Null
        Set-Content -Path (Join-Path $fonts 'fa-solid-900.woff2') -Value 'binary' -NoNewline

        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @('Assets/Fonts/FontAwesome')

        $script:RobocopyCalls | Should -HaveCount 1
        $script:RobocopyCalls[0] | Should -Contain '/E'
    }

    It 'creates the parent directory rather than a directory named after the file' {
        # Ensure-Directory on the file path would make a directory called
        # _variable-overrides.less and robocopy would copy the file inside it.
        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @("$script:StylesRelative/_variable-overrides.less")

        $collision = Join-Path $script:Destination "$script:StylesRelative/_variable-overrides.less"
        (Test-Path -Path $collision -PathType Container) | Should -BeFalse
        (Test-Path -Path (Split-Path -Parent $collision) -PathType Container) | Should -BeTrue
    }

    It 'says the path was absent rather than copying, when the base site lacks it' {
        # A theme production does not have is not an error. The artifact's copy
        # stays, which is the only thing that could be right.
        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @('Themes/RockNextGen/Styles/_variable-overrides.less')

        $script:RobocopyCalls | Should -HaveCount 0
    }
}

Describe 'Sync-ServerOwnedAssets byte reporting for a path that names a file' {

    <#
        The runbook tells an operator to read this line to confirm the restore
        happened, so a line that says "0 bytes" for a file that arrived intact
        would send them chasing a fault that is not there.

        It reports with Get-ChildItem -Recurse -File against the destination path,
        which was written when every path in the list was a directory. That it
        also returns the item when handed a leaf is real PowerShell behaviour and
        not an accident, but it is not obvious from reading the line, so it is
        pinned here rather than left to be rediscovered.

        The stub copies, unlike the one above. This test is about the number in
        the message, and a stub that moved nothing could only ever report on what
        the artifact had already put there.
    #>

    BeforeAll {
        function robocopy {
            # Mirror the real call shape: two directories, then a filename filter.
            $from = $args[0]
            $to = $args[1]
            $leaf = $args | Select-Object -Skip 2 | Where-Object { $_ -notmatch '^/' } | Select-Object -First 1
            if ($leaf) {
                Copy-Item -Path (Join-Path $from $leaf) -Destination (Join-Path $to $leaf) -Force
            }
            $global:LASTEXITCODE = 1
        }

        function Write-DeployStep {
            param([string]$Message)
            $script:DeployMessages += $Message
        }
    }

    BeforeEach {
        $script:DeployMessages = @()

        $script:Source = Join-Path $TestDrive 'reportbase'
        $script:Destination = Join-Path $TestDrive 'reportnew'
        foreach ($root in @($script:Source, $script:Destination)) {
            if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $script:Destination -Force | Out-Null
    }

    It 'reports the restored file''s own size, not zero' {
        $sourceStyles = Join-Path $script:Source 'Themes/Rock/Styles'
        New-Item -ItemType Directory -Path $sourceStyles -Force | Out-Null

        # 310 bytes, which is what production's Rock/_css-overrides.less measured.
        $body = 'x' * 310
        Set-Content -Path (Join-Path $sourceStyles '_css-overrides.less') -Value $body -NoNewline

        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @('Themes/Rock/Styles/_css-overrides.less')

        $line = $script:DeployMessages | Where-Object { $_ -match '_css-overrides\.less restored' }
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match '\(310 bytes on disk\)'
    }

    It 'says zero rather than blank, and warns, when nothing arrived' {
        # Measure-Object over an empty set sums to $null, so the uncoalesced line
        # printed "( bytes on disk)". robocopy can report success having moved
        # nothing, which is precisely when this line is the only evidence.
        $sourceStyles = Join-Path $script:Source 'Themes/Rock/Styles'
        New-Item -ItemType Directory -Path $sourceStyles -Force | Out-Null
        Set-Content -Path (Join-Path $sourceStyles '_css-overrides.less') -Value ('x' * 310) -NoNewline

        # Shadow the copying stub for this test only, so the copy is a no-op.
        function robocopy { $global:LASTEXITCODE = 1 }

        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @('Themes/Rock/Styles/_css-overrides.less') -WarningVariable warnings -WarningAction SilentlyContinue

        $line = $script:DeployMessages | Where-Object { $_ -match '_css-overrides\.less restored' }
        $line | Should -Match '0 bytes on disk'
        $line | Should -Not -Match '\(\s+bytes'
        $warnings | Should -Not -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'copied 0 bytes'
    }

    It 'reports only the named file, not everything beside it in Styles' {
        # The count comes from the destination path. If that were ever widened to
        # the parent directory the number would silently become the whole theme's
        # Styles folder, which reads as success no matter what arrived.
        $sourceStyles = Join-Path $script:Source 'Themes/Rock/Styles'
        New-Item -ItemType Directory -Path $sourceStyles -Force | Out-Null
        Set-Content -Path (Join-Path $sourceStyles '_css-overrides.less') -Value ('x' * 310) -NoNewline

        $destStyles = Join-Path $script:Destination 'Themes/Rock/Styles'
        New-Item -ItemType Directory -Path $destStyles -Force | Out-Null
        Set-Content -Path (Join-Path $destStyles 'theme.less') -Value ('y' * 9000) -NoNewline

        Sync-ServerOwnedAssets -SourceRoot $script:Source -DestinationRoot $script:Destination `
            -RelativePaths @('Themes/Rock/Styles/_css-overrides.less')

        $line = $script:DeployMessages | Where-Object { $_ -match '_css-overrides\.less restored' }
        $line | Should -Match '\(310 bytes on disk\)'
        $line | Should -Not -Match '9310'
    }
}

Describe 'ConvertTo-NativePath' {

    <#
        This exists for one caller: the robocopy /XF and /XD exclusion arguments
        on the InPlace branch. The server-owned lists are written with forward
        slashes and Join-Path only normalises the seam it creates, so the joined
        path is mixed. An exclusion that fails to match is silent -- robocopy
        copies the artifact's stock file over production's and reports success --
        so this is the wrong place to rely on Windows being forgiving.

        The first implementation used -replace with the separator passed through
        Regex::Escape. That returns two characters for a backslash, and a
        replacement string takes them literally, so every separator came back
        doubled. These tests are written to fail on that.
    #>

    It 'returns a path whose separators are all native' {
        $native = [System.IO.Path]::DirectorySeparatorChar
        $foreign = if ($native -eq [char]'/') { [char]'\' } else { [char]'/' }

        $result = ConvertTo-NativePath -Path ('Themes' + $foreign + 'Rock' + $foreign + 'Styles')

        $result | Should -Be ('Themes' + $native + 'Rock' + $native + 'Styles')
        $result.IndexOf($foreign) | Should -Be -1
    }

    It 'does not double a separator that was already native' {
        # The Regex::Escape bug. 'a/b' became 'a\\b' on Windows, which is not a
        # path any /XF argument could match.
        $native = [System.IO.Path]::DirectorySeparatorChar
        $result = ConvertTo-NativePath -Path ('a' + $native + 'b' + $native + 'c')

        $result | Should -Be ('a' + $native + 'b' + $native + 'c')
        $result | Should -Not -Match ([System.Text.RegularExpressions.Regex]::Escape("$native$native"))
    }

    It 'leaves the separator count unchanged' {
        # Doubling is the failure mode, so count rather than inspect. Three
        # separators in, three out, whichever way they were written.
        $native = [System.IO.Path]::DirectorySeparatorChar
        $result = ConvertTo-NativePath -Path 'Themes/Rock/Styles/_css-overrides.less'

        ($result.ToCharArray() | Where-Object { $_ -eq $native }).Count | Should -Be 3
    }

    It 'normalises a path that mixes both separators, which is what Join-Path produces' {
        # Join-Path 'C:\extract' 'Themes/Rock/x.less' is exactly this shape.
        $native = [System.IO.Path]::DirectorySeparatorChar
        $mixed = 'root' + [char]'\' + 'Themes' + [char]'/' + 'Rock' + [char]'/' + 'x.less'

        $result = ConvertTo-NativePath -Path $mixed

        $result | Should -Be ('root' + $native + 'Themes' + $native + 'Rock' + $native + 'x.less')
    }

    It 'passes an empty string through rather than throwing' {
        ConvertTo-NativePath -Path '' | Should -Be ''
    }

    Context 'with the separator forced to a backslash, as on the box' {

        <#
            The tests above run against whatever this platform's separator is, so
            on macOS and on a Linux runner they exercise '/' replacing '/' and
            prove nothing about the deploy. These force the Windows separator so
            the doubling bug is reachable off Windows.

            Confirmed by reverting the implementation: the platform-relative
            tests still passed, these fail.
        #>

        BeforeAll { $script:Backslash = [char]'\' }

        It 'converts forward slashes to backslashes' {
            ConvertTo-NativePath -Path 'Themes/Rock/Styles/_css-overrides.less' -Separator $script:Backslash |
                Should -Be 'Themes\Rock\Styles\_css-overrides.less'
        }

        It 'does not double them, which Regex::Escape did' {
            # Regex::Escape('\') is two characters, and a replacement string takes
            # them literally. The result was 'Themes\\Rock\\Styles', which no /XF
            # argument can ever match.
            $result = ConvertTo-NativePath -Path 'Themes/Rock/Styles' -Separator $script:Backslash

            $result | Should -Not -Match '\\\\'
            ($result.ToCharArray() | Where-Object { $_ -eq $script:Backslash }).Count | Should -Be 2
        }

        It 'normalises the mixed path Join-Path actually produces on the box' {
            # Join-Path 'C:\extract' 'Themes/Rock/x.less' returns this exactly.
            ConvertTo-NativePath -Path 'C:\extract\Themes/Rock/Styles/x.less' -Separator $script:Backslash |
                Should -Be 'C:\extract\Themes\Rock\Styles\x.less'
        }

        It 'leaves an already-backslashed path alone' {
            $already = 'C:\extract\Themes\Rock\x.less'
            ConvertTo-NativePath -Path $already -Separator $script:Backslash | Should -Be $already
        }
    }
}

Describe 'Resolve-SharedAssetSource' {

    <#
        The plan and the apply run both need to know which site the overlay reads
        from, and they used to work it out separately. The apply run fell back to
        the Default Web Site when nothing was configured -- the normal case -- and
        the plan did not, so the plan reported "none found" for a run that would
        restore eight files.

        The Get-Command guard is the part worth testing here. -ErrorAction does not
        suppress a missing cmdlet: CommandNotFoundException is raised before any
        parameter is bound. Without the guard this function throws on any machine
        without the IIS module, which is every machine these tests run on, and the
        dry run now calls it.
    #>

    It 'returns the configured path when one is given' {
        Resolve-SharedAssetSource -ConfiguredPath '/srv/base-site' | Should -Be '/srv/base-site'
    }

    It 'expands environment variables in the configured path' {
        # The apply run did this and the plan must not quietly stop doing it.
        $env:ROCK_TEST_BASE = '/srv/expanded'
        try {
            Resolve-SharedAssetSource -ConfiguredPath '%ROCK_TEST_BASE%' | Should -Be '/srv/expanded'
        }
        finally {
            Remove-Item Env:\ROCK_TEST_BASE -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty rather than throwing when Get-Website does not exist' {
        # This is the whole point of the guard, and it is the state of every
        # machine that runs this suite. Without it the call is a terminating error.
        (Get-Command -Name 'Get-Website' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty

        { Resolve-SharedAssetSource -ConfiguredPath '' } | Should -Not -Throw
        Resolve-SharedAssetSource -ConfiguredPath '' | Should -Be ''
    }

    It 'treats whitespace as no configured path' {
        { Resolve-SharedAssetSource -ConfiguredPath '   ' } | Should -Not -Throw
        Resolve-SharedAssetSource -ConfiguredPath '   ' | Should -Be ''
    }

    It 'reads the Default Web Site when nothing is configured and IIS is present' {
        # Stubbed, because there is no IIS here. What is being checked is that a
        # blank parameter reaches the fallback at all -- the plan's original bug
        # was that it never did.
        function Get-Website { param($Name) [pscustomobject]@{ physicalPath = '/srv/default-web-site' } }

        Resolve-SharedAssetSource -ConfiguredPath '' | Should -Be '/srv/default-web-site'
    }
}
