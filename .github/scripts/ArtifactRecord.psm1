<#
.SYNOPSIS
    Where a RockWeb artifact lives in the bucket, and the record kept beside it:
    shared by the three scripts that package, plan and repackage.

.DESCRIPTION
    An artifact's address -- its zip's name, its folder, and the object paths of
    the zip and of its pr-test-artifact.json -- used to be spelled out in four
    places: the package step, the repackage script, the plan's listing regex and
    the uploads. They had to agree for a repackaged zip to land where the deploy
    looks and for a later plan to find it again, and the only thing holding them
    together was a test comparing two regexes. Get-ArtifactAddress now composes
    it once, and ConvertFrom-ArtifactObjectPath reads it back by composing again
    and comparing, so the two directions cannot drift apart.

    The uploads in pr-test-artifact.yml still name the folder themselves, from
    the job's env. A step output cannot replace them: the repackage job runs the
    target's own script, and a target older than a new output would hand the
    upload an empty folder. test_artifact_reuse.py holds both jobs' uploads to
    one destination instead.

    The record is pr-test-artifact.json. The deploy never reads it -- it is
    handed the object path as an output -- but a later repackage does, to learn
    which build a base carries and what its zip should hash to. New-ArtifactRecord
    fixes its fields and their order; Read-ArtifactRecord reads one back,
    tolerating the fields an older writer never wrote.

    ADR-0001 keeps shared modules out of Deployment/PrTestEnvironments, because
    the bootstrap copies only *.ps1 to the VM. It does not govern this: these
    scripts never leave a GitHub runner, which checks the module out beside them.
#>

Set-StrictMode -Version Latest

# The prefix every artifact folder sits under. The command queue and the
# bootstrap share it, so a listing of it holds far more than artifacts.
$script:ArtifactRoot = 'pr-environments'

# Beside every zip, under this name. The workflow's uploads name it too, as a
# literal, because a path: input cannot call a module.
$script:RecordName = 'pr-test-artifact.json'

# Every field a record can carry, in the order New-ArtifactRecord writes them.
# Read-ArtifactRecord returns each of these whether or not the file has it.
$script:RecordField = @(
    'prNumber', 'sha', 'shortSha', 'artifactName', 'artifactGcsPath', 'hostName', 'sha256',
    'builtFromSha', 'baseArtifactGcsPath'
)

function Get-ArtifactAddress {
    <#
        .SYNOPSIS
        Where the artifact of one commit, packaged for one slug, lives in the bucket.

        .DESCRIPTION
        Returns Slug, Sha, ShortSha, Name (the zip's file name), Folder,
        ObjectPath (the zip, relative to the bucket), RecordName and RecordPath
        (its pr-test-artifact.json, relative to the bucket). The folder is keyed
        on the full commit and the name on its first seven characters, which is
        how every artifact already in the bucket was written.

        Nothing is validated. A dispatch can name a short commit, and the
        package job has always packaged what it was given; ShortSha is then the
        whole of it. ConvertFrom-ArtifactObjectPath is the stricter direction.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)][string]$Sha
    )

    $shortSha = $Sha.Substring(0, [Math]::Min(7, $Sha.Length))
    $name = "RockWeb-$Slug-$shortSha.zip"
    $folder = "$script:ArtifactRoot/$Slug/$Sha"

    return [pscustomobject]@{
        Slug = $Slug
        Sha = $Sha
        ShortSha = $shortSha
        Name = $name
        Folder = $folder
        ObjectPath = "$folder/$name"
        RecordName = $script:RecordName
        RecordPath = "$folder/$script:RecordName"
    }
}

function ConvertFrom-ArtifactObjectPath {
    <#
        .SYNOPSIS
        The address an object path names, or nothing when it names no artifact.

        .DESCRIPTION
        The inverse of Get-ArtifactAddress. A path counts only when composing an
        address from the slug and commit it carries gives back exactly that
        path. So a record, a zip renamed by hand and a zip in a folder named for
        a short commit are all not artifacts: no packaging job writes the first
        two as zips, and the third's commit cannot be fetched from GitHub to
        diff against.

        Compared with case, because object names are: RockWeb-x.zip and
        rockweb-x.zip are two objects, and no writer makes the second.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ObjectPath
    )

    # -notmatch ignores case, so an upper-case commit still parses. The
    # comparison below is what holds the name to the composer's spelling.
    $shape = '^' + [regex]::Escape($script:ArtifactRoot) + '/(?<slug>[^/]+)/(?<sha>[0-9a-f]{40})/[^/]+$'
    if ($ObjectPath -notmatch $shape) {
        return
    }

    $address = Get-ArtifactAddress -Slug $Matches['slug'] -Sha $Matches['sha']
    if ($address.ObjectPath -cne $ObjectPath) {
        return
    }
    return $address
}

function ConvertFrom-ArtifactListing {
    <#
        .SYNOPSIS
        Reads the artifacts out of `gsutil ls -l gs://<bucket>/pr-environments/**`.

        .DESCRIPTION
        One object per zip: Slug, Sha, ObjectPath (relative to the bucket) and
        Updated. A line counts when the object it names is an artifact address,
        as ConvertFrom-ArtifactObjectPath judges one, so the TOTAL line, each
        record beside its zip, the command queue's files under the same prefix
        and a zip in a short-SHA folder are all skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line
    )

    # A long listing's three columns: size, time updated, gs://bucket/object.
    $shape = '^\s*\d+\s+(?<updated>\S+)\s+gs://[^/]+/(?<path>.+?)\s*$'
    foreach ($entry in $Line) {
        if ($entry -notmatch $shape) {
            continue
        }

        # Taken before the next call, which matches a pattern of its own.
        $updated = $Matches['updated']
        $address = ConvertFrom-ArtifactObjectPath -ObjectPath $Matches['path']
        if ($null -eq $address) {
            continue
        }

        [pscustomobject]@{
            Slug = $address.Slug
            Sha = $address.Sha
            ObjectPath = $address.ObjectPath
            Updated = [DateTimeOffset]::Parse($updated, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

function New-ArtifactRecord {
    <#
        .SYNOPSIS
        The pr-test-artifact.json fields for one artifact, in the order every writer has used.

        .DESCRIPTION
        prNumber, sha, shortSha, artifactName, artifactGcsPath, hostName and
        sha256, as the package job has always written them. A repackage adds
        builtFromSha -- the commit whose compiled output the zip carries, which
        a chain of repackages keeps pointing at the build that made it -- and
        baseArtifactGcsPath, the zip it started from. Nothing reads a record by
        position; the order is kept so a new record diffs cleanly against an
        old one.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Build')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]$Address,
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PrNumber,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true, ParameterSetName = 'Repackage')][string]$BuiltFromSha,
        [Parameter(Mandatory = $true, ParameterSetName = 'Repackage')][string]$BaseObjectPath
    )

    $record = [ordered]@{
        prNumber = $PrNumber
        sha = $Address.Sha
        shortSha = $Address.ShortSha
        artifactName = $Address.Name
        artifactGcsPath = "gs://$Bucket/$($Address.ObjectPath)"
        hostName = $HostName
        sha256 = $Sha256
    }
    if ($PSCmdlet.ParameterSetName -eq 'Repackage') {
        $record['builtFromSha'] = $BuiltFromSha
        $record['baseArtifactGcsPath'] = "gs://$Bucket/$BaseObjectPath"
    }
    return $record
}

function Write-ArtifactRecord {
    <#
        .SYNOPSIS
        Writes a record from New-ArtifactRecord to disk, as JSON.

        .DESCRIPTION
        UTF-8 without a byte-order mark under PowerShell 7, which is what the
        package step has always written and what both jobs upload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Record | ConvertTo-Json | Out-File -FilePath $Path -Encoding utf8
}

function Read-ArtifactRecord {
    <#
        .SYNOPSIS
        Reads a pr-test-artifact.json back, every known field as a string.

        .DESCRIPTION
        A record predates whichever fields were added after it was written --
        builtFromSha, for one, only a repackage records -- so an absent field
        reads as '' and means "not recorded", not an error. A field this module
        does not know is dropped, because nothing here acts on it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parsed = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $record = [ordered]@{}
    foreach ($name in $script:RecordField) {
        $field = $parsed.PSObject.Properties[$name]
        $isRecorded = $null -ne $field -and $null -ne $field.Value
        if ($isRecorded) {
            $record[$name] = [string]$field.Value
        }
        else {
            $record[$name] = ''
        }
    }
    return [pscustomobject]$record
}

function Write-ArtifactOutput {
    <#
        .SYNOPSIS
        Hands an artifact to the rest of the workflow: the five outputs both packaging jobs set.

        .DESCRIPTION
        pr-test-artifact.yml returns each of its outputs from whichever packaging
        job ran, so the package job and the repackage job have to write the same
        five names. artifact_gcs_object_path is the one the deploy acts on; an
        empty one sends it to gs:///, minutes later and far from the cause.

        Path is GITHUB_OUTPUT, passed in rather than read here so a test can
        hand it a file of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Address,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PrNumber,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    @(
        "artifact_name=$($Address.Name)"
        "artifact_gcs_object_path=$($Address.ObjectPath)"
        "host_name=$HostName"
        "pr_number=$PrNumber"
        "sha=$($Address.Sha)"
    ) | Out-File -FilePath $Path -Append
}

Export-ModuleMember -Function Get-ArtifactAddress, ConvertFrom-ArtifactObjectPath, ConvertFrom-ArtifactListing, New-ArtifactRecord, Write-ArtifactRecord, Read-ArtifactRecord, Write-ArtifactOutput
