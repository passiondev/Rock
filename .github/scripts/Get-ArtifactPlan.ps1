<#
.SYNOPSIS
    Decides whether pr-test-artifact.yml has to build, or can repackage an artifact
    it already has.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run the
    decision -- see Tests/PrTestEnvironments/Pester/ArtifactPlan.Tests.ps1. The
    whole of it is Invoke-ArtifactPlan, which is handed the bucket, GitHub and
    git rather than calling them; the script body builds the real ones and
    reports what it decided.

    A full build is about half an hour on a Windows runner, and most changes to
    this site are Lava, markup and theme assets the build copies into the artifact
    untouched. For those, an artifact already in the bucket holds exactly the
    compiled output a new build would produce, and New-RepackagedArtifact.ps1 can
    swap the changed files into a copy of it in a few minutes.

    The plan looks for such a base: an artifact whose commit differs from the
    target only in paths artifact-paths.json classes as patch or ignore. Finding
    none, or failing to look, it says build. It never fails the run -- a plan it
    cannot make costs a build, not a deploy.

.PARAMETER TargetSha
    The commit this run packages. Must be checked out.

.PARAMETER ArtifactSlug
    This run's artifact folder: pr-<number>, staging or production.

.PARAMETER Bucket
    The deployment bucket the artifacts live in.

.PARAMETER Repository
    owner/name, for asking GitHub which pull requests a commit came from.

.PARAMETER ForceBuild
    Skip the search and build. The force_build input, or the rock:full-build label.

.OUTPUTS
    Writes mode (build or repackage), base_sha and base_object_path to
    GITHUB_OUTPUT, and what it considered to the step summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetSha,
    [Parameter(Mandatory = $true)][string]$ArtifactSlug,
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $true)][string]$Repository,
    [switch]$ForceBuild
)

$ErrorActionPreference = "Stop"

function Get-ArtifactBaseCandidate {
    <#
        .SYNOPSIS
        Orders the artifacts worth diffing against, most promising first.

        .DESCRIPTION
        Each candidate costs a fetch and a tree diff, so this offers a handful
        rather than the whole bucket, newest first within each tier:

          1. the target commit itself -- production promoting what staging built
             needs no patch at all. Staging's copy first, because that is the zip
             staging ran; any other slug's after it.
          2. this slug's newest artifact -- the next push to the same pull request
          3. the newest artifact of each related slug, in the order given -- the
             pull requests a trunk commit came from, as GitHub reports them
          4. staging's newest artifact -- most branches start from the trunk

        A commit is offered once, at its first tier. Every artifact of one commit
        holds the same compiled output whatever slug built it: nothing in the
        build reads the slug, the host name or the pull request number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifact,
        [Parameter(Mandatory = $true)][string]$TargetSha,
        [Parameter(Mandatory = $true)][string]$ArtifactSlug,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$RelatedSlug = @()
    )

    $newestFirst = @($Artifact | Sort-Object -Property Updated -Descending)

    $tiers = @(
        @($newestFirst | Where-Object { $_.Sha -eq $TargetSha -and $_.Slug -eq 'staging' } | Select-Object -First 1)
        @($newestFirst | Where-Object { $_.Sha -eq $TargetSha } | Select-Object -First 1)
        @($newestFirst | Where-Object { $_.Slug -eq $ArtifactSlug } | Select-Object -First 1)
        foreach ($slug in $RelatedSlug) {
            @($newestFirst | Where-Object { $_.Slug -eq $slug } | Select-Object -First 1)
        }
        @($newestFirst | Where-Object { $_.Slug -eq 'staging' } | Select-Object -First 1)
    )

    $offered = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $tiers) {
        if ($offered.Add($candidate.Sha)) {
            $candidate
        }
    }
}

function Select-ArtifactBase {
    <#
        .SYNOPSIS
        Picks the first candidate a repackage can start from.

        .DESCRIPTION
        GetChange is called with each candidate's commit and returns the
        name-status lines between it and the target. It is a parameter so the
        decision can be tested without a repository; the script body hands in
        the git calls. RuleSet is artifact-paths.json, parsed.

        Returns Base (the chosen candidate, or $null to build), Change (its
        classified difference) and Rejected (each candidate passed over, with
        the reason, so the run log says why a build happened). With no base,
        Change is the difference from the nearest candidate that could be
        diffed: a build ships server-owned files too, and is warned about them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Candidate,
        [Parameter(Mandatory = $true)][scriptblock]$GetChange,
        [Parameter(Mandatory = $true)]$RuleSet,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$GeneratedThemeName
    )

    $rejected = New-Object System.Collections.Generic.List[object]
    $nearestChange = @()
    $isNearestKnown = $false

    foreach ($possibleBase in $Candidate) {
        # A commit GitHub no longer serves -- the old head of a force-pushed
        # branch -- makes this candidate unusable, not the search.
        try {
            $lines = @(& $GetChange $possibleBase.Sha)
        }
        catch {
            $rejected.Add([pscustomobject]@{
                Candidate = $possibleBase
                Reason = "could not diff: $($_.Exception.Message)"
            })
            continue
        }

        $change = @(Get-ArtifactChangeClass -NameStatus $lines -RuleSet $RuleSet -GeneratedThemeName $GeneratedThemeName)
        if (-not $isNearestKnown) {
            $nearestChange = $change
            $isNearestKnown = $true
        }

        $compiled = @($change | Where-Object { $_.Class -eq 'build' })
        if ($compiled.Count -gt 0) {
            # The first few are enough to say why; a merge of the trunk can
            # differ by thousands of paths.
            $named = @($compiled | Select-Object -First 3 | ForEach-Object { $_.Path }) -join ', '
            $rejected.Add([pscustomobject]@{
                Candidate = $possibleBase
                Reason = "$($compiled.Count) path(s) need a build: $named"
            })
            continue
        }

        return [pscustomobject]@{
            Base = $possibleBase
            Change = $change
            Rejected = $rejected.ToArray()
        }
    }

    return [pscustomobject]@{
        Base = $null
        Change = $nearestChange
        Rejected = $rejected.ToArray()
    }
}

function Write-ArtifactPlan {
    <#
        .SYNOPSIS
        Hands the plan to the workflow, and the reasons for it to the run's summary.

        .DESCRIPTION
        mode, base_sha and base_object_path go to GITHUB_OUTPUT, where the
        repackage and package jobs branch on them. The summary is where someone
        asking why a run built, or what it patched, finds the answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Summary
    )

    Write-Host "Plan: $($Plan.mode) $($Plan.base_object_path)"
    foreach ($key in $Plan.Keys) {
        "$key=$($Plan[$key])" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    }
    $Summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}

function Invoke-ArtifactPlan {
    <#
        .SYNOPSIS
        Makes the plan: build, or repackage which artifact, and the summary that says why.

        .DESCRIPTION
        Everything the plan asks of the world is a parameter, so the Pester
        suite can run the whole of it -- an empty bucket, a listing that fails,
        a GitHub that will not answer -- with none of them there. The script
        body hands in the real ones.

        Store is an artifact store (see New-GsutilArtifactStore in
        ArtifactRecord.psm1); only its List is used here. GetRelatedPulls is
        called with the target commit and returns the numbers of the pull
        requests it came from, throwing when it cannot say. GetChange is called
        with a candidate's commit and returns the name-status lines between it
        and the target. GetGeneratedThemeName returns the generated theme names
        in the target's tree. RuleSetPath is artifact-paths.json.

        Returns Plan -- mode, base_sha and base_object_path, as
        Write-ArtifactPlan writes them -- and Summary, the lines of the step
        summary. It does not throw. A plan it cannot make is a build, and the
        summary says why: a half-hour build is the worst that a wrong answer
        here is allowed to cost.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$TargetSha,
        [Parameter(Mandatory = $true)][string]$ArtifactSlug,
        [Parameter(Mandatory = $true)][hashtable]$Store,
        [Parameter(Mandatory = $true)][scriptblock]$GetRelatedPulls,
        [Parameter(Mandatory = $true)][scriptblock]$GetChange,
        [Parameter(Mandatory = $true)][scriptblock]$GetGeneratedThemeName,
        [Parameter(Mandatory = $true)][string]$RuleSetPath,
        [switch]$ForceBuild
    )

    # What a forced run reports, and the fallback: a plan this cannot make
    # costs a build, never a failed deploy.
    $buildPlan = [ordered]@{ mode = 'build'; base_sha = ''; base_object_path = '' }
    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('### Artifact plan')
    $summary.Add('')

    if ($ForceBuild) {
        $summary.Add('Full build requested (`force_build`, or the `rock:full-build` label).')
        return [pscustomobject]@{ Plan = $buildPlan; Summary = $summary.ToArray() }
    }

    $plan = $buildPlan
    try {
        $ruleSet = Get-Content -Raw -Path $RuleSetPath | ConvertFrom-Json
        $themes = @(& $GetGeneratedThemeName)

        # An empty bucket lists nothing, and is a first build. A bucket that
        # cannot be listed throws, and is caught below as a search that failed.
        $artifact = @(& $Store.List)

        # A merge to the trunk carries the code its pull request was last
        # deployed with, so that pull request's artifact is the natural base.
        # Not knowing costs only that tier, so a failed lookup is not worth a
        # build.
        $related = @()
        try {
            $related = @(& $GetRelatedPulls $TargetSha)
        }
        catch {
            Write-Host "::notice::Could not ask GitHub which pull requests $TargetSha came from; searching without them."
        }
        $relatedSlug = @($related | Where-Object { $_ } | ForEach-Object { "pr-$_" })

        $candidate = @(Get-ArtifactBaseCandidate -Artifact $artifact -TargetSha $TargetSha -ArtifactSlug $ArtifactSlug -RelatedSlug $relatedSlug)
        $selection = Select-ArtifactBase -Candidate $candidate -RuleSet $ruleSet -GeneratedThemeName $themes -GetChange $GetChange

        foreach ($rejection in $selection.Rejected) {
            $summary.Add("- Passed over ``$($rejection.Candidate.ObjectPath)``: $($rejection.Reason)")
        }

        if ($null -eq $selection.Base) {
            $summary.Add("Building: none of $($candidate.Count) candidate artifact(s) differs from $TargetSha in files alone.")
        }
        else {
            $plan = [ordered]@{
                mode = 'repackage'
                base_sha = $selection.Base.Sha
                base_object_path = $selection.Base.ObjectPath
            }

            $patched = @($selection.Change | Where-Object { $_.Class -eq 'patch' })
            $summary.Add("Repackaging ``$($selection.Base.ObjectPath)`` with $($patched.Count) changed file(s); no build.")
            $summary.Add('')
            foreach ($item in $patched) {
                $summary.Add("- ``$($item.Status)`` ``$($item.Path)``")
            }
        }

        # Whichever way this run goes: a build ships the file as surely as a
        # patch does, and the deploy keeps the server's copy either way. What it
        # then does with it is Deploy-RockEnvironment.ps1's call.
        foreach ($item in @($selection.Change | Where-Object { $_.IsServerOwned })) {
            $message = "$($item.Path) changed, but the deploy treats it as server-owned, so the server's copy may win. See the server-owned lists in Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1."
            Write-Host "::warning::$message"
            $summary.Add("- :warning: $message")
        }
    }
    catch {
        $plan = $buildPlan
        Write-Host "::warning::Could not look for an artifact to repackage, so this run builds: $($_.Exception.Message)"
        $summary.Add("Building: the search for a base artifact failed -- $($_.Exception.Message)")
    }

    return [pscustomobject]@{ Plan = $plan; Summary = $summary.ToArray() }
}

Import-Module (Join-Path $PSScriptRoot 'ArtifactPaths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force

# Which pull requests GitHub says the target came from. A nonzero exit is
# thrown, so the plan can tell a lookup that failed from a commit that came
# from none. Reads $Repository when called, from this script's scope.
$getRelatedPulls = {
    param($Sha)
    $numbers = @(gh api "repos/$Repository/commits/$Sha/pulls" --jq '.[].number' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "gh api exited $LASTEXITCODE"
    }
    return $numbers
}

$result = Invoke-ArtifactPlan -TargetSha $TargetSha -ArtifactSlug $ArtifactSlug -ForceBuild:$ForceBuild `
    -Store (New-GsutilArtifactStore -Bucket $Bucket) `
    -GetRelatedPulls $getRelatedPulls `
    -GetChange { param($Sha) Get-ArtifactTreeChange -BaseSha $Sha -TargetSha $TargetSha } `
    -GetGeneratedThemeName { Get-GeneratedThemeName -Sha $TargetSha } `
    -RuleSetPath (Join-Path $PSScriptRoot 'artifact-paths.json')

Write-ArtifactPlan -Plan $result.Plan -Summary $result.Summary
