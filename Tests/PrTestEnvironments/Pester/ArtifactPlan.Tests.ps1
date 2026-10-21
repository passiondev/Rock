<#
    .github/scripts/Get-ArtifactPlan.ps1 decides whether a run of pr-test-artifact.yml
    has to compile anything at all, judging each changed path with the classifier
    in .github/scripts/ArtifactPaths.psm1.

    A full build is 27 minutes on a Windows runner. Most of what changes between two
    deploys of this site is Lava, markup and theme assets that the build copies into
    the artifact verbatim, so for those the compiled output of an earlier artifact is
    exactly what a fresh build would produce. The plan finds such an artifact and
    says "repackage" instead of "build".

    The cost of getting it wrong is lopsided. A needless build is half an hour. A
    wrong repackage ships source where compiled output belongs, or stale compiled
    output beside new source, and nothing downstream checks for that. So the cases
    here are mostly about the plan saying "build" when it must.

    The functions are lifted with Import-ScriptFunction and called directly. The
    rules come from the real artifact-paths.json, because the rules *are* the
    behaviour: a test against a hand-written rule list would pass while the shipped
    list classed a compiled path as patchable.

    Invoke-ArtifactPlan is the whole script short of writing its outputs, and it
    is handed the bucket, GitHub and git rather than calling them. Its cases hand
    it an artifact store that is a listing held in memory, and stand-ins for the
    other two that answer, or fail, as the case needs. That is how an empty
    bucket, a bucket that cannot be listed and a GitHub that will not answer are
    each shown to cost a build or a tier of the search, and never the run.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:PlanScript = Get-RepositoryPath '.github/scripts/Get-ArtifactPlan.ps1'
    $script:RulePath = Get-RepositoryPath '.github/scripts/artifact-paths.json'

    # The classifier and the artifact address are modules the scripts import;
    # the rest is the plan's own. Reading the bucket listing is the address
    # module's job, and ArtifactRecord.Tests.ps1 covers it.
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactPaths.psm1') -Force
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactRecord.psm1') -Force
    . (Import-ScriptFunction -Path $script:PlanScript -Name @(
        'Get-ArtifactBaseCandidate',
        'Select-ArtifactBase',
        'Invoke-ArtifactPlan'))

    $script:Rules = Get-Content -Raw -Path $script:RulePath | ConvertFrom-Json
    $script:GeneratedThemes = @('RockNextGen', 'RockManagerNextGen', 'NextGenCheckin')

    # A listing entry as ConvertFrom-ArtifactListing returns it. Commits are a
    # repeated hex digit so a failure message says which one it got.
    function New-Artifact {
        param(
            [Parameter(Mandatory = $true)][string]$Slug,
            [Parameter(Mandatory = $true)][string]$Digit,
            [Parameter(Mandatory = $true)][int]$DaysAgo
        )
        $sha = $Digit * 40
        return [pscustomobject]@{
            Slug = $Slug
            Sha = $sha
            ObjectPath = (Get-ArtifactAddress -Slug $Slug -Sha $sha).ObjectPath
            Updated = ([DateTimeOffset]'2026-10-15T12:00:00Z').AddDays(-$DaysAgo)
        }
    }

    # Classifies one name-status line against the shipped rules.
    function Get-Class {
        param([Parameter(Mandatory = $true)][string]$Line)
        return Get-ArtifactChangeClass -NameStatus @($Line) -RuleSet $script:Rules -GeneratedThemeName $script:GeneratedThemes
    }

    # Stands in for `git diff --name-status --no-renames <candidate> <target>`.
    # The real one needs a fetch per candidate; what is under test is what the
    # plan does with the answer.
    function New-ChangeSource {
        param([Parameter(Mandatory = $true)][hashtable]$DiffBySha)
        return { param($Sha) $DiffBySha[$Sha] }.GetNewClosure()
    }
}

Describe 'Get-ArtifactChangeClass' {
    Context 'the changes the feature exists for' {
        It 'patches a Lava template into the artifact' {
            $change = Get-Class "M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava"

            $change.Status | Should -Be 'M'
            $change.Path | Should -Be 'RockWeb/Themes/Rock/Assets/Lava/PageNav.lava'
            $change.Class | Should -Be 'patch'
            $change.IsServerOwned | Should -BeFalse
        }

        It 'patches <Path>' -ForEach @(
            @{ Path = 'RockWeb/Blocks/Cms/HtmlContentDetail.ascx.cs' }
            @{ Path = 'RockWeb/Themes/Stark/Layouts/FullWidth.aspx' }
            @{ Path = 'RockWeb/Scripts/Rock/Controls/grid.js' }
            @{ Path = 'RockWeb/Themes/RockNextGenLegacy/Assets/x.lava' }
            # Compress-Archive packs everything under RockWeb, Markdown included,
            # so a README there ships like any other file.
            @{ Path = 'RockWeb/Themes/Rock/README.md' }
        ) {
            (Get-Class "M`t$Path").Class | Should -Be 'patch'
        }

        It 'keeps the status git reported, so a deletion is applied as one' {
            (Get-Class "D`tRockWeb/Assets/Lava/Retired.lava").Status | Should -Be 'D'
        }
    }

    Context 'changes that never reach the artifact' {
        It 'ignores <Path>' -ForEach @(
            @{ Path = 'README.md' }
            @{ Path = 'Rock.Frontend.Styles/README.md' }
            @{ Path = 'Documentation/PR-Test-Environments-Operator-Runbook.md' }
            @{ Path = 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1' }
            @{ Path = 'Tests/PrTestEnvironments/test_powershell_job.py' }
            @{ Path = '.github/workflows/staging-deploy.yml' }
        ) {
            (Get-Class "M`t$Path").Class | Should -Be 'ignore'
        }
    }

    Context 'paths a deploy keeps the server''s copy of' {
        It 'flags <Path> as server-owned and still patches it' -ForEach @(
            @{ Path = 'RockWeb/Themes/Rock/Styles/_variable-overrides.less' }
            @{ Path = 'RockWeb/Themes/Stark/Styles/_CSS-Overrides.less' }
            @{ Path = 'RockWeb/Assets/Fonts/FontAwesome/webfonts/fa-solid-900.woff2' }
            @{ Path = 'RockWeb/web.ConnectionStrings.config' }
        ) {
            $change = Get-Class "M`t$Path"
            $change.IsServerOwned | Should -BeTrue
            $change.Class | Should -Be 'patch'
        }

        It 'does not flag the theme file a deploy does take from the artifact' {
            (Get-Class "M`tRockWeb/Themes/Rock/Styles/theme.less").IsServerOwned | Should -BeFalse
        }
    }

    Context 'compiled output' {
        It 'builds when <Path> changes (<Why>)' -ForEach @(
            @{ Path = 'RockWeb/Bin/Rock.dll.refresh'; Why = 'NuGet and MSBuild write Bin' }
            @{ Path = 'RockWeb/bin/Rock.dll'; Why = 'IIS does not care about case, so neither can the match' }
            @{ Path = 'RockWeb/packages.config'; Why = 'restored into Bin' }
            @{ Path = 'RockWeb/Plugins/org_passion/Thing/Block.ascx.cs'; Why = 'plugins compile into Bin' }
            @{ Path = 'RockWeb/Themes/RockNextGen/Styles/theme.css'; Why = 'a generated NextGen theme' }
            @{ Path = 'RockWeb/Themes/nextgencheckin/Assets/x.png'; Why = 'generated theme, other case' }
            @{ Path = 'RockWeb/Styles/styles-v2/core.css'; Why = 'compiled SCSS' }
            @{ Path = 'RockWeb/Scripts/Rock/realtime.js.map'; Why = 'a webpack bundle beside hand-written scripts' }
            @{ Path = 'RockWeb/tsconfig.json'; Why = 'the build deletes it' }
            @{ Path = 'Rock/Model/Core/Person/Person.cs'; Why = 'no rule names it, and unknown means build' }
            @{ Path = 'Rock.Frontend.Styles/src/themes/RockNextGen/Assets/Lava/x.lava'; Why = 'Lava, but the source of a generated theme' }
            @{ Path = '.github/workflows/pr-test-artifact.yml'; Why = 'the build recipe' }
            @{ Path = '.github/scripts/artifact-paths.json'; Why = 'these rules' }
        ) {
            (Get-Class "M`t$Path").Class | Should -Be 'build'
        }

        It 'refuses to classify without the generated theme names' {
            # An empty list would leave {GeneratedTheme} matching nothing, and
            # RockWeb/Themes/RockNextGen/** would fall through to the RockWeb/**
            # patch rule -- source copied over a compiled theme.
            { Get-ArtifactChangeClass -NameStatus @("M`tRockWeb/Themes/RockNextGen/Styles/theme.css") -RuleSet $script:Rules -GeneratedThemeName @() } |
                Should -Throw '*GeneratedTheme*'
        }
    }
}

Describe 'Get-ArtifactBaseCandidate' {
    It 'offers the exact commit first, whichever environment built it' {
        # Production deploying what staging already built is the whole of the
        # promotion path, and an artifact of the same commit needs no patch at all.
        $artifacts = @(
            New-Artifact -Slug 'production' -Digit '1' -DaysAgo 1
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 2
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('2' * 40) -ArtifactSlug 'production')

        $candidates[0].Sha | Should -Be ('2' * 40)
        $candidates[0].Slug | Should -Be 'staging'
    }

    It 'offers staging''s artifact of the exact commit over a newer one built elsewhere' {
        # A pull request whose head is the trunk tip builds that commit too. Its zip
        # holds the same source, but it is not the zip staging ran, and production
        # is meant to ship exactly that one.
        $artifacts = @(
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 3
            New-Artifact -Slug 'pr-42' -Digit '2' -DaysAgo 1
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('2' * 40) -ArtifactSlug 'production')

        $candidates[0].Slug | Should -Be 'staging'
    }

    It 'then offers this environment''s newest artifact, not an older one' {
        $artifacts = @(
            New-Artifact -Slug 'pr-42' -Digit '3' -DaysAgo 5
            New-Artifact -Slug 'pr-42' -Digit '4' -DaysAgo 1
            New-Artifact -Slug 'pr-7' -Digit '5' -DaysAgo 0
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('9' * 40) -ArtifactSlug 'pr-42')

        $candidates[0].Sha | Should -Be ('4' * 40)
        $candidates.Sha | Should -Not -Contain ('3' * 40)
        $candidates.Sha | Should -Not -Contain ('5' * 40)
    }

    It 'then offers the newest artifact of each pull request the commit came from' {
        # A merge to the trunk is the commit staging deploys next, and the pull
        # request it came from was usually deployed to its own site first. Its
        # head is the closest tree there is to the merge result.
        $artifacts = @(
            New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 3
            New-Artifact -Slug 'pr-12' -Digit '2' -DaysAgo 2
            New-Artifact -Slug 'pr-12' -Digit '3' -DaysAgo 4
            New-Artifact -Slug 'pr-15' -Digit '4' -DaysAgo 1
            New-Artifact -Slug 'pr-99' -Digit '5' -DaysAgo 0
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('9' * 40) -ArtifactSlug 'staging' -RelatedSlug @('pr-12', 'pr-15'))

        $candidates[1].Sha | Should -Be ('2' * 40)
        $candidates[2].Sha | Should -Be ('4' * 40)
        $candidates.Sha | Should -Not -Contain ('3' * 40)
        $candidates.Sha | Should -Not -Contain ('5' * 40)
    }

    It 'falls back to staging''s newest artifact last' {
        # A new pull request has no artifact of its own yet, and most branch off
        # the trunk staging deploys -- so a first deploy of a Lava-only change can
        # still skip the build.
        $artifacts = @(
            New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'pr-42' -Digit '2' -DaysAgo 3
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('9' * 40) -ArtifactSlug 'pr-42')

        $candidates.Sha | Should -Be @(('2' * 40), ('1' * 40))
    }

    It 'offers each commit once, however many ways it qualifies' {
        $artifacts = @(
            New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'pr-42' -Digit '1' -DaysAgo 1
        )

        $candidates = @(Get-ArtifactBaseCandidate -Artifact $artifacts -TargetSha ('9' * 40) -ArtifactSlug 'pr-42' -RelatedSlug @('pr-42'))

        $candidates | Should -HaveCount 1
    }

    It 'offers nothing when the bucket is empty' {
        @(Get-ArtifactBaseCandidate -Artifact @() -TargetSha ('9' * 40) -ArtifactSlug 'staging') | Should -HaveCount 0
    }
}

Describe 'Select-ArtifactBase' {
    BeforeAll {
        function Select-Base {
            param(
                [Parameter(Mandatory = $true)][object[]]$Candidate,
                [Parameter(Mandatory = $true)][scriptblock]$GetChange
            )
            return Select-ArtifactBase -Candidate $Candidate -GetChange $GetChange -RuleSet $script:Rules -GeneratedThemeName $script:GeneratedThemes
        }
    }

    It 'repackages the first artifact whose difference is all build-free' {
        $candidate = @(
            New-Artifact -Slug 'pr-42' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 1
        )
        $source = New-ChangeSource @{
            ('1' * 40) = @("M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava", "M`tDocumentation/notes.md")
            ('2' * 40) = @()
        }

        $selection = Select-Base -Candidate $candidate -GetChange $source

        $selection.Base.Sha | Should -Be ('1' * 40)
        $selection.Change.Path | Should -Be @('RockWeb/Themes/Rock/Assets/Lava/PageNav.lava', 'Documentation/notes.md')
    }

    It 'passes over an artifact whose difference needs compiling, and says which path' {
        $candidate = @(
            New-Artifact -Slug 'pr-42' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 1
        )
        $source = New-ChangeSource @{
            ('1' * 40) = @("M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava", "M`tRock/Model/Core/Person/Person.cs")
            ('2' * 40) = @("A`tRockWeb/Assets/Lava/New.lava")
        }

        $selection = Select-Base -Candidate $candidate -GetChange $source

        $selection.Base.Sha | Should -Be ('2' * 40)
        $selection.Rejected | Should -HaveCount 1
        $selection.Rejected[0].Candidate.Sha | Should -Be ('1' * 40)
        $selection.Rejected[0].Reason | Should -BeLike '*Rock/Model/Core/Person/Person.cs*'
    }

    It 'builds when no artifact qualifies, and keeps every reason' {
        $candidate = @(New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 0)
        $source = New-ChangeSource @{ ('1' * 40) = @("M`tRockWeb/Bin/Rock.dll.refresh") }

        $selection = Select-Base -Candidate $candidate -GetChange $source

        # Asserted non-null first: a $null result also has a null Base, and
        # piping $null to -HaveCount 1 counts it as one item.
        $selection | Should -Not -BeNullOrEmpty
        $selection.Base | Should -BeNullOrEmpty
        @($selection.Rejected) | Should -HaveCount 1
        $selection.Rejected[0].Reason | Should -BeLike '*RockWeb/Bin/Rock.dll.refresh*'
    }

    It 'still reports the nearest difference when it builds, so a server-owned change is warned about' {
        # A theme override edited beside a C# change builds rather than
        # repackages, and the deploy keeps the server's copy either way.
        $candidate = @(
            New-Artifact -Slug 'pr-42' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 1
        )
        $source = New-ChangeSource @{
            ('1' * 40) = @("M`tRockWeb/Themes/Rock/Styles/_variable-overrides.less", "M`tRock/Model/Core/Person/Person.cs")
            ('2' * 40) = @("M`tRockWeb/Themes/Rock/Styles/_css-overrides.less", "M`tRockWeb/Bin/Rock.dll.refresh")
        }

        $selection = Select-Base -Candidate $candidate -GetChange $source

        $selection.Base | Should -BeNullOrEmpty
        @($selection.Change | Where-Object { $_.IsServerOwned } | ForEach-Object { $_.Path }) |
            Should -Be @('RockWeb/Themes/Rock/Styles/_variable-overrides.less')
    }

    It 'passes over an artifact whose commit cannot be diffed' {
        # A force-push leaves the artifact of the old head in the bucket and the
        # commit nowhere GitHub will serve it. That candidate is unusable; the
        # next one may be fine.
        $candidate = @(
            New-Artifact -Slug 'pr-42' -Digit '1' -DaysAgo 0
            New-Artifact -Slug 'staging' -Digit '2' -DaysAgo 1
        )
        $source = {
            param($Sha)
            if ($Sha -eq ('1' * 40)) { throw "fatal: remote error: upload-pack: not our ref $Sha" }
            return @("M`tRockWeb/Assets/Lava/PageNav.lava")
        }

        $selection = Select-Base -Candidate $candidate -GetChange $source

        $selection.Base.Sha | Should -Be ('2' * 40)
        $selection.Rejected[0].Reason | Should -BeLike '*not our ref*'
    }
}

Describe 'Invoke-ArtifactPlan' {
    # The plan's own promise is that it never fails the run: whatever it cannot
    # find out costs a build, or one tier of the search. These hand it a world
    # that fails in each way the real one can, and read the plan and the summary
    # it would write.

    BeforeAll {
        # The commit every case plans for. No artifact here is of it, so the
        # exact-commit tier never fires.
        $script:Target = '9' * 40

        # An artifact store holding a listing and nothing else, which is all the
        # plan asks of one.
        function New-ListingStore {
            param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifact)
            return @{ List = { $Artifact }.GetNewClosure() }
        }

        # The plan for the target on staging, against the shipped rules. GitHub
        # names no pull request and nothing may be diffed, unless a case says
        # otherwise: a diff nobody expected lands in the summary as a candidate
        # that could not be diffed, and fails the exact comparison.
        function Invoke-Plan {
            param(
                [Parameter(Mandatory = $true)][hashtable]$Store,
                [scriptblock]$GetChange = { param($Sha) throw "nothing was meant to be diffed, but $Sha was" },
                [scriptblock]$GetRelatedPulls = { },
                [switch]$ForceBuild
            )
            $themes = $script:GeneratedThemes
            $getThemes = { $themes }.GetNewClosure()
            return Invoke-ArtifactPlan -TargetSha $script:Target -ArtifactSlug 'staging' -Store $Store `
                -GetRelatedPulls $GetRelatedPulls -GetChange $GetChange `
                -GetGeneratedThemeName $getThemes `
                -RuleSetPath $script:RulePath -ForceBuild:$ForceBuild
        }
    }

    It 'builds when the bucket holds no artifact yet' {
        # A first deploy. gsutil says so with exit 1 and "matched no objects",
        # which the gsutil store turns into an empty listing
        # (ArtifactRecord.Tests.ps1); that is a first build, not a failure.
        $result = Invoke-Plan -Store (New-ListingStore -Artifact @())

        # The three outputs the repackage and package jobs branch on, in the
        # order Write-ArtifactPlan writes them.
        @($result.Plan.Keys) | Should -Be @('mode', 'base_sha', 'base_object_path')
        $result.Plan.mode | Should -Be 'build'
        $result.Plan.base_sha | Should -Be ''
        $result.Plan.base_object_path | Should -Be ''
        $result.Summary | Should -Be @(
            '### Artifact plan'
            ''
            'Building: none of 0 candidate artifact(s) differs from 9999999999999999999999999999999999999999 in files alone.'
        )
    }

    It 'repackages an artifact that differs in files alone, and lists what it patches' {
        # The control for the cases below: the same plan, with a world that
        # answers.
        $store = New-ListingStore -Artifact @(New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 0)
        $source = New-ChangeSource @{ ('1' * 40) = @("M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava") }

        $result = Invoke-Plan -Store $store -GetChange $source

        $result.Plan.mode | Should -Be 'repackage'
        $result.Plan.base_sha | Should -Be '1111111111111111111111111111111111111111'
        $result.Plan.base_object_path | Should -Be 'pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-staging-1111111.zip'
        $result.Summary | Should -Be @(
            '### Artifact plan'
            ''
            'Repackaging `pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-staging-1111111.zip` with 1 changed file(s); no build.'
            ''
            '- `M` `RockWeb/Themes/Rock/Assets/Lava/PageNav.lava`'
        )
    }

    It 'builds, rather than failing the run, when the bucket cannot be listed' {
        # A credential that has lost storage.objects.list, say. The plan cannot
        # know what is there, and a build is what not knowing costs.
        $store = @{ List = { throw 'gsutil ls failed (exit 1): AccessDeniedException: 403 Access denied.' } }

        $result = Invoke-Plan -Store $store

        $result.Plan.mode | Should -Be 'build'
        $result.Plan.base_object_path | Should -Be ''
        $result.Summary | Should -Be @(
            '### Artifact plan'
            ''
            'Building: the search for a base artifact failed -- gsutil ls failed (exit 1): AccessDeniedException: 403 Access denied.'
        )
    }

    Context 'when the base is the pull request the commit came from' {
        BeforeAll {
            # Staging's newest artifact needs a build; the pull request the
            # target was merged from has one that does not. Only the related
            # tier finds it.
            $script:MergeStore = New-ListingStore -Artifact @(
                New-Artifact -Slug 'staging' -Digit '1' -DaysAgo 1
                New-Artifact -Slug 'pr-12' -Digit '2' -DaysAgo 0
            )
            $script:MergeSource = New-ChangeSource @{
                ('1' * 40) = @("M`tRock/Model/Core/Person/Person.cs")
                ('2' * 40) = @("M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava")
            }
        }

        It 'repackages that pull request''s artifact when GitHub says which it was' {
            # The control: what a GitHub that will not answer gives up.
            $result = Invoke-Plan -Store $script:MergeStore -GetChange $script:MergeSource -GetRelatedPulls {
                param($Sha)
                if ($Sha -eq '9999999999999999999999999999999999999999') {
                    12
                }
            }

            $result.Plan.mode | Should -Be 'repackage'
            $result.Plan.base_sha | Should -Be '2222222222222222222222222222222222222222'
        }

        It 'searches without it, rather than failing the run, when GitHub cannot say' {
            # gh not signed in, rate-limited or down. That costs the related
            # tier and nothing else: the rest of the search still runs.
            $result = Invoke-Plan -Store $script:MergeStore -GetChange $script:MergeSource -GetRelatedPulls {
                param($Sha)
                throw "gh api exited 1 asking about $Sha"
            }

            $result.Plan.mode | Should -Be 'build'
            $result.Summary | Should -Be @(
                '### Artifact plan'
                ''
                '- Passed over `pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-staging-1111111.zip`: 1 path(s) need a build: Rock/Model/Core/Person/Person.cs'
                'Building: none of 1 candidate artifact(s) differs from 9999999999999999999999999999999999999999 in files alone.'
            )
        }
    }

    It 'builds without looking when a full build is asked for' {
        # force_build, or the rock:full-build label. The store throws if it is
        # read, and a throw would put a failed search in the summary, so the
        # exact summary is what shows the bucket was never listed.
        $store = @{ List = { throw 'the bucket was listed' } }

        $result = Invoke-Plan -Store $store -ForceBuild

        $result.Plan.mode | Should -Be 'build'
        $result.Summary | Should -Be @(
            '### Artifact plan'
            ''
            'Full build requested (`force_build`, or the `rock:full-build` label).'
        )
    }
}

Describe 'artifact-paths.json against the files it describes' {
    # The rules are a hand-kept list of where the build writes inside RockWeb and
    # of what the deploy keeps from the server. A new bundle or a renamed output
    # directory would fall through to the RockWeb/** patch rule, and the first
    # anyone heard of it would be a repackage copying source over the compiled
    # file. So these read the build's own configuration and the deploy script,
    # rather than trusting the list to have kept up.

    BeforeAll {
        # The names the plan reads from the tree at run time, read the same way.
        $script:TreeThemes = @(Get-ChildItem -Directory -Path (Get-RepositoryPath 'Rock.Frontend.Styles/src/themes') |
            ForEach-Object { $_.Name })

        # Every probe path that does not classify as build, so one failing run
        # names all of them rather than the first.
        function Get-PatchedProbe {
            param([Parameter(Mandatory = $true)][string[]]$Path)
            $change = @($Path | ForEach-Object { "M`t$_" })
            return @(Get-ArtifactChangeClass -NameStatus $change -RuleSet $script:Rules -GeneratedThemeName $script:TreeThemes |
                Where-Object { $_.Class -ne 'build' } |
                ForEach-Object { $_.Path })
        }
    }

    It 'builds when anything the plan, the repackage or the packager loads changes' {
        # A base judged by an older classifier is not to be trusted, so a change to
        # the classifier has to rule out every base -- and a base zipped, named or
        # recorded another way is not what a build would make now. Read from the
        # scripts rather than listed, because a further file they come to load
        # would otherwise fall through to the .github/** ignore rule.
        $scripts = @(
            '.github/scripts/Get-ArtifactPlan.ps1'
            '.github/scripts/New-RepackagedArtifact.ps1'
            '.github/scripts/New-PackagedArtifact.ps1'
        )
        $loaded = @($scripts | ForEach-Object {
            $body = Get-Content -Raw -Path (Get-RepositoryPath $_)
            [regex]::Matches($body, "Join-Path \`$PSScriptRoot '([^']+)'") | ForEach-Object { ".github/scripts/$($_.Groups[1].Value)" }
        } | Sort-Object -Unique)
        $loaded | Should -Not -BeNullOrEmpty

        Get-PatchedProbe -Path @($scripts + $loaded) | Should -BeNullOrEmpty
    }

    It 'builds every webpack bundle and its source map' {
        # Rock.JavaScript writes into RockWeb/Scripts/Rock beside hand-written
        # scripts, so its rules name files rather than the directory. A fourth
        # entry point would add a bundle no rule names.
        $configs = @(
            Get-RepositoryPath 'Rock.JavaScript/webpack.config.js'
            Get-RepositoryPath 'Rock.JavaScript/webpack.config.monaco.js'
            Get-RepositoryPath 'Rock.JavaScript.EditorJs/webpack.config.js'
        )

        $probe = @()
        foreach ($config in $configs) {
            $text = Get-Content -Raw -Path $config
            $output = [regex]::Match($text, 'path\.resolve\(\s*__dirname\s*,\s*"\.\./(RockWeb/[^"]+)"\s*\)')
            $output.Success | Should -BeTrue -Because "$config should still name its output directory the way this reads it"

            $bundles = @([regex]::Matches($text, 'filename:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            $bundles.Count | Should -BeGreaterThan 0 -Because "$config should still name its bundles the way this reads them"
            foreach ($bundle in $bundles) {
                # A templated name stands for every entry point; any one will do.
                $file = $bundle.Replace('[name]', 'probe')
                $probe += "$($output.Groups[1].Value)/$file"
                $probe += "$($output.Groups[1].Value)/$file.map"
            }
        }

        Get-PatchedProbe -Path $probe | Should -BeNullOrEmpty -Because 'webpack writes these, so a repackage would copy stale source over them'
    }

    It 'builds everything Rock.Frontend.Styles compiles into RockWeb' {
        # styles-v2 and the three NextGen themes are SCSS compiled at build time,
        # and the RockWeb copy of each holds only a .gitignore. A new source
        # directory would be a new compiled output.
        $root = Get-RepositoryPath 'Rock.Frontend.Styles'
        $mappings = Get-Content -Raw -Path (Get-RepositoryPath 'Rock.Frontend.Styles/obsidian.config.json') | ConvertFrom-Json

        $probe = @()
        foreach ($mapping in $mappings) {
            $destination = $mapping.destination -replace '^\.\./', ''
            foreach ($child in Get-ChildItem -Path (Join-Path $root $mapping.source)) {
                if ($child.PSIsContainer) {
                    $probe += "$destination/$($child.Name)/probe.css"
                }
                else {
                    $probe += "$destination/$([System.IO.Path]::ChangeExtension($child.Name, '.css'))"
                }
            }
        }

        $probe.Count | Should -BeGreaterThan 0 -Because 'an empty sweep proves nothing'
        Get-PatchedProbe -Path $probe | Should -BeNullOrEmpty -Because 'Rock.Frontend.Styles writes these'
    }

    It 'builds everything the Obsidian bundles write' {
        $sources = @(
            Get-RepositoryPath 'Rock.JavaScript.Obsidian/package.json'
            Get-RepositoryPath 'Rock.JavaScript.Obsidian/Framework/rollup.config.cjs'
            Get-RepositoryPath 'Rock.JavaScript.Obsidian.Blocks/rollup.config.cjs'
            Get-RepositoryPath 'Rock.JavaScript.Obsidian.Reporting/rollup.config.cjs'
        )

        $probe = @()
        foreach ($source in $sources) {
            $text = Get-Content -Raw -Path $source
            # package.json copies to "../RockWeb/Obsidian/"; the rollup configs
            # build theirs with path.join(workspacePath, "..", "RockWeb", ...).
            $targets = @(
                [regex]::Matches($text, '\.\./(RockWeb/[^"\\]+)') | ForEach-Object { $_.Groups[1].Value.TrimEnd('/') }
                [regex]::Matches($text, 'path\.join\(\s*\w+\s*,\s*"\.\."\s*,\s*"RockWeb"((?:\s*,\s*"[^"]+")*)\s*\)') | ForEach-Object {
                    'RockWeb' + (@([regex]::Matches($_.Groups[1].Value, '"([^"]+)"') | ForEach-Object { '/' + $_.Groups[1].Value }) -join '')
                }
            )
            $targets.Count | Should -BeGreaterThan 0 -Because "$source should still name where it writes the way this reads it"
            $probe += @($targets | ForEach-Object { "$_/probe.js" })
        }

        Get-PatchedProbe -Path $probe | Should -BeNullOrEmpty -Because 'the Obsidian build writes these'
    }

    It 'warns about every path the deploy keeps from the server' {
        # Mirrors the four lists at the top of Deploy-RockEnvironment.ps1. A list
        # that grows there and not here is a change the plan patches in without
        # saying the deploy will throw it away.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'), [ref]$tokens, [ref]$errors)

        $list = @{}
        foreach ($name in 'PreservedDirectories', 'PreservedFiles', 'ServerOwnedDirectories', 'ServerOwnedThemeFiles') {
            # Script level only: the functions take parameters of the same names.
            $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq $name
            }, $false)
            $assignment | Should -Not -BeNullOrEmpty -Because "Deploy-RockEnvironment.ps1 should still set `$$name"
            $list[$name] = @($assignment.Right.Expression.SafeGetValue())
        }

        $probe = @(
            $list.PreservedDirectories | ForEach-Object { "RockWeb/$_/probe.txt" }
            $list.PreservedFiles | ForEach-Object { "RockWeb/$_" }
            $list.ServerOwnedDirectories | ForEach-Object { "RockWeb/$_/probe.woff2" }
            $list.ServerOwnedThemeFiles | ForEach-Object { "RockWeb/Themes/AnyTheme/Styles/$_" }
        )
        $probe.Count | Should -BeGreaterThan 0 -Because 'an empty sweep proves nothing'

        $change = @($probe | ForEach-Object { "M`t$_" })
        $unflagged = @(Get-ArtifactChangeClass -NameStatus $change -RuleSet $script:Rules -GeneratedThemeName $script:TreeThemes |
            Where-Object { -not $_.IsServerOwned } |
            ForEach-Object { $_.Path })
        $unflagged | Should -BeNullOrEmpty -Because 'the deploy keeps the server''s copy of these, so the plan must say so'
    }
}
