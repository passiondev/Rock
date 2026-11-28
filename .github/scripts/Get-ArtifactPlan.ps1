<#
.SYNOPSIS
    Decides whether pr-test-artifact.yml has to build, can partially reuse
    untouched compiled layers from GCS, or can repackage an artifact it already
    has without compiling anything.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run the
    decision -- see Tests/PrTestEnvironments/Pester/ArtifactPlan.Tests.ps1. The
    whole of it is Invoke-ArtifactPlan, which is handed the bucket, GitHub and
    git rather than calling them; the script body builds the real ones and
    reports what it decided.

    Three tiers of reuse:
      1. Repackage (mode=repackage): only patch/ignore files changed -- no build.
      2. Partial-layer build (mode=build with reuse_base_object_path set): only a
         strict subset of build layers (dotnet, js-obsidian, js-blocks, js-misc)
         changed -- rebuild only dirty layers and extract untouched compiled
         layers from the verified GCS base zip.
      3. Full build (mode=build, all build_* = true): force_build, empty bucket,
         unknown/workflow path changed, or all 4 layers changed.

    It never fails the run -- a plan it cannot make costs a full build, not a
    failed deploy.

.PARAMETER TargetSha
    The commit this run packages. Must be checked out.

.PARAMETER ArtifactSlug
    This run's artifact folder: pr-<number>, staging or production.

.PARAMETER Bucket
    The deployment bucket the artifacts live in.

.PARAMETER Repository
    owner/name, for asking GitHub which pull requests a commit came from.

.PARAMETER ForceBuild
    Skip the search and run a full build. The force_build input, or the
    rock:full-build label.

.OUTPUTS
    Writes mode, base_sha, base_object_path, build_dotnet, build_js_obsidian,
    build_js_blocks, build_js_misc, and reuse_base_object_path to
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
        Picks the first candidate a repackage can start from, and records the
        best partial-layer reuse candidate when a build is needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Candidate,
        [Parameter(Mandatory = $true)][scriptblock]$GetChange,
        [Parameter(Mandatory = $true)]$RuleSet,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$GeneratedThemeName
    )

    $allLayers = @('dotnet', 'js-obsidian', 'js-blocks', 'js-misc')
    $rejected = New-Object System.Collections.Generic.List[object]
    $nearestChange = @()
    $isNearestKnown = $false
    $bestPartialBase = $null
    $bestPartialDirty = $null

    foreach ($possibleBase in $Candidate) {
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
            $named = @($compiled | Select-Object -First 3 | ForEach-Object { $_.Path }) -join ', '
            $rejected.Add([pscustomobject]@{
                Candidate = $possibleBase
                Reason = "$($compiled.Count) path(s) need a build: $named"
            })

            # Evaluate partial-layer reuse eligibility for this candidate.
            $dirtyLayers = @($compiled | ForEach-Object {
                if ($_.PSObject.Properties['Layer'] -and $_.Layer) { $_.Layer } else { 'all' }
            } | Sort-Object -Unique)

            if (-not ($dirtyLayers -contains 'all') -and $dirtyLayers.Count -lt $allLayers.Count) {
                if ($null -eq $bestPartialBase -or $dirtyLayers.Count -lt $bestPartialDirty.Count) {
                    $bestPartialBase = $possibleBase
                    $bestPartialDirty = $dirtyLayers
                }
            }
            continue
        }

        return [pscustomobject]@{
            Base = $possibleBase
            Change = $change
            Rejected = $rejected.ToArray()
            PartialBase = $null
            DirtyLayers = @()
        }
    }

    return [pscustomobject]@{
        Base = $null
        Change = $nearestChange
        Rejected = $rejected.ToArray()
        PartialBase = $bestPartialBase
        DirtyLayers = if ($null -ne $bestPartialDirty) { $bestPartialDirty } else { $allLayers }
    }
}

function Write-ArtifactPlan {
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

    $buildPlan = [ordered]@{
        mode = 'build'
        base_sha = ''
        base_object_path = ''
        build_dotnet = 'true'
        build_js_obsidian = 'true'
        build_js_blocks = 'true'
        build_js_misc = 'true'
        reuse_base_object_path = ''
    }
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
        $artifact = @(& $Store.List)

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
            if ($null -ne $selection.PartialBase) {
                $dirty = @($selection.DirtyLayers)
                $plan = [ordered]@{
                    mode = 'build'
                    base_sha = ''
                    base_object_path = ''
                    build_dotnet = if ($dirty -contains 'dotnet') { 'true' } else { 'false' }
                    build_js_obsidian = if ($dirty -contains 'js-obsidian') { 'true' } else { 'false' }
                    build_js_blocks = if ($dirty -contains 'js-blocks') { 'true' } else { 'false' }
                    build_js_misc = if ($dirty -contains 'js-misc') { 'true' } else { 'false' }
                    reuse_base_object_path = $selection.PartialBase.ObjectPath
                }
                $reused = @(@('dotnet', 'js-obsidian', 'js-blocks', 'js-misc') | Where-Object { $dirty -notcontains $_ })
                $summary.Add("Partial build: rebuilding [$($dirty -join ', ')]; reusing [$($reused -join ', ')] from ``$($selection.PartialBase.ObjectPath)``.")
            }
            else {
                $summary.Add("Building: none of $($candidate.Count) candidate artifact(s) differs from $TargetSha in files alone.")
            }
        }
        else {
            $plan = [ordered]@{
                mode = 'repackage'
                base_sha = $selection.Base.Sha
                base_object_path = $selection.Base.ObjectPath
                build_dotnet = 'false'
                build_js_obsidian = 'false'
                build_js_blocks = 'false'
                build_js_misc = 'false'
                reuse_base_object_path = ''
            }

            $patched = @($selection.Change | Where-Object { $_.Class -eq 'patch' })
            $summary.Add("Repackaging ``$($selection.Base.ObjectPath)`` with $($patched.Count) changed file(s); no build.")
            $summary.Add('')
            foreach ($item in $patched) {
                $summary.Add("- ``$($item.Status)`` ``$($item.Path)``")
            }
        }

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
