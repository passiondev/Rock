<#
.SYNOPSIS
    How a changed path relates to a RockWeb artifact: shared by the two scripts that
    decide on and carry out a build-free repackage.

.DESCRIPTION
    Get-ArtifactPlan.ps1 judges candidate base artifacts with this and
    New-RepackagedArtifact.ps1 judges its one base again with it, on another
    runner. A module rather than a third script because both need the same
    functions and neither should run the other's body to get them.

    ADR-0001 keeps shared modules out of Deployment/PrTestEnvironments, because
    the bootstrap copies only *.ps1 to the VM. It does not govern this: these
    scripts never leave a GitHub runner, which checks the module out beside them.

    The rules themselves live in artifact-paths.json beside this file.
#>

Set-StrictMode -Version Latest

function ConvertTo-PathPatternRegex {
    <#
        .SYNOPSIS
        Turns one artifact-paths.json glob into an anchored, case-insensitive regex.

        .DESCRIPTION
        `**` crosses directory boundaries and `*` does not. A leading `**/` also
        matches nothing at all, so `**/*.md` catches README.md at the root.
        {GeneratedTheme} becomes an alternation of the names supplied.
    #>
    [CmdletBinding()]
    [OutputType([regex])]
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$GeneratedThemeName = @()
    )

    $builder = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $Pattern.Length) {
        $rest = $Pattern.Substring($index)
        if ($rest.StartsWith('{GeneratedTheme}')) {
            # An empty alternation matches nothing, which would quietly hand every
            # compiled theme to the RockWeb/** patch rule below it.
            if (@($GeneratedThemeName).Count -eq 0) {
                throw "'$Pattern' needs {GeneratedTheme} names and none were supplied."
            }
            $names = @($GeneratedThemeName | ForEach-Object { [regex]::Escape($_) })
            [void]$builder.Append('(?:' + ($names -join '|') + ')')
            $index += '{GeneratedTheme}'.Length
        }
        elseif ($rest.StartsWith('**/')) {
            [void]$builder.Append('(?:.*/)?')
            $index += 3
        }
        elseif ($rest.StartsWith('**')) {
            [void]$builder.Append('.*')
            $index += 2
        }
        elseif ($rest.StartsWith('*')) {
            [void]$builder.Append('[^/]*')
            $index += 1
        }
        else {
            [void]$builder.Append([regex]::Escape($rest.Substring(0, 1)))
            $index += 1
        }
    }

    return [regex]::new('^' + $builder.ToString() + '$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-ArtifactChangeClass {
    <#
        .SYNOPSIS
        Classifies `git diff --name-status --no-renames` lines against artifact-paths.json.

        .DESCRIPTION
        Returns one object per change: Status (A, M, D...), Path, Class (build, patch
        or ignore) and IsServerOwned. RuleSet is artifact-paths.json, parsed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$NameStatus,
        [Parameter(Mandatory = $true)]$RuleSet,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$GeneratedThemeName = @()
    )

    $classRules = @($RuleSet.rules | ForEach-Object {
        [pscustomobject]@{
            Class = $_.class
            Regex = ConvertTo-PathPatternRegex -Pattern $_.pattern -GeneratedThemeName $GeneratedThemeName
        }
    })
    $serverOwned = @($RuleSet.serverOwned | ForEach-Object { ConvertTo-PathPatternRegex -Pattern $_.pattern })

    foreach ($line in $NameStatus) {
        $status, $path = $line -split "`t", 2

        $class = 'build'
        foreach ($classRule in $classRules) {
            if ($classRule.Regex.IsMatch($path)) {
                $class = $classRule.Class
                break
            }
        }

        $isServerOwned = $false
        foreach ($regex in $serverOwned) {
            if ($regex.IsMatch($path)) {
                $isServerOwned = $true
                break
            }
        }

        [pscustomobject]@{
            Status = $status
            Path = $path
            Class = $class
            IsServerOwned = $isServerOwned
        }
    }
}

function Get-GeneratedThemeName {
    <#
        .SYNOPSIS
        The themes Rock.Frontend.Styles compiles into RockWeb/Themes, read from a commit's tree.

        .DESCRIPTION
        Read from git rather than the working tree so it describes the commit
        being judged, whatever is checked out. A tree without Rock.Frontend.Styles
        (the 18.x line) returns nothing, and Get-ArtifactChangeClass then refuses
        to classify -- so that line always builds, which is the safe answer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Sha
    )

    $entries = @(git ls-tree -d --name-only $Sha 'Rock.Frontend.Styles/src/themes/')
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-tree $Sha failed (exit $LASTEXITCODE)."
    }
    foreach ($entry in $entries) {
        Split-Path -Path $entry -Leaf
    }
}

function Get-ArtifactTreeChange {
    <#
        .SYNOPSIS
        The `git diff --name-status` lines between a base artifact's commit and the target.

        .DESCRIPTION
        The checkout is one commit deep, so the base is fetched first: one commit,
        its trees and none of its blobs. Name-status compares tree entries and
        never reads a blob, and --no-renames keeps it that way -- rename detection
        would read both sides of every candidate pair, and a rename is a delete
        and an add to the archive anyway.

        A commit GitHub no longer serves throws, which Select-ArtifactBase reads
        as "this candidate is unusable".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$BaseSha,
        [Parameter(Mandatory = $true)][string]$TargetSha
    )

    git fetch --quiet --depth=1 --filter=blob:none --no-tags origin $BaseSha
    if ($LASTEXITCODE -ne 0) {
        throw "git fetch of $BaseSha failed (exit $LASTEXITCODE)."
    }

    # quotepath off: a path with non-ASCII characters comes back as itself, so
    # the rules can match it. One with a tab or a quote is still C-quoted, which
    # no rule matches, so it builds.
    $lines = @(git -c core.quotepath=off diff --name-status --no-renames $BaseSha $TargetSha)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff $BaseSha $TargetSha failed (exit $LASTEXITCODE)."
    }
    return $lines
}

Export-ModuleMember -Function Get-ArtifactChangeClass, Get-GeneratedThemeName, Get-ArtifactTreeChange
