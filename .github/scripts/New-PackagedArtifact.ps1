<#
.SYNOPSIS
    Zips a built RockWeb and records it beside the zip: the last step of
    pr-test-artifact.yml's package job.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run it
    -- see Tests/PrTestEnvironments/Pester/ArtifactRecord.Tests.ps1. Where the
    zip goes and what its record says come from ArtifactRecord.psm1, which the
    plan and the repackage read too, so a built artifact and a repackaged one
    are named, found and recorded by one piece of code.

    The package job runs this from a second checkout, of the commit the
    workflow itself came from, rather than from the target it builds. The
    target can predate this file -- an older pull request head, or the commit
    production promotes -- and the package job has to build every one of them.
    Nothing here depends on the target: it zips whatever the build left in
    RockWeb.

.PARAMETER TargetSha
    The commit the build compiled.

.PARAMETER ArtifactSlug
    This run's artifact folder: pr-<number>, staging or production.

.PARAMETER Bucket
    The deployment bucket, for the gs:// path the record carries and the
    destination the job's uploads take.

.PARAMETER PrNumber
    Recorded in the metadata and handed on as an output.

.PARAMETER HostName
    Recorded in the metadata and handed on as an output.

.OUTPUTS
    The zip and pr-test-artifact.json in the working directory, and
    artifact_name, artifact_gcs_object_path, host_name, pr_number, sha and
    artifact_gcs_destination in GITHUB_OUTPUT -- the outputs the repackage job
    writes too.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetSha,
    [Parameter(Mandatory = $true)][string]$ArtifactSlug,
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PrNumber = '',
    [Parameter(Mandatory = $false)][AllowEmptyString()][string]$HostName = ''
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force

$address = Get-ArtifactAddress -Slug $ArtifactSlug -Sha $TargetSha
$destPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $address.Name))
$rockWebPath = (Resolve-Path -LiteralPath 'RockWeb').Path

if (Test-Path -LiteralPath $destPath) {
    Remove-Item -LiteralPath $destPath -Force
}

# The contents of RockWeb rather than the directory, so web.config is at the
# zip's root, where the deploy expands it into the site. Prefer multi-threaded
# 7z or native zip (-1) over PowerShell's Compress-Archive (~3-10x faster on
# 5,100+ files), with .NET ZipFile Fastest as the universal fallback.
Push-Location $rockWebPath
try {
    if (Get-Command 7z -ErrorAction SilentlyContinue) {
        & 7z a -tzip -mx=1 -mmt=on -bd -bso0 $destPath '.'
        if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }
    }
    elseif (Get-Command zip -ErrorAction SilentlyContinue) {
        & zip -qr -1 $destPath '.'
        if ($LASTEXITCODE -ne 0) { throw "zip failed (exit $LASTEXITCODE)" }
    }
    else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $rockWebPath,
            $destPath,
            [System.IO.Compression.CompressionLevel]::Fastest,
            $false
        )
    }
}
finally {
    Pop-Location
}

$hash = (Get-FileHash -Path $destPath -Algorithm SHA256).Hash

$record = New-ArtifactRecord -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName -Sha256 $hash
Write-ArtifactRecord -Record $record -Path $address.RecordName
Write-ArtifactOutput -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName -Path $env:GITHUB_OUTPUT
