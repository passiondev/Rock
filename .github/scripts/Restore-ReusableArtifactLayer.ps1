<#
.SYNOPSIS
    Extracts untouched compiled layer(s) (dotnet, js-obsidian, js-blocks,
    js-misc) from a verified base artifact zip in GCS into RockWeb/.

.DESCRIPTION
    Enables partial-layer GCS artifact reuse: when a PR only touches JS, the
    .NET job is skipped and RockWeb/Bin is extracted from a verified base zip;
    when a PR only touches C#, untouched JS layers can be extracted from the
    verified base zip.

    Before extracting anything, validates the base object path via
    ConvertFrom-ArtifactObjectPath and verifies the downloaded zip's SHA-256
    against its sibling pr-test-artifact.json record (exact same integrity
    contract as New-RepackagedArtifact.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseObjectPath,
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $true)][string[]]$Layer,
    [Parameter(Mandatory = $false)][string]$RockWebPath = 'RockWeb',
    [Parameter(Mandatory = $false)][string[]]$GeneratedThemeName = @('RockNextGen', 'RockManagerNextGen', 'NextGenCheckin')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-EntryBelongsToLayer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string[]]$Layers,
        [Parameter(Mandatory = $true)][string[]]$Themes
    )

    $norm = $EntryPath.Replace('\', '/').TrimStart('/')
    foreach ($l in $Layers) {
        switch ($l) {
            'dotnet' {
                if ($norm -like 'Bin/*') { return $true }
            }
            'js-obsidian' {
                if ($norm -like 'Obsidian/*' -and -not ($norm -like 'Obsidian/Blocks/*')) { return $true }
            }
            'js-blocks' {
                if ($norm -like 'Obsidian/Blocks/*') { return $true }
            }
            'js-misc' {
                if ($norm -like 'Scripts/Rock/Monaco/*' -or
                    $norm -like 'Scripts/Rock/UI/structuredcontenteditor/*' -or
                    $norm -like 'Styles/styles-v2/*' -or
                    $norm -ieq 'Scripts/Rock/realtime.js' -or $norm -ieq 'Scripts/Rock/realtime.js.map' -or
                    $norm -ieq 'Scripts/Rock/plyr.js' -or $norm -ieq 'Scripts/Rock/plyr.js.map' -or
                    $norm -ieq 'Scripts/Rock/streamchat.js' -or $norm -ieq 'Scripts/Rock/streamchat.js.map') {
                    return $true
                }
                foreach ($theme in $Themes) {
                    if ($norm -like "Themes/$theme/*") { return $true }
                }
            }
        }
    }
    return $false
}

function Expand-ArtifactLayerFromZip {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string[]]$Layers,
        [Parameter(Mandatory = $true)][string[]]$Themes
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fullDest = [System.IO.Path]::GetFullPath($DestinationRoot)
    $extracted = 0

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $norm = $entry.FullName.Replace('\', '/').TrimStart('/')
            if (-not (Test-EntryBelongsToLayer -EntryPath $norm -Layers $Layers -Themes $Themes)) {
                continue
            }

            # Canonicalize leading bin/ -> Bin/ so case-sensitive Linux matches git's RockWeb/Bin.
            if ($norm -match '^bin/(.+)$') {
                $norm = 'Bin/' + $Matches[1]
            }

            $outPath = Join-Path $fullDest $norm
            $outDir = Split-Path -Path $outPath -Parent
            if (-not (Test-Path -LiteralPath $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }

            $inStream = $entry.Open()
            $outStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
            try {
                $inStream.CopyTo($outStream)
            }
            finally {
                $outStream.Dispose()
                $inStream.Dispose()
            }
            $extracted++
        }
    }
    finally {
        $archive.Dispose()
    }

    return $extracted
}

function Invoke-RestoreReusableLayer {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$BaseObjectPath,
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][string[]]$Layers,
        [Parameter(Mandatory = $true)][string]$RockWebRoot,
        [Parameter(Mandatory = $true)][string[]]$Themes,
        [Parameter(Mandatory = $true)][hashtable]$Store,
        [Parameter(Mandatory = $true)][string]$WorkPath
    )

    $baseAddress = ConvertFrom-ArtifactObjectPath -ObjectPath $BaseObjectPath
    if ($null -eq $baseAddress) {
        throw "$BaseObjectPath is not a valid artifact address. Rerun with force_build to build everything."
    }

    New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
    $baseZip = Join-Path $WorkPath 'base.zip'
    $baseRecordPath = Join-Path $WorkPath $baseAddress.RecordName

    try {
        $null = & $Store.Download -ObjectPath $BaseObjectPath -Destination $baseZip
    }
    catch {
        throw "Could not download base artifact gs://$Bucket/$BaseObjectPath ($($_.Exception.Message)). Rerun with force_build."
    }

    $hasRecord = $true
    try {
        $null = & $Store.Download -ObjectPath $baseAddress.RecordPath -Destination $baseRecordPath
    }
    catch {
        $hasRecord = $false
    }

    if ($hasRecord) {
        $record = Read-ArtifactRecord -Path $baseRecordPath
        $recordedHash = $record.sha256
        $actualHash = (Get-FileHash -Path $baseZip -Algorithm SHA256).Hash
        if ($recordedHash -and $recordedHash -ne $actualHash) {
            throw "Base artifact SHA-256 is $actualHash but metadata says $recordedHash. Rerun with force_build."
        }
    }

    return Expand-ArtifactLayerFromZip -ZipPath $baseZip -DestinationRoot $RockWebRoot -Layers $Layers -Themes $Themes
}

if ($MyInvocation.InvocationName -ne '.') {
    Import-Module (Join-Path $PSScriptRoot 'ArtifactRecord.psm1') -Force
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("rock-layer-reuse-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $count = Invoke-RestoreReusableLayer `
            -BaseObjectPath $BaseObjectPath -Bucket $Bucket -Layers $Layer `
            -RockWebRoot (Resolve-Path -LiteralPath $RockWebPath).Path `
            -Themes $GeneratedThemeName `
            -Store (New-GsutilArtifactStore -Bucket $Bucket) `
            -WorkPath $work
        Write-Host "Restored $count file(s) for layer(s) [$($Layer -join ', ')] from $BaseObjectPath"
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
