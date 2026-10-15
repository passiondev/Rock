<#
    The two things a deploy can be, and the order each one does them in.

    Until these functions existed the whole deploy ran as top-level script.
    Import-ScriptFunction lifts function definitions, so nothing under Pester
    could reach any of it: 379 tests stopped at the last function, and the only
    coverage the ordering had was Python tests matching substrings of the script's
    own source. Those assert what the file says. They cannot assert what it does,
    and the difference is not academic -- the extraction that made this file
    possible exposed a cross-branch variable read that had been a terminating
    error on the production rollback path the whole time, under 132 text checks
    that never saw it.

    Ordering is what is tested here because ordering is what is dangerous.

    Invoke-DedicatedSiteReplace
        Between the wipe and the restore the site does not exist. Every read that
        has to happen before that window must have happened before it, and every
        write that repairs it must come after -- in the right order among
        themselves, because the shared-asset overlay fills gaps only and the
        server-owned pass replaces. Run the second one first and it is a no-op
        that logs a successful restore.

    Invoke-InPlaceOverlay
        The branch production uses. It reads the migration log and copies the site
        aside before it writes anything, because both are worthless afterwards.
        Orphan reconciliation happens while the pool is still stopped and nothing
        holds a lock on bin.

    Get-InPlaceOverlayPlan
        What that branch keeps away from the artifact, worked out once. The dry
        run prints this record and the overlay hands its exclusions to robocopy,
        so the plan an operator approves is held here against the arguments
        robocopy was actually given -- the one comparison nothing made while the
        two were worked out separately.

    Both hand back one record with the same two fields. That is asserted here
    directly: it is what lets the deploy body ask "is there a backup" instead of
    asking which branch ran, and a stray emitter anywhere inside either function
    would break it silently -- robocopy's job summary alone is forty lines.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'

    # The two branches and the in-place plan under test, and the two helpers they
    # call that are cheap and honest to run for real. Everything else is stubbed
    # below, because the question is what order it was called in and not what it
    # did -- and -Supplied is that list, held against what the lifted bodies
    # actually reach for. A stub the deploy script has stopped calling fails here
    # rather than going on passing.
    . (Import-ScriptFunction -Path $script:DeployScript -Name `
            'Invoke-DedicatedSiteReplace', 'Get-InPlaceOverlayPlan', 'Invoke-InPlaceOverlay', `
            'Ensure-Directory', 'ConvertTo-NativePath' `
        -Supplied `
            'Write-DeployStep', 'Resolve-SharedAssetSource', 'Sync-SharedSiteAssets', `
            'Get-ServerOwnedThemeFilePaths', 'Sync-ServerOwnedAssets', `
            'Remove-PluginBuildArtifacts', 'Write-PluginAssemblyReport', `
            'Write-RuntimeConfiguration', 'Ensure-AppPool', 'Ensure-Website', `
            'Get-MigrationFingerprint', 'Invoke-OrphanedAssemblyReconciliation', `
            'Write-OrphanedBlockReport', 'Assert-DeployedCoreVersion')

    # Recorded rather than mocked. Pester's Should -Invoke can say a mock was
    # called and how often; it cannot say it was called after another one, and
    # after is the whole subject of this file.
    $script:Calls = @()
    $script:Arguments = @{}

    function Script:Record {
        param([string]$Name, [hashtable]$Detail = @{})
        $script:Calls += $Name
        if (-not $script:Arguments.ContainsKey($Name)) { $script:Arguments[$Name] = @() }
        $script:Arguments[$Name] = @($script:Arguments[$Name]) + $Detail
    }

    function Script:DetailOf {
        <#
            What one call was given. Keyed by name and by which call it was,
            because the in-place branch calls robocopy twice and the backup's
            exclusions are not the deploy copy's -- reading "the arguments to
            robocopy" gives whichever came last and quietly asserts the wrong one.
        #>
        param([string]$Name, [int]$Index = 0)
        $recorded = @()
        if ($script:Arguments.ContainsKey($Name)) { $recorded = @($script:Arguments[$Name]) }
        if ($recorded.Count -le $Index) {
            throw "there was no call $Index to ${Name}; the calls were: $($script:Calls -join ', ')"
        }
        return $recorded[$Index]
    }

    function Script:IndexOf {
        <#
            Position of one recorded call. -1 when it never happened, so an
            ordering assertion against a call that did not occur fails on the
            position rather than passing on a comparison with nothing.
        #>
        param([string]$Name)
        return [array]::IndexOf($script:Calls, $Name)
    }

    function Script:ExclusionsOf {
        <#
            The /XD and /XF pairs one recorded robocopy call was given, in order
            and with their flags. The source, the destination and the retry
            switches are how robocopy runs rather than what it keeps away, so
            they are left out: a test of the exclusions should not break when
            /R:3 becomes /R:5. Joined into one string so a mismatch prints both
            lists whole, and so an empty list compares as an empty string rather
            than vanishing in the pipeline on its way to Should.
        #>
        param([int]$Index)
        $arguments = @((Script:DetailOf -Name 'robocopy' -Index $Index).Arguments)
        $pairs = @()
        for ($i = 0; $i -lt $arguments.Count; $i++) {
            if ($arguments[$i] -cin '/XD', '/XF') {
                $pairs += "$($arguments[$i]) $($arguments[$i + 1])"
                $i++
            }
        }
        return ($pairs -join "`n")
    }

    function Script:PairsOf {
        <#
            A plan's exclusion list in the shape Script:ExclusionsOf returns, so
            the two can be compared as one string each.
        #>
        param([object[]]$Exclusions)
        $pairs = @()
        for ($i = 0; $i -lt $Exclusions.Count; $i += 2) {
            $pairs += "$($Exclusions[$i]) $($Exclusions[$i + 1])"
        }
        return ($pairs -join "`n")
    }

    # Write-DeployStep is the one stub that is not about ordering. The real one
    # writes to $script:DeployStartedUtc, which only exists when the script runs
    # as a script; lifting it would make every function under test depend on a
    # variable this file would then have to fake anyway.
    function Script:Write-DeployStep {
        param([Parameter(Mandatory = $true)][string]$Message)
        $script:Steps += $Message
    }

    # PowerShell resolves a function before an external application, so naming a
    # stub `robocopy` is enough to intercept the call -- no shim on PATH, and the
    # call site keeps the `& robocopy` spelling that ships.
    #
    # It writes to the success stream on purpose. Real robocopy prints a job
    # header and a summary table there even under /NFL /NDL /NP, which is exactly
    # the hazard the `| Write-Host` on both call sites exists to contain: inside a
    # function whose return value is captured, that chatter is handed back as if
    # it were the record.
    function Script:robocopy {
        Script:Record -Name 'robocopy' -Detail @{ Arguments = $args }
        Write-Output '   Files :        41         0        41         0'
        $global:LASTEXITCODE = $script:RobocopyExit
    }

    function Script:icacls {
        Script:Record -Name 'icacls' -Detail @{ Arguments = $args }
        Write-Output 'processed file: C:\inetpub\pr-test\site'
        $global:LASTEXITCODE = $script:IcaclsExit
    }

    function Script:Resolve-SharedAssetSource {
        param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConfiguredPath = '')
        Script:Record -Name 'Resolve-SharedAssetSource'
        return $script:SharedAssetSource
    }

    function Script:Sync-SharedSiteAssets {
        param($SourceRoot, $DestinationRoot, $DirectoryList)
        Script:Record -Name 'Sync-SharedSiteAssets' -Detail @{
            SourceRoot = $SourceRoot; DestinationRoot = $DestinationRoot; DirectoryList = $DirectoryList
        }
    }

    function Script:Sync-ServerOwnedAssets {
        param($SourceRoot, $DestinationRoot, $RelativePaths)
        Script:Record -Name 'Sync-ServerOwnedAssets' -Detail @{
            SourceRoot = $SourceRoot; DestinationRoot = $DestinationRoot; RelativePaths = $RelativePaths
        }
    }

    function Script:Get-ServerOwnedThemeFilePaths {
        param($SiteRoot, $FileNames)
        Script:Record -Name 'Get-ServerOwnedThemeFilePaths' -Detail @{ SiteRoot = $SiteRoot; FileNames = $FileNames }
        return $script:DiscoveredThemeFiles
    }

    function Script:Get-MigrationFingerprint {
        param($SiteRoot)
        Script:Record -Name 'Get-MigrationFingerprint' -Detail @{ SiteRoot = $SiteRoot }
        return $script:MigrationFingerprint
    }

    function Script:Remove-PluginBuildArtifacts {
        param($Path)
        Script:Record -Name 'Remove-PluginBuildArtifacts' -Detail @{ Path = $Path }
    }

    function Script:Write-PluginAssemblyReport {
        param($SiteRoot)
        Script:Record -Name 'Write-PluginAssemblyReport' -Detail @{ SiteRoot = $SiteRoot }
        return 7
    }

    function Script:Write-RuntimeConfiguration {
        param($Path, $Connection, $ExistingWebConfig)
        Script:Record -Name 'Write-RuntimeConfiguration' -Detail @{
            Path = $Path; Connection = $Connection; ExistingWebConfig = $ExistingWebConfig
        }
    }

    function Script:Ensure-AppPool {
        param($Name)
        Script:Record -Name 'Ensure-AppPool' -Detail @{ Name = $Name }
    }

    function Script:Ensure-Website {
        param($Name, $PhysicalPath, $HostHeader, $PoolName, $Thumbprint)
        Script:Record -Name 'Ensure-Website' -Detail @{
            Name = $Name; PhysicalPath = $PhysicalPath; HostHeader = $HostHeader
            PoolName = $PoolName; Thumbprint = $Thumbprint
        }
    }

    function Script:Invoke-OrphanedAssemblyReconciliation {
        param($SiteRoot, $ArtifactRoot, $QuarantineRoot)
        Script:Record -Name 'Invoke-OrphanedAssemblyReconciliation' -Detail @{
            SiteRoot = $SiteRoot; ArtifactRoot = $ArtifactRoot; QuarantineRoot = $QuarantineRoot
        }
        return 0
    }

    function Script:Write-OrphanedBlockReport {
        param($SiteRoot, $ArtifactRoot)
        Script:Record -Name 'Write-OrphanedBlockReport' -Detail @{ SiteRoot = $SiteRoot; ArtifactRoot = $ArtifactRoot }
        return 0
    }

    # A function rather than a root-level BeforeEach, which Pester 6 refuses in
    # the container. Each Describe calls it; there is one copy of the fixture.
    function Script:Reset-Fixture {
        $script:Calls = @()
        $script:Arguments = @{}
        $script:Steps = @()
        # 1 is robocopy for "files were copied", which is the ordinary success
        # here. Anything up to 7 is also success; 8 and above is not.
        $script:RobocopyExit = 1
        $script:IcaclsExit = 0
        $script:MigrationFingerprint = 'before'
        $script:DiscoveredThemeFiles = @()

        $script:Root = Join-Path $TestDrive ('deploy-' + [guid]::NewGuid().ToString('n'))
        $script:SitePath = Join-Path $script:Root 'site'
        $script:ExtractPath = Join-Path $script:Root 'extract'
        $script:BackupRoot = Join-Path $script:Root 'backups'
        $script:SharedAssetSource = Join-Path $script:Root 'base-site'
        $script:ManifestPath = Join-Path $script:Root 'state/manifest.json'

        Ensure-Directory -Path $script:SitePath
        Ensure-Directory -Path $script:ExtractPath
        Ensure-Directory -Path $script:SharedAssetSource
    }

    function Script:Assert-DeployedCoreVersion {
        param($SiteRoot, $ArtifactRoot)
        Script:Record -Name 'Assert-DeployedCoreVersion' -Detail @{ SiteRoot = $SiteRoot; ArtifactRoot = $ArtifactRoot }
    }
}

Describe 'Invoke-DedicatedSiteReplace' {

    BeforeEach {
        Script:Reset-Fixture

        $script:Replace = {
            param([hashtable]$Override = @{})
            $splat = @{
                SitePath               = $script:SitePath
                ExtractPath            = $script:ExtractPath
                SiteName               = 'pr-1234'
                AppPoolName            = 'pr-1234-pool'
                HostName               = 'pr-1234.pr.passion.team'
                ConnectionString       = 'Server=db;Database=pr1234;'
                ExistingWebConfig      = '<configuration />'
                SharedAssetSourcePath  = ''
                SharedAssetDirectories = 'Themes,Content,Assets,Styles,Plugins'
                ServerOwnedDirectories = @('Assets/Fonts/FontAwesome')
                ServerOwnedThemeFiles  = @('_variables.less')
            }
            foreach ($key in $Override.Keys) { $splat[$key] = $Override[$key] }
            return Invoke-DedicatedSiteReplace @splat
        }
    }

    It 'wipes the site and moves the artifact into its place' {
        $marker = Join-Path $script:SitePath 'old.txt'
        Set-Content -Path $marker -Value 'the site being replaced'
        Set-Content -Path (Join-Path $script:ExtractPath 'web.config') -Value '<configuration />'

        & $script:Replace | Out-Null

        Test-Path $marker | Should -BeFalse -Because 'a dedicated site is replaced wholesale, not merged into'
        Test-Path (Join-Path $script:SitePath 'web.config') | Should -BeTrue
        Test-Path $script:ExtractPath | Should -BeFalse -Because 'Move-Item is a rename, so the artifact directory is gone afterwards'
    }

    It 'reads the preserved files before the wipe and writes them back after it' {
        # The ordering this function exists to hold. The stash has to be taken
        # while the directory is still there, and put back once the artifact has
        # landed. Getting it backwards destroys the site: the wipe takes
        # web.ConnectionStrings.config with it and every request 500s before Rock
        # starts, including the error page.
        $preserved = 'web.ConnectionStrings.config'
        Set-Content -Path (Join-Path $script:SitePath $preserved) -Value '<connectionStrings />' -NoNewline

        & $script:Replace -Override @{ PreservedFiles = @($preserved) } | Out-Null

        $restored = Join-Path $script:SitePath $preserved
        Test-Path $restored | Should -BeTrue
        (Get-Content -Raw -Path $restored) | Should -Be '<connectionStrings />'
    }

    It 'leaves a preserved file alone when the artifact ships its own copy' {
        # Gap-filling only, the same rule the overlay follows. The artifact
        # shipping the file means this branch is authoritative for it.
        $preserved = 'web.ConnectionStrings.config'
        Set-Content -Path (Join-Path $script:SitePath $preserved) -Value 'from the old site' -NoNewline
        Set-Content -Path (Join-Path $script:ExtractPath $preserved) -Value 'from the artifact' -NoNewline

        & $script:Replace -Override @{ PreservedFiles = @($preserved) } | Out-Null

        (Get-Content -Raw -Path (Join-Path $script:SitePath $preserved)) | Should -Be 'from the artifact'
    }

    It 'grants the app pool modify rights after the move and before anything writes' {
        & $script:Replace | Out-Null

        Script:IndexOf 'icacls' | Should -BeGreaterThan -1 -Because 'without the grant Rock cannot compile its themes and serves stale .css behind a passing health check'
        Script:IndexOf 'icacls' | Should -BeLessThan (Script:IndexOf 'Sync-SharedSiteAssets') -Because 'the ACE is inheritable, so it has to exist before the overlay writes the files it should cover'

        $grant = (Script:DetailOf -Name 'icacls').Arguments
        $grant | Should -Contain '/grant'
        ($grant -join ' ') | Should -Match 'IIS AppPool\\pr-1234-pool:\(OI\)\(CI\)\(M\)'
    }

    It 'stops the deploy when the grant fails' {
        # A grant that fails quietly is the same outcome as no grant at all, and
        # that outcome went unnoticed from January to August 2026.
        $script:IcaclsExit = 5

        { & $script:Replace } | Should -Throw '*modify rights*'
    }

    It 'restores the server-owned paths after the shared-asset overlay, never before' {
        & $script:Replace | Out-Null

        $overlay = Script:IndexOf 'Sync-SharedSiteAssets'
        $restore = Script:IndexOf 'Sync-ServerOwnedAssets'

        $overlay | Should -BeGreaterThan -1
        $restore | Should -BeGreaterThan $overlay -Because 'the overlay copies only what is absent, so running the replacing pass first leaves it nothing to do and logs a successful restore that changed nothing'
    }

    It 'discovers the theme overrides against the base site, not the new one' {
        # Both wrong answers are silent. Asking $SitePath here finds the
        # artifact's stock copies and restores them onto themselves.
        & $script:Replace | Out-Null

        (Script:DetailOf -Name 'Get-ServerOwnedThemeFilePaths').SiteRoot | Should -Be $script:SharedAssetSource
        (Script:DetailOf -Name 'Sync-ServerOwnedAssets').SourceRoot | Should -Be $script:SharedAssetSource
        (Script:DetailOf -Name 'Sync-ServerOwnedAssets').DestinationRoot | Should -Be $script:SitePath
    }

    It 'carries the discovered theme files alongside the server-owned directories' {
        $script:DiscoveredThemeFiles = @('Themes/Rock/Styles/_variables.less')

        & $script:Replace | Out-Null

        $paths = @((Script:DetailOf -Name 'Sync-ServerOwnedAssets').RelativePaths)
        $paths | Should -Contain 'Assets/Fonts/FontAwesome'
        $paths | Should -Contain 'Themes/Rock/Styles/_variables.less'
    }

    It 'strips the plugin build artifacts again after the overlay has backfilled Plugins' {
        & $script:Replace | Out-Null

        $strip = Script:IndexOf 'Remove-PluginBuildArtifacts'
        $strip | Should -BeGreaterThan (Script:IndexOf 'Sync-SharedSiteAssets') -Because 'the base site brings its own Plugins/*/bin along with the overlay, after the strip that ran on the artifact'
        (Script:DetailOf -Name 'Remove-PluginBuildArtifacts').Path | Should -Be $script:SitePath -Because 'a strip aimed at the extract path satisfies any ordering check while doing nothing at all'
    }

    It 'configures the site only once the files it configures are in place' {
        & $script:Replace | Out-Null

        $config = Script:IndexOf 'Write-RuntimeConfiguration'
        $config | Should -BeGreaterThan (Script:IndexOf 'Sync-ServerOwnedAssets')
        Script:IndexOf 'Ensure-AppPool' | Should -BeGreaterThan $config
        Script:IndexOf 'Ensure-Website' | Should -BeGreaterThan (Script:IndexOf 'Ensure-AppPool')
    }

    It 'hands the caller-read web.config on to the runtime configuration' {
        # It cannot read the file itself: it deleted the directory holding it.
        & $script:Replace -Override @{ ExistingWebConfig = '<configuration><appSettings /></configuration>' } | Out-Null

        (Script:DetailOf -Name 'Write-RuntimeConfiguration').ExistingWebConfig |
            Should -Be '<configuration><appSettings /></configuration>'
    }

    It 'returns one record saying there is nowhere to roll back to' {
        $result = & $script:Replace

        @($result).Count | Should -Be 1 -Because 'the deploy body reads fields off this, and a second object in the success stream makes the first one unreachable'
        $result.BackupPath | Should -Be '' -Because 'this branch deleted the directory it deployed into; it did not copy it aside'
        $result.PreDeployMigrationFingerprint | Should -BeNullOrEmpty
        $result.Keys | Sort-Object | Should -Be @('BackupPath', 'PreDeployMigrationFingerprint')
    }

    It 'never copies the site aside' {
        & $script:Replace | Out-Null

        Script:IndexOf 'robocopy' | Should -Be -1 -Because 'the returned record promises no backup, and a backup taken but not reported is worse than none'
    }
}

Describe 'Invoke-InPlaceOverlay' {

    BeforeEach {
        Script:Reset-Fixture

        Set-Content -Path (Join-Path $script:SitePath 'web.config') -Value '<configuration />'
        Set-Content -Path (Join-Path $script:ExtractPath 'web.config') -Value '<configuration />'

        # Made when the overlay is run rather than here, so an It that changes
        # what discovery finds before running it gets a plan that found it.
        $script:Overlay = {
            $script:Plan = Get-InPlaceOverlayPlan `
                -SitePath $script:SitePath `
                -ExtractPath $script:ExtractPath `
                -EnvironmentName 'production' `
                -BackupRoot $script:BackupRoot `
                -PreservedDirectories @('Content') `
                -PreservedFiles @('web.ConnectionStrings.config') `
                -ServerOwnedDirectories @('Assets/Fonts/FontAwesome') `
                -ServerOwnedThemeFiles @('_variables.less')

            # The deploy body makes the plan before it downloads anything, long
            # before the overlay runs. Starting the recording over here keeps it
            # the overlay's alone, so "first" below means first in the overlay.
            $script:Calls = @()
            $script:Arguments = @{}
            $script:Steps = @()

            return Invoke-InPlaceOverlay `
                -Plan $script:Plan `
                -Sha 'abc1234' `
                -ManifestPath $script:ManifestPath `
                -ConnectionString 'Server=db;Database=rock;' `
                -ExistingWebConfig '<configuration />'
        }
    }

    It 'reads the migration log before it copies anything' {
        # Afterwards the reading answers a different question. The comparison it
        # feeds is "did migrations run during this deploy", and a fingerprint
        # taken after the copy can only say "did they run since I asked".
        & $script:Overlay | Out-Null

        $fingerprint = Script:IndexOf 'Get-MigrationFingerprint'
        $fingerprint | Should -Be 0
        $fingerprint | Should -BeLessThan (Script:IndexOf 'robocopy')
        (Script:DetailOf -Name 'Get-MigrationFingerprint').SiteRoot | Should -Be $script:SitePath
    }

    It 'backs the site up before it copies the artifact over it' {
        & $script:Overlay | Out-Null

        @($script:Calls | Where-Object { $_ -eq 'robocopy' }).Count |
            Should -Be 2 -Because 'the backup copy and the deploy copy'
        $script:Calls[(Script:IndexOf 'robocopy')] | Should -Be 'robocopy'
    }

    It 'refuses to deploy when the backup fails' {
        # 8 and above is robocopy for "at least one file did not copy". Deploying
        # on top of a backup that is missing files removes the way back.
        $script:RobocopyExit = 8

        { & $script:Overlay } | Should -Throw '*Backup failed*'
    }

    It 'excludes the preserved directories from the backup' {
        & $script:Overlay | Out-Null

        $backup = @((Script:DetailOf -Name 'robocopy' -Index 0).Arguments)
        $backup | Should -Contain '/XD'
        ($backup -join ' ') | Should -Match ([regex]::Escape((Join-Path $script:SitePath 'Content')))
    }

    It 'builds the copy exclusions from all four lists, against the artifact tree' {
        # robocopy matches /XD and /XF against the source, so an exclusion spelled
        # from $SitePath excludes nothing and reads as if it excluded something.
        $script:DiscoveredThemeFiles = @('Themes/Rock/Styles/_variables.less')

        & $script:Overlay | Out-Null

        $copy = ((Script:DetailOf -Name 'robocopy' -Index 1).Arguments -join ' ')
        foreach ($excluded in @('Content', 'web.ConnectionStrings.config', 'Assets/Fonts/FontAwesome', 'Themes/Rock/Styles/_variables.less')) {
            $native = ConvertTo-NativePath -Path (Join-Path $script:ExtractPath $excluded)
            $copy | Should -Match ([regex]::Escape($native)) -Because "$excluded must be kept away from the artifact's copy"
        }
    }

    It 'hands robocopy the exclusions the plan names, and no others' {
        # The plan is what the dry run printed and what the operator approved
        # before ticking apply. An exclusion robocopy is given beyond it is a
        # decision nobody read; one it is not given is a promise the copy breaks.
        $script:DiscoveredThemeFiles = @('Themes/Rock/Styles/_variables.less')

        & $script:Overlay | Out-Null

        @($script:Plan.BackupExclusions).Count | Should -BeGreaterThan 0 -Because 'an empty plan matches an empty command line and proves nothing'
        @($script:Plan.CopyExclusions).Count | Should -BeGreaterThan 0 -Because 'an empty plan matches an empty command line and proves nothing'
        Script:ExclusionsOf -Index 0 | Should -BeExactly (Script:PairsOf -Exclusions $script:Plan.BackupExclusions)
        Script:ExclusionsOf -Index 1 | Should -BeExactly (Script:PairsOf -Exclusions $script:Plan.CopyExclusions)
    }

    It 'keeps away from the copy the theme file the dry run says it will keep' {
        # The dry run's "Would keep this site's own theme override files" line is
        # read off the plan's ThemeOverrides. A file named there and missing from
        # robocopy's /XF list is production's brand overwritten by upstream's
        # empty pair, under a plan that said it would not be.
        $themeFile = 'Themes/Rock/Styles/_variables.less'
        $script:DiscoveredThemeFiles = @($themeFile)

        & $script:Overlay | Out-Null

        (@($script:Plan.ThemeOverrides) -ccontains $themeFile) | Should -BeTrue -Because 'this is the list the dry run reports'
        $native = ConvertTo-NativePath -Path (Join-Path $script:ExtractPath $themeFile)
        ((Script:ExclusionsOf -Index 1) -split "`n" -ccontains "/XF $native") | Should -BeTrue -Because 'robocopy matches exclusions against the source tree, and /XD against a file name excludes nothing'
    }

    It 'backs up into the directory the dry run named' {
        # The dry run prints "Would back up <site> to <directory>\<timestamp>",
        # and the operator reads that line to check the backup root before
        # ticking apply. The leaf is the only part a dry run cannot know.
        $result = & $script:Overlay

        (Split-Path -Parent $result.BackupPath) | Should -BeExactly $script:Plan.BackupDirectory
        $script:Plan.BackupDirectory | Should -BeExactly (Join-Path $script:BackupRoot 'production')
    }

    It 'reconciles orphaned assemblies while the pool is still stopped' {
        & $script:Overlay | Out-Null

        $reconcile = Script:IndexOf 'Invoke-OrphanedAssemblyReconciliation'
        $reconcile | Should -BeGreaterThan -1
        $reconcile | Should -BeLessThan (Script:IndexOf 'Write-RuntimeConfiguration')
        (Script:DetailOf -Name 'Invoke-OrphanedAssemblyReconciliation').QuarantineRoot |
            Should -Match 'quarantined-orphans' -Because 'the quarantine goes inside the backup, so one rollback restores both'
    }

    It 'checks the deployed core version after the copy and before the site is configured' {
        & $script:Overlay | Out-Null

        $assert = Script:IndexOf 'Assert-DeployedCoreVersion'
        $assert | Should -BeGreaterThan (Script:IndexOf 'Invoke-OrphanedAssemblyReconciliation')
        $assert | Should -BeLessThan (Script:IndexOf 'Write-RuntimeConfiguration')
    }

    It 'returns one record carrying the backup path and the pre-deploy fingerprint' {
        $script:MigrationFingerprint = 'sha256:before'

        $result = & $script:Overlay

        @($result).Count | Should -Be 1 -Because "robocopy prints a job summary to the success stream; without the pipe to Write-Host on both call sites it is handed back as if it were the record"
        $result.BackupPath | Should -Not -BeNullOrEmpty
        $result.BackupPath | Should -Match 'abc1234' -Because 'a backup directory that does not name the sha it replaced cannot be matched to a deploy'
        $result.PreDeployMigrationFingerprint | Should -Be 'sha256:before'
        $result.Keys | Sort-Object | Should -Be @('BackupPath', 'PreDeployMigrationFingerprint')
    }

    It 'creates the backup directory it hands back' {
        $result = & $script:Overlay

        Test-Path $result.BackupPath | Should -BeTrue
    }

    It 'never runs the shared-asset overlay' {
        # Production deploys this way, onto a live site with its own Plugins tree
        # maintained outside git. Backfilling it from another site is exactly the
        # wrong thing to do here.
        & $script:Overlay | Out-Null

        Script:IndexOf 'Sync-SharedSiteAssets' | Should -Be -1
        Script:IndexOf 'Sync-ServerOwnedAssets' | Should -Be -1
        Script:IndexOf 'icacls' | Should -Be -1 -Because 'this branch copies into a directory that already carries the right ACEs'
    }
}

Describe 'Get-InPlaceOverlayPlan' {

    BeforeEach {
        Script:Reset-Fixture

        $script:PlanFor = {
            return Get-InPlaceOverlayPlan `
                -SitePath $script:SitePath `
                -ExtractPath $script:ExtractPath `
                -EnvironmentName 'production' `
                -BackupRoot $script:BackupRoot `
                -ServerOwnedThemeFiles @('_variables.less')
        }
    }

    It 'discovers the theme overrides against the live site' {
        # The question here is which files production has that the artifact must
        # not overwrite. Asking $ExtractPath answers "all of them" -- every theme
        # in the artifact ships the pair -- and excludes the override file from
        # themes v19 adds and the box has never had. theme.less imports it
        # unconditionally, so those themes stop compiling.
        & $script:PlanFor | Out-Null

        (Script:DetailOf -Name 'Get-ServerOwnedThemeFilePaths').SiteRoot | Should -Be $script:SitePath
    }

    It 'changes nothing, because the dry run makes it too' {
        # The deploy body makes this plan before it forks into the dry run, so
        # whatever this does a dry run does as well -- and a dry run is the one
        # command an operator runs on production on the promise that it touches
        # nothing.
        & $script:PlanFor | Out-Null

        Script:IndexOf 'robocopy' | Should -Be -1
        Test-Path $script:BackupRoot | Should -BeFalse -Because 'the backup directory belongs to the apply run'
    }
}

Describe 'the two branches as one interface' {

    BeforeEach { Script:Reset-Fixture }

    It 'both return the same fields, so the deploy body never has to ask which ran' {
        Set-Content -Path (Join-Path $script:SitePath 'web.config') -Value '<configuration />'

        $dedicated = Invoke-DedicatedSiteReplace `
            -SitePath $script:SitePath -ExtractPath $script:ExtractPath `
            -SiteName 'pr-1' -AppPoolName 'pr-1-pool' -HostName 'pr-1.pr.passion.team' `
            -SharedAssetDirectories 'Themes'

        Ensure-Directory -Path $script:ExtractPath
        Ensure-Directory -Path $script:SitePath

        $plan = Get-InPlaceOverlayPlan `
            -SitePath $script:SitePath -ExtractPath $script:ExtractPath `
            -EnvironmentName 'production' -BackupRoot $script:BackupRoot
        $inPlace = Invoke-InPlaceOverlay -Plan $plan -Sha 'abc1234' -ManifestPath $script:ManifestPath

        ($dedicated.Keys | Sort-Object) | Should -Be ($inPlace.Keys | Sort-Object)
    }
}
