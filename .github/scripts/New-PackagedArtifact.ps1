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

Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force

$address = Get-ArtifactAddress -Slug $ArtifactSlug -Sha $TargetSha

# The contents of RockWeb rather than the directory, so web.config is at the
# zip's root, where the deploy expands it into the site.
Compress-Archive -Path (Join-Path 'RockWeb' '*') -DestinationPath $address.Name -Force
$hash = (Get-FileHash -Path $address.Name -Algorithm SHA256).Hash

$record = New-ArtifactRecord -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName -Sha256 $hash
Write-ArtifactRecord -Record $record -Path $address.RecordName
Write-ArtifactOutput -Address $address -Bucket $Bucket -PrNumber $PrNumber -HostName $HostName -Path $env:GITHUB_OUTPUT
