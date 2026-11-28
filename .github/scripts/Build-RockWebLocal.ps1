<#
.SYNOPSIS
    Fast local RockWeb build for macOS, Linux, and Windows developers.

.DESCRIPTION
    Uses the exact same cross-platform .NET 9 SDK + parallel Node build scripts
    that power pr-test-artifact.yml on ubuntu-latest:
      - Compiles all 29 shipped net472 Rock assemblies (~15s on Apple Silicon)
      - Resolves all 158 RockWeb/Bin/*.dll.refresh pointers from ~/.nuget/packages
      - Runs JS/CSS packages (parallel webpack, parallel Obsidian core + rollup,
        decoupled Obsidian.Blocks rollup)
      - Verifies every required assembly, Obsidian block, and styles-v2 sheet
      - Optionally packages a deployable RockWeb zip (-Package) or syncs into a
        local Windows VM IIS share (-DeployDir).

.EXAMPLE
    ./.github/scripts/Build-RockWebLocal.ps1 -DotNetOnly
    ./.github/scripts/Build-RockWebLocal.ps1 -SkipInstall -Package
    ./.github/scripts/Build-RockWebLocal.ps1 -DeployDir /Volumes/WindowsVM/RockWeb
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory = $false)][switch]$DotNetOnly,
    [Parameter(Mandatory = $false)][switch]$JsOnly,
    [Parameter(Mandatory = $false)][switch]$SkipInstall,
    [Parameter(Mandatory = $false)][switch]$NoRestore,
    [Parameter(Mandatory = $false)][switch]$Typecheck,
    [Parameter(Mandatory = $false)][switch]$Package,
    [Parameter(Mandatory = $false)][string]$PackageOut = '',
    [Parameter(Mandatory = $false)][string]$DeployDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$scriptDir = $PSScriptRoot
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $JsOnly) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host '==> Building .NET (29 required net472 projects)...'
    & (Join-Path $scriptDir 'Invoke-RockDotNetBuild.ps1') -RepoRoot $resolvedRoot -NoRestore:$NoRestore
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host ("    .NET finished in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}

if (-not $DotNetOnly) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host '==> Building JavaScript & Styles packages...'
    & (Join-Path $scriptDir 'Invoke-RockJsBuild.ps1') -Package all -RepoRoot $resolvedRoot -SkipInstall:$SkipInstall
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host ("    JS finished in {0:N1}s" -f $sw.Elapsed.TotalSeconds)

    if ($Typecheck) {
        $tcSw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host '==> Running Obsidian + Blocks typecheck (MaxConcurrency=4)...'
        & (Join-Path $scriptDir 'Invoke-RockJsBuild.ps1') -Package typecheck -RepoRoot $resolvedRoot -SkipInstall
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host ("    Typecheck finished in {0:N1}s" -f $tcSw.Elapsed.TotalSeconds)
    }
}

if (-not $DotNetOnly -and -not $JsOnly) {
    Write-Host '==> Verifying RockWeb artifact...'
    & (Join-Path $scriptDir 'Test-RockWebArtifact.ps1') -RockWebPath (Join-Path $resolvedRoot 'RockWeb')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Package) {
    $zipSw = [System.Diagnostics.Stopwatch]::StartNew()
    $sha = (git -C $resolvedRoot rev-parse --short=7 HEAD 2>$null)
    if (-not $sha) { $sha = 'local' }
    if (-not $PackageOut) {
        $PackageOut = Join-Path $resolvedRoot "RockWeb-local-$sha.zip"
    }
    $absOut = [System.IO.Path]::GetFullPath($PackageOut)
    if (Test-Path -LiteralPath $absOut) { Remove-Item -LiteralPath $absOut -Force }

    $rockWebDir = Join-Path $resolvedRoot 'RockWeb'
    Write-Host "==> Packaging $absOut..."
    Push-Location $rockWebDir
    try {
        if (Get-Command 7z -ErrorAction SilentlyContinue) {
            & 7z a -tzip -mx=1 -mmt=on -bd -bso0 $absOut '.'
            if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }
        }
        elseif (Get-Command zip -ErrorAction SilentlyContinue) {
            & zip -qr -1 $absOut '.'
            if ($LASTEXITCODE -ne 0) { throw "zip failed (exit $LASTEXITCODE)" }
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($rockWebDir, $absOut, [System.IO.Compression.CompressionLevel]::Fastest, $false)
        }
    }
    finally {
        Pop-Location
    }
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $absOut).Length / 1MB, 1)
    Write-Host ("    Packaged {0} MB in {1:N1}s" -f $sizeMb, $zipSw.Elapsed.TotalSeconds)
}

if ($DeployDir) {
    $syncSw = [System.Diagnostics.Stopwatch]::StartNew()
    $rockWebDir = Join-Path $resolvedRoot 'RockWeb'
    Write-Host "==> Syncing RockWeb -> $DeployDir..."
    if (-not (Test-Path -LiteralPath $DeployDir)) {
        New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
    }
    if (Get-Command rsync -ErrorAction SilentlyContinue) {
        # Preserve server-owned runtime folders on the local VM just like Deploy-RockEnvironment.ps1.
        & rsync -a --delete `
            --exclude 'web.ConnectionStrings.config' `
            --exclude 'App_Data/**' `
            --exclude 'Content/**' `
            --exclude 'Logs/**' `
            --exclude 'Uploads/**' `
            "$rockWebDir/" "$DeployDir/"
        if ($LASTEXITCODE -ne 0) { throw "rsync failed (exit $LASTEXITCODE)" }
    }
    else {
        Copy-Item -Path (Join-Path $rockWebDir '*') -Destination $DeployDir -Recurse -Force
    }
    Write-Host ("    Synced in {0:N1}s" -f $syncSw.Elapsed.TotalSeconds)
}

Write-Host ("==> Local RockWeb build complete in {0:N1}s" -f $totalSw.Elapsed.TotalSeconds)
