<#
.SYNOPSIS
    Builds a deployable RockWeb zip from an earlier artifact plus the files that
    changed since, without compiling anything.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run it
    -- see Tests/PrTestEnvironments/Pester/ArtifactRepackage.Tests.ps1. The whole
    of it is Invoke-ArtifactRepackage, which is handed the bucket and git rather
    than calling them; the script body builds the real ones and hands them over.

    The repackage job of pr-test-artifact.yml runs this when Get-ArtifactPlan.ps1
    found a base: an artifact whose commit differs from this one only in files the
    build copies verbatim. The result is the zip a full build would have made --
    same name, same bucket folder, same metadata, plus builtFromSha naming the
    commit whose compiled output it carries -- so nothing downstream can tell the
    two apart, and nothing downstream has to.

    The difference is judged again here rather than handed over from the plan,
    which ran on another runner: this is the last point that can refuse to ship
    source where compiled output belongs. A failure fails the run. There is no
    fallback to a build from here; rerun with force_build, or add the
    rock:full-build label.

    Expects the target commit checked out in the working directory with
    core.autocrlf true, as the Windows build checks it out, so a patched text file
    carries the line endings a built one would.

.PARAMETER BaseSha
    The base artifact's commit, from the plan.

.PARAMETER BaseObjectPath
    The base zip, relative to the bucket, from the plan.

.PARAMETER TargetSha
    The commit this run packages.

.PARAMETER Bucket
    The deployment bucket, for the base's download, the gs:// paths the record
    carries and the destination the job's uploads take.

.PARAMETER ArtifactSlug
    This run's artifact folder: pr-<number>, staging or production.

.PARAMETER PrNumber
    Recorded in the metadata, as the build records it.

.PARAMETER HostName
    Recorded in the metadata, as the build records it.

.OUTPUTS
    The zip and pr-test-artifact.json in the working directory, and
    artifact_name, artifact_gcs_object_path, host_name, pr_number, sha and
    artifact_gcs_destination in GITHUB_OUTPUT -- the outputs the package job
    writes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseSha,
    [Parameter(Mandatory = $true)][string]$BaseObjectPath,
    [Parameter(Mandatory = $true)][string]$TargetSha,
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $true)][string]$ArtifactSlug,
    [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PrNumber = '',
    [Parameter(Mandatory = $true)][string]$HostName
)

$ErrorActionPreference = "Stop"

function New-PatchedArtifactArchive {
    <#
        .SYNOPSIS
        Writes a copy of a base artifact with a set of changed files applied.

        .DESCRIPTION
        Change is what Get-ArtifactChangeClass returns. Paths are repository-relative
        and the artifact is the contents of RockWeb, so RockWeb/web.config is the
        entry web.config. Each changed file is read from SourceRoot, the checkout of
        the target commit.

        Entries are matched ignoring case and separator, because IIS ignores case
        and Compress-Archive has written both separators in its time. A changed
        file therefore replaces its old entry rather than landing beside it, and
        new entries are written with whichever separator the base already uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Change
    )

    # Checked again here, not only in the plan job: that job decided on another
    # runner, and this is the last point that can stop source being shipped
    # where compiled output belongs.
    $compiled = @($Change | Where-Object { $_.Class -eq 'build' })
    if ($compiled.Count -gt 0) {
        $named = @($compiled | ForEach-Object { $_.Path }) -join ', '
        throw "Refusing to repackage: $($compiled.Count) changed path(s) need a build: $named"
    }

    $patch = @($Change | Where-Object { $_.Class -eq 'patch' })
    $replaced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $patch) {
        [void]$replaced.Add($item.Path.Substring('RockWeb/'.Length))
    }

    $baseStream = [System.IO.File]::OpenRead($BasePath)
    $base = New-Object System.IO.Compression.ZipArchive($baseStream, [System.IO.Compression.ZipArchiveMode]::Read)
    $outputStream = $null
    $output = $null
    try {
        # A repackage inherits every assembly from its base and checks none of
        # them. The full build verifies its output before uploading; this is the
        # cheap stand-in, so a stray zip in the bucket cannot become a site that
        # will not start.
        $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $base.Entries) {
            [void]$present.Add($entry.FullName.Replace('\', '/'))
        }
        $missing = @('Bin/Rock.dll', 'web.config' | Where-Object { -not $present.Contains($_) })
        if ($missing.Count -gt 0) {
            throw "Refusing to repackage: the base artifact has no $($missing -join ' or '), so it is not a RockWeb build."
        }

        $outputStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::CreateNew)
        $output = New-Object System.IO.Compression.ZipArchive($outputStream, [System.IO.Compression.ZipArchiveMode]::Create)

        $separator = '/'
        if (@($base.Entries | Where-Object { $_.FullName.Contains('\') }).Count -gt 0) {
            $separator = '\'
        }

        foreach ($entry in $base.Entries) {
            if ($replaced.Contains($entry.FullName.Replace('\', '/'))) {
                continue
            }

            $copy = $output.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $copy.LastWriteTime = $entry.LastWriteTime
            $copy.ExternalAttributes = $entry.ExternalAttributes
            $reader = $entry.Open()
            $writer = $copy.Open()
            try {
                $reader.CopyTo($writer)
            }
            finally {
                $writer.Dispose()
                $reader.Dispose()
            }
        }

        # Every patched path was skipped above, so a deletion needs nothing more.
        foreach ($item in @($patch | Where-Object { $_.Status -ne 'D' })) {
            $source = Join-Path $SourceRoot $item.Path
            $name = $item.Path.Substring('RockWeb/'.Length).Replace('/', $separator)
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($output, $source, $name, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        $base.Dispose()
        $baseStream.Dispose()
    }
}

function Invoke-ArtifactRepackage {
    <#
        .SYNOPSIS
        Makes the repackaged zip, its record and its outputs from a base artifact in the store.

        .DESCRIPTION
        Everything the repackage asks of the world is a parameter, so the
        Pester suite can run the whole of it -- a base that was itself
        repackaged, a base whose hash is wrong, a base with no record beside
        it -- against a store held in memory. The script body hands in the
        bucket and git.

        Store is an artifact store (see New-GsutilArtifactStore in
        ArtifactRecord.psm1); only its Download is used here. GetChange is
        called with the base commit and returns the name-status lines between
        it and the target. GetGeneratedThemeName returns the generated theme
        names in the target's tree. RuleSetPath is artifact-paths.json.

        CheckoutPath is the checkout of the target commit. The changed files
        are read from it, and the zip and its record are written into it,
        where the upload step looks for them. It must be absolute: the archive
        is opened through .NET, which resolves a relative path against the
        process's directory rather than PowerShell's. WorkPath is a directory
        for the base's download. OutputPath and SummaryPath are GITHUB_OUTPUT
        and GITHUB_STEP_SUMMARY.

        Any failure throws. There is no fallback to a build from here: a
        repackage that cannot be trusted fails the run, and the message says
        to rerun with force_build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseSha,
        [Parameter(Mandatory = $true)][string]$BaseObjectPath,
        [Parameter(Mandatory = $true)][string]$TargetSha,
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][string]$ArtifactSlug,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PrNumber,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][hashtable]$Store,
        [Parameter(Mandatory = $true)][scriptblock]$GetChange,
        [Parameter(Mandatory = $true)][scriptblock]$GetGeneratedThemeName,
        [Parameter(Mandatory = $true)][string]$RuleSetPath,
        [Parameter(Mandatory = $true)][string]$CheckoutPath,
        [Parameter(Mandatory = $true)][string]$WorkPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SummaryPath
    )

    # The plan names the base by its zip. Its record sits beside it, at the
    # address that path decodes to -- and a path that decodes to none is not
    # a zip any packaging job wrote, so there is nothing trustworthy to start
    # from.
    $baseAddress = ConvertFrom-ArtifactObjectPath -ObjectPath $BaseObjectPath
    if ($null -eq $baseAddress) {
        throw "$BaseObjectPath is not where a packaging job puts an artifact. Rerun with force_build to build instead."
    }

    $ruleSet = Get-Content -Raw -Path $RuleSetPath | ConvertFrom-Json
    $themes = @(& $GetGeneratedThemeName)
    $nameStatus = @(& $GetChange $BaseSha)
    $change = @(Get-ArtifactChangeClass -NameStatus $nameStatus -RuleSet $ruleSet -GeneratedThemeName $themes)

    New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
    $basePath = Join-Path $WorkPath 'base.zip'
    $baseRecordPath = Join-Path $WorkPath $baseAddress.RecordName

    try {
        $null = & $Store.Download -ObjectPath $BaseObjectPath -Destination $basePath
    }
    catch {
        throw "Could not download the base artifact gs://$Bucket/$BaseObjectPath ($($_.Exception.Message)). Rerun with force_build to build instead."
    }

    # The base's own record says which commit's compiled output it holds: a
    # base that was itself repackaged carries an older build than its
    # folder's commit. The build has always written this file beside its zip,
    # so its absence is tolerated -- the folder's commit is then the best
    # answer there is. Only the download is forgiven; a record that arrives
    # and disagrees with the zip is not.
    $builtFromSha = $BaseSha
    $isRecordFetched = $true
    try {
        $null = & $Store.Download -ObjectPath $baseAddress.RecordPath -Destination $baseRecordPath
    }
    catch {
        $isRecordFetched = $false
    }

    if ($isRecordFetched) {
        $baseRecord = Read-ArtifactRecord -Path $baseRecordPath
        if ($baseRecord.builtFromSha) {
            $builtFromSha = $baseRecord.builtFromSha
        }

        # A zip cut short on upload still opens, minus whatever was cut.
        $recordedHash = $baseRecord.sha256
        $actualHash = (Get-FileHash -Path $basePath -Algorithm SHA256).Hash
        $isHashMismatched = $recordedHash -and $recordedHash -ne $actualHash
        if ($isHashMismatched) {
            throw "The base artifact's SHA-256 is $actualHash but its metadata says $recordedHash. Rerun with force_build to build instead."
        }
    }
    else {
        Write-Host "::warning::No pr-test-artifact.json beside $BaseObjectPath; recording $BaseSha as the build this artifact carries."
    }

    $address = Get-ArtifactAddress -Slug $ArtifactSlug -Sha $TargetSha
    $artifactPath = Join-Path $CheckoutPath $address.Name
    New-PatchedArtifactArchive -BasePath $basePath -DestinationPath $artifactPath -SourceRoot $CheckoutPath -Change $change

    # The record and outputs a build writes, from the same module the build
    # uses, plus the two fields only a repackage has.
    $record = New-ArtifactRecord -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName `
        -Sha256 (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash -BuiltFromSha $builtFromSha -BaseObjectPath $BaseObjectPath
    Write-ArtifactRecord -Record $record -Path (Join-Path $CheckoutPath $address.RecordName)
    Write-ArtifactOutput -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName -Path $OutputPath

    $patched = @($change | Where-Object { $_.Class -eq 'patch' })
    @(
        '### Repackaged artifact',
        '',
        "``$($address.Name)`` is ``$BaseObjectPath`` with $($patched.Count) file(s) swapped in. Its compiled output was built from ``$builtFromSha``."
    ) -join "`n" | Out-File -FilePath $SummaryPath -Append
}

Import-Module (Join-Path $PSScriptRoot 'ArtifactPaths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force

# The real store and the real git. The working directory is the checkout of
# the target, and the base is downloaded beside other runs' in the temp
# directory, where it always has been.
Invoke-ArtifactRepackage -BaseSha $BaseSha -BaseObjectPath $BaseObjectPath -TargetSha $TargetSha `
    -Bucket $Bucket -ArtifactSlug $ArtifactSlug -PrNumber $PrNumber -HostName $HostName `
    -Store (New-GsutilArtifactStore -Bucket $Bucket) `
    -GetChange { param($Sha) Get-ArtifactTreeChange -BaseSha $Sha -TargetSha $TargetSha } `
    -GetGeneratedThemeName { Get-GeneratedThemeName -Sha $TargetSha } `
    -RuleSetPath (Join-Path $PSScriptRoot 'artifact-paths.json') `
    -CheckoutPath (Get-Location).Path `
    -WorkPath (Join-Path ([System.IO.Path]::GetTempPath()) "rockweb-base-$BaseSha") `
    -OutputPath $env:GITHUB_OUTPUT `
    -SummaryPath $env:GITHUB_STEP_SUMMARY
