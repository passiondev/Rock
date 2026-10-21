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

    The uploads in pr-test-artifact.yml take their destination from it too:
    Write-ArtifactOutput hands on artifact_gcs_destination, and each upload uses
    it whole. The repackage job runs its target's own script, and a target from
    before that output writes none. So the output carries the bucket as well as
    the folder: a missing one is an empty destination, which the action refuses,
    rather than `bucket/` with nothing after it, which uploads to the bucket's
    root. The plan never chooses a repackage for such a target: it asks this
    function for -Bucket and builds when it is missing. The repackage job stops
    on an empty output too, as the net under that. test_artifact_reuse.py holds
    the uploads to the output.

    The record is pr-test-artifact.json. The deploy never reads it -- it is
    handed the object path as an output -- but a later repackage does, to learn
    which build a base carries and what its zip should hash to. New-ArtifactRecord
    fixes its fields and their order; Read-ArtifactRecord reads one back,
    tolerating the fields an older writer never wrote.

    The bucket itself is reached through an artifact store: a hashtable of two
    scriptblocks, List and Download, that the plan and the repackage are handed
    rather than calling gsutil themselves. New-GsutilArtifactStore is the one
    the workflow uses. The Pester suites hand in stores of their own, so an
    empty bucket, a listing that fails and a base with a bad hash can each be
    run without a bucket.

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
$script:RecordFields = @(
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
    foreach ($name in $script:RecordFields) {
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
        Hands an artifact to the rest of the workflow: the outputs both packaging jobs set.

        .DESCRIPTION
        pr-test-artifact.yml returns five of them from whichever packaging job
        ran, so the package job and the repackage job have to write the same
        five names. artifact_gcs_object_path is the one the deploy acts on; an
        empty one sends it to gs:///, minutes later and far from the cause.

        The sixth, artifact_gcs_destination, is where the job's own uploads put
        the zip and its record: Bucket, a slash, then the address's Folder.
        upload-cloud-storage splits that at the first slash into a bucket and a
        prefix and names each object prefix/file, so the zip lands at
        ObjectPath and the record at RecordPath. It stays a step output rather
        than one of the workflow's: the bucket's name can be built from a
        secret, and GitHub drops a job output that carries one.

        Path is GITHUB_OUTPUT, passed in rather than read here so a test can
        hand it a file of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Address,
        [Parameter(Mandatory = $true)][string]$Bucket,
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
        "artifact_gcs_destination=$Bucket/$($Address.Folder)"
    ) | Out-File -FilePath $Path -Append
}

function Get-GsutilArtifactListing {
    <#
        .SYNOPSIS
        Every artifact in a bucket, as ConvertFrom-ArtifactListing reads them, by asking gsutil.

        .DESCRIPTION
        Lists every object under the prefix and lets ConvertFrom-ArtifactListing
        keep the zips. An empty bucket is not an error, it is a first build:
        gsutil exits 1 and says the wildcard "matched no objects", and that
        returns nothing. Any other failure throws, because a listing that could
        not be read is not a listing that found nothing, and the plan should say
        which it was.

        Not exported. New-GsutilArtifactStore hands it out as the store's List.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Bucket
    )

    $listing = @(gsutil ls -l "gs://$Bucket/$script:ArtifactRoot/**" 2>&1 | ForEach-Object { "$_" })
    $listingExitCode = $LASTEXITCODE
    $isBucketEmpty = @($listing -match 'matched no objects').Count -gt 0
    $isListingFailed = $listingExitCode -ne 0 -and -not $isBucketEmpty
    if ($isListingFailed) {
        throw "gsutil ls failed (exit $listingExitCode): $($listing -join ' ')"
    }

    ConvertFrom-ArtifactListing -Line $listing
}

function Copy-GsutilArtifactObject {
    <#
        .SYNOPSIS
        Downloads one object from a bucket to a local file, by asking gsutil.

        .DESCRIPTION
        Throws when gsutil fails, with only the exit code as the message: the
        caller knows what it was fetching and why it mattered, and words the
        sentence. The repackage's "Could not download the base artifact ...
        (exit 1)" reads exactly as it did when gsutil was called inline.

        Not exported. New-GsutilArtifactStore hands it out as the store's Download.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][string]$ObjectPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # Sliced downloads off. upload-cloud-storage stores every artifact
    # gzip-encoded, and gsutil cannot rebuild a gzip-encoded object from the
    # ranged reads it slices a large download into: anything past its 150 MB
    # threshold -- every RockWeb zip -- fails with "Some components ... were not
    # downloaded successfully", however often it is retried. One stream is
    # slower and always works.
    gsutil -q -o 'GSUtil:sliced_object_download_threshold=0' cp "gs://$Bucket/$ObjectPath" $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "exit $LASTEXITCODE"
    }
}

function New-GsutilArtifactStore {
    <#
        .SYNOPSIS
        The artifact store the workflow uses: one bucket, reached through gsutil.

        .DESCRIPTION
        An artifact store is a hashtable of two scriptblocks:

          List      takes nothing and returns every artifact in the store as
                    ConvertFrom-ArtifactListing returns them: Slug, Sha,
                    ObjectPath and Updated. Nothing for an empty store; it
                    throws when it cannot say.
          Download  takes -ObjectPath (relative to the bucket) and
                    -Destination (a local file) and copies the one to the
                    other. It throws when it cannot.

        Get-ArtifactPlan.ps1 takes a store and uses List; New-RepackagedArtifact.ps1
        takes one and uses Download. The Pester suites build their own, so each
        script's handling of an empty bucket, a failed listing or a base whose
        hash is wrong runs without gsutil or a bucket.

        Each scriptblock is a closure over the bucket. A closure runs in a
        dynamic module of its own, which cannot see this module's unexported
        functions by name, so it carries the two gsutil functions as
        scriptblocks and invokes those; each still runs here, in this module.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$Bucket
    )

    $listArtifacts = ${function:Get-GsutilArtifactListing}
    $copyObject = ${function:Copy-GsutilArtifactObject}

    return @{
        List = {
            & $listArtifacts -Bucket $Bucket
        }.GetNewClosure()
        Download = {
            param(
                [Parameter(Mandatory = $true)][string]$ObjectPath,
                [Parameter(Mandatory = $true)][string]$Destination
            )
            & $copyObject -Bucket $Bucket -ObjectPath $ObjectPath -Destination $Destination
        }.GetNewClosure()
    }
}

Export-ModuleMember -Function Get-ArtifactAddress, ConvertFrom-ArtifactObjectPath, ConvertFrom-ArtifactListing, New-ArtifactRecord, Write-ArtifactRecord, Read-ArtifactRecord, Write-ArtifactOutput, New-GsutilArtifactStore
