<#
.SYNOPSIS
    Builds a deployable RockWeb zip from an earlier artifact plus the files that
    changed since, without compiling anything.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run the
    archive edit -- see Tests/PrTestEnvironments/Pester/ArtifactRepackage.Tests.ps1.

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
    The deployment bucket.

.PARAMETER ArtifactSlug
    This run's artifact folder: pr-<number>, staging or production.

.PARAMETER PrNumber
    Recorded in the metadata, as the build records it.

.PARAMETER HostName
    Recorded in the metadata, as the build records it.

.OUTPUTS
    The zip and pr-test-artifact.json in the working directory, and
    artifact_name, artifact_gcs_object_path, host_name, pr_number and sha in
    GITHUB_OUTPUT -- the outputs the package job writes.
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

Import-Module (Join-Path $PSScriptRoot 'ArtifactPaths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force

# The plan names the base by its zip. Its record sits beside it, at the address
# that path decodes to -- and a path that decodes to none is not a zip any
# packaging job wrote, so there is nothing trustworthy to start from.
$baseAddress = ConvertFrom-ArtifactObjectPath -ObjectPath $BaseObjectPath
if ($null -eq $baseAddress) {
    throw "$BaseObjectPath is not where a packaging job puts an artifact. Rerun with force_build to build instead."
}

$ruleSet = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'artifact-paths.json') | ConvertFrom-Json
$themes = @(Get-GeneratedThemeName -Sha $TargetSha)
$nameStatus = @(Get-ArtifactTreeChange -BaseSha $BaseSha -TargetSha $TargetSha)
$change = @(Get-ArtifactChangeClass -NameStatus $nameStatus -RuleSet $ruleSet -GeneratedThemeName $themes)

$work = Join-Path ([System.IO.Path]::GetTempPath()) "rockweb-base-$BaseSha"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$basePath = Join-Path $work 'base.zip'
$baseRecordPath = Join-Path $work $baseAddress.RecordName

gsutil -q cp "gs://$Bucket/$BaseObjectPath" $basePath
if ($LASTEXITCODE -ne 0) {
    throw "Could not download the base artifact gs://$Bucket/$BaseObjectPath (exit $LASTEXITCODE). Rerun with force_build to build instead."
}

# The base's own record says which commit's compiled output it holds: a base
# that was itself repackaged carries an older build than its folder's commit.
# The build has always written this file beside its zip, so its absence is
# tolerated -- the folder's commit is then the best answer there is.
$builtFromSha = $BaseSha
gsutil -q cp "gs://$Bucket/$($baseAddress.RecordPath)" $baseRecordPath
if ($LASTEXITCODE -eq 0) {
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

# Absolute, because the archive is opened through .NET, which resolves a
# relative path against the process's directory rather than PowerShell's.
$artifactPath = Join-Path (Get-Location).Path $address.Name
New-PatchedArtifactArchive -BasePath $basePath -DestinationPath $artifactPath -SourceRoot (Get-Location).Path -Change $change

# The record and outputs a build writes, from the same module the build uses,
# plus the two fields only a repackage has.
$record = New-ArtifactRecord -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName `
    -Sha256 (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash -BuiltFromSha $builtFromSha -BaseObjectPath $BaseObjectPath
Write-ArtifactRecord -Record $record -Path $address.RecordName
Write-ArtifactOutput -Address $address -PrNumber $PrNumber -HostName $HostName -Path $env:GITHUB_OUTPUT

$patched = @($change | Where-Object { $_.Class -eq 'patch' })
@(
    '### Repackaged artifact',
    '',
    "``$($address.Name)`` is ``$BaseObjectPath`` with $($patched.Count) file(s) swapped in. Its compiled output was built from ``$builtFromSha``."
) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
