<#
.SYNOPSIS
    Cross-platform parallel JavaScript/CSS builder for RockWeb (Linux, macOS,
    and Windows).

.DESCRIPTION
    Supports running individual parallel CI shards (misc, obsidian, blocks,
    typecheck) or all packages locally with the optimizations proven in
    benchmarking:
      - Rock.JavaScript runs webpack and webpack.config.monaco.js in parallel.
      - Rock.JavaScript.Obsidian runs build-core (webpack + lessc + cleancss +
        copy-webforms-core) in parallel with rollup-mt.js.
      - Rock.JavaScript.Obsidian.Blocks runs rollup-mt.js directly without
        waiting for Rock.JavaScript.Obsidian/dist (Babel strips TS types and
        marks @Obsidian/* imports external).
      - Rock.Frontend.Styles is guarded on Rock.Frontend.Styles/package-lock.json
        so 18.4.1 branches continue to build cleanly.
      - TypeScript declaration/typecheck (build:types / vue-tsc) runs with
        MaxConcurrency = 4 (instead of Math.floor(4/3) = 1 on 4-core runners)
        without editing upstream Build/build-tools.js.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('all', 'misc', 'obsidian', 'blocks', 'typecheck', 'javascript', 'editorjs', 'styles')]
    [string]$Package = 'all',

    [Parameter(Mandatory = $false)][string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory = $false)][string]$NpmCacheDir = '',
    [Parameter(Mandatory = $false)][switch]$SkipInstall,
    [Parameter(Mandatory = $false)][switch]$SkipJavaScript,
    [Parameter(Mandatory = $false)][switch]$SkipEditorJs,
    [Parameter(Mandatory = $false)][switch]$SkipStyles,
    [Parameter(Mandatory = $false)][switch]$SkipObsidian,
    [Parameter(Mandatory = $false)][switch]$SkipBlocks,
    [Parameter(Mandatory = $false)][int]$TypecheckConcurrency = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NpmCi {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDir,
        [Parameter(Mandatory = $false)][string]$CacheDir = ''
    )

    $args = @('ci', '--prefer-offline')
    if (-not [string]::IsNullOrWhiteSpace($CacheDir)) {
        $args += @('--cache', $CacheDir)
    }

    Push-Location $WorkingDir
    try {
        & npm @args
        if ($LASTEXITCODE -ne 0) {
            throw "npm ci failed ($LASTEXITCODE) in $WorkingDir"
        }
    }
    finally {
        Pop-Location
    }
}

function Start-BackgroundProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDir,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $outLog = Join-Path $LogDir "$Name.out.log"
    $errLog = Join-Path $LogDir "$Name.err.log"
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDir `
        -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog

    return [pscustomobject]@{
        Name = $Name
        Process = $proc
        OutLog = $outLog
        ErrLog = $errLog
    }
}

function Wait-BackgroundProcesses {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items
    )

    $failed = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $item.Process.WaitForExit()
        $code = $item.Process.ExitCode
        Write-Host "===== $($item.Name) (exit $code) ====="
        foreach ($log in @($item.OutLog, $item.ErrLog)) {
            if (Test-Path -LiteralPath $log) {
                $content = Get-Content -Raw -Path $log
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    Write-Host $content.TrimEnd()
                }
            }
        }
        if ($code -ne 0) {
            $failed += "$($item.Name) (exit $code)"
        }
    }

    if ($failed.Count -gt 0) {
        throw "Parallel JS task(s) failed: $($failed -join ', ')"
    }
}

function Get-NpmExecutable {
    if ($IsWindows) { return 'npm.cmd' }
    return 'npm'
}

function Get-NpxExecutable {
    if ($IsWindows) { return 'npx.cmd' }
    return 'npx'
}

function Build-RockJavaScript {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall, [string]$LogDir)
    $dir = Join-Path $Root 'Rock.JavaScript'
    if (-not $NoInstall) {
        Write-Host '::group::Install Rock.JavaScript Dependencies'
        Invoke-NpmCi -WorkingDir $dir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }

    Write-Host '::group::Build Rock.JavaScript (parallel webpack + monaco)'
    # Match prebuild: rimraf ../RockWeb/Scripts/Rock/Monaco
    $monacoOut = Join-Path $Root (Join-Path 'RockWeb' (Join-Path 'Scripts' (Join-Path 'Rock' 'Monaco')))
    if (Test-Path -LiteralPath $monacoOut) {
        Remove-Item -LiteralPath $monacoOut -Recurse -Force
    }

    $npx = Get-NpxExecutable
    $procs = @(
        Start-BackgroundProcess -Name 'rock-js-webpack' -FilePath $npx -ArgumentList @('webpack', '--no-color') -WorkingDir $dir -LogDir $LogDir
        Start-BackgroundProcess -Name 'rock-js-monaco' -FilePath $npx -ArgumentList @('webpack', '--config', './webpack.config.monaco.js', '--no-color') -WorkingDir $dir -LogDir $LogDir
    )
    Wait-BackgroundProcesses -Items $procs
    Write-Host '::endgroup::'
}

function Build-RockEditorJs {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall)
    $dir = Join-Path $Root 'Rock.JavaScript.EditorJs'
    if (-not $NoInstall) {
        Write-Host '::group::Install Rock.JavaScript.EditorJs Dependencies'
        Invoke-NpmCi -WorkingDir $dir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }
    Write-Host '::group::Build Rock.JavaScript.EditorJs'
    Push-Location $dir
    try {
        & npm run build
        if ($LASTEXITCODE -ne 0) { throw "Rock.JavaScript.EditorJs build failed ($LASTEXITCODE)" }
    }
    finally { Pop-Location }
    Write-Host '::endgroup::'
}

function Build-RockStyles {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall)
    $dir = Join-Path $Root 'Rock.Frontend.Styles'
    $lock = Join-Path $dir 'package-lock.json'
    if (-not (Test-Path -LiteralPath $lock)) {
        Write-Host 'Skip Rock.Frontend.Styles (package-lock.json not present on this branch)'
        return
    }
    if (-not $NoInstall) {
        Write-Host '::group::Install Rock.Frontend.Styles Dependencies'
        Invoke-NpmCi -WorkingDir $dir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }
    Write-Host '::group::Build Rock.Frontend.Styles'
    $stylesAlias = $null
    if ($IsLinux) {
        $srcDir = Join-Path $dir 'src'
        $lowerStyles = Join-Path $srcDir 'styles'
        $upperStyles = Join-Path $srcDir 'Styles'
        if ((Test-Path -LiteralPath $lowerStyles) -and -not (Test-Path -LiteralPath $upperStyles)) {
            New-Item -ItemType SymbolicLink -Path $upperStyles -Target 'styles' -Force | Out-Null
            $stylesAlias = $upperStyles
        }
    }
    Push-Location $dir
    try {
        & npm run build
        if ($LASTEXITCODE -ne 0) { throw "Rock.Frontend.Styles build failed ($LASTEXITCODE)" }
    }
    finally {
        Pop-Location
        if ($stylesAlias -and [System.IO.Directory]::Exists($stylesAlias)) {
            try { [System.IO.Directory]::Delete($stylesAlias, $false) } catch { }
        }
    }
    Write-Host '::endgroup::'
}

function Build-RockObsidian {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall, [string]$LogDir)
    $dir = Join-Path $Root 'Rock.JavaScript.Obsidian'
    if (-not $NoInstall) {
        Write-Host '::group::Install Rock.JavaScript.Obsidian Dependencies'
        Invoke-NpmCi -WorkingDir $dir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }

    Write-Host '::group::Build Rock.JavaScript.Obsidian (parallel build-core + rollup-mt)'
    $npm = Get-NpmExecutable
    $procs = @(
        Start-BackgroundProcess -Name 'obsidian-core' -FilePath $npm -ArgumentList @('run', 'build-core') -WorkingDir $dir -LogDir $LogDir
        Start-BackgroundProcess -Name 'obsidian-rollup' -FilePath 'node' -ArgumentList @('./Build/rollup-mt.js', 'Framework/rollup.config.cjs') -WorkingDir $dir -LogDir $LogDir
    )
    Wait-BackgroundProcesses -Items $procs

    Push-Location $dir
    try {
        & npm run copy-webforms-core
        if ($LASTEXITCODE -ne 0) { throw "copy-webforms-core failed ($LASTEXITCODE)" }
        $distDir = Join-Path $dir 'dist'
        if (-not (Test-Path -LiteralPath $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }
        Set-Content -Path (Join-Path $distDir '.buildstamp') -Value '' -Encoding utf8
    }
    finally { Pop-Location }
    Write-Host '::endgroup::'
}

function Build-RockBlocks {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall)
    $obsDir = Join-Path $Root 'Rock.JavaScript.Obsidian'
    $dir = Join-Path $Root 'Rock.JavaScript.Obsidian.Blocks'
    if (-not $NoInstall) {
        if (-not (Test-Path -LiteralPath (Join-Path $obsDir 'node_modules'))) {
            Write-Host '::group::Install Rock.JavaScript.Obsidian Dependencies (shared rollup/terser plugins)'
            Invoke-NpmCi -WorkingDir $obsDir -CacheDir $CacheDir
            Write-Host '::endgroup::'
        }
        Write-Host '::group::Install Rock.JavaScript.Obsidian.Blocks Dependencies'
        Invoke-NpmCi -WorkingDir $dir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }

    Write-Host '::group::Build Rock.JavaScript.Obsidian.Blocks (rollup-mt)'
    Push-Location $dir
    try {
        & node '../Rock.JavaScript.Obsidian/Build/rollup-mt.js' 'rollup.config.cjs'
        if ($LASTEXITCODE -ne 0) { throw "Obsidian.Blocks rollup-mt failed ($LASTEXITCODE)" }
        $distDir = Join-Path $dir 'dist'
        if (-not (Test-Path -LiteralPath $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }
        Set-Content -Path (Join-Path $distDir '.buildstamp') -Value '' -Encoding utf8
    }
    finally {
        Pop-Location
    }
    Write-Host '::endgroup::'
}

function Invoke-ObsidianTypecheck {
    param([string]$Root, [string]$CacheDir, [bool]$NoInstall, [int]$Concurrency)
    $obsDir = Join-Path $Root 'Rock.JavaScript.Obsidian'
    $blkDir = Join-Path $Root 'Rock.JavaScript.Obsidian.Blocks'
    $effective = [Math]::Max(1, $Concurrency)
    $fakeCpuCount = $effective * 3

    if (-not $NoInstall) {
        Write-Host '::group::Install Obsidian + Blocks Dependencies for typecheck'
        Invoke-NpmCi -WorkingDir $obsDir -CacheDir $CacheDir
        Invoke-NpmCi -WorkingDir $blkDir -CacheDir $CacheDir
        Write-Host '::endgroup::'
    }

    $buildAlias = $null
    $backupDir = $null
    $normalizeScript = $null
    if ($IsLinux) {
        $upperBuild = Join-Path $obsDir 'Build'
        $lowerBuild = Join-Path $obsDir 'build'
        if ((Test-Path -LiteralPath $upperBuild) -and -not (Test-Path -LiteralPath $lowerBuild)) {
            New-Item -ItemType SymbolicLink -Path $lowerBuild -Target 'Build' -Force | Out-Null
            $buildAlias = $lowerBuild
        }

        # Normalize case-mismatched @Obsidian/* and relative imports on Linux
        # (case-sensitive ext4) without modifying tracked source permanently.
        $backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rock-ts-case-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $normalizeScript = Join-Path $backupDir 'fix-case.cjs'
        @'
const fs = require('fs');
const path = require('path');

const mode = process.argv[2];
const root = process.argv[3];
const backupDir = process.argv[4];
const manifestPath = path.join(backupDir, 'manifest.json');

if (mode === 'restore') {
    if (fs.existsSync(manifestPath)) {
        const items = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
        for (const item of items) {
            if (fs.existsSync(item.backup)) {
                fs.copyFileSync(item.backup, item.original);
            }
        }
    }
    process.exit(0);
}

const obsFw = path.join(root, 'Rock.JavaScript.Obsidian', 'Framework');
const dirCache = new Map();
function listDir(d) {
    let entries = dirCache.get(d);
    if (!entries) {
        try { entries = fs.readdirSync(d); } catch { entries = []; }
        dirCache.set(d, entries);
    }
    return entries;
}

function resolveExact(baseDir, relPath) {
    const segs = relPath.split('/').filter(Boolean);
    let cur = baseDir;
    const out = [];
    for (const seg of segs) {
        if (seg === '.' || seg === '..') {
            out.push(seg);
            cur = path.resolve(cur, seg);
            continue;
        }
        const entries = listDir(cur);
        if (entries.includes(seg)) {
            out.push(seg);
            cur = path.join(cur, seg);
            continue;
        }
        const low = seg.toLowerCase();
        const found = entries.find(e => e.toLowerCase() === low);
        if (!found) return null;
        out.push(found);
        cur = path.join(cur, found);
    }
    return out.join('/');
}

const suffixes = ['', '.ts', '.d.ts', '.obs', '.vue', '.js', '/index.ts', '/index.d.ts'];
function resolveImportSpec(fileDir, spec) {
    const isAlias = spec.startsWith('@Obsidian/');
    const baseDir = isAlias ? obsFw : fileDir;
    const rawRel = isAlias ? spec.slice('@Obsidian/'.length) : spec;
    const prefix = isAlias ? '@Obsidian/' : (rawRel.startsWith('./') ? './' : '');
    const cleanRel = rawRel.startsWith('./') ? rawRel.slice(2) : rawRel;

    for (const suf of suffixes) {
        const resolved = resolveExact(baseDir, cleanRel + suf);
        if (!resolved) continue;
        let finalRel = suf ? resolved.slice(0, resolved.length - suf.length) : resolved;
        if (!isAlias && !finalRel.startsWith('.')) finalRel = './' + finalRel;
        const candidate = isAlias ? ('@Obsidian/' + finalRel) : finalRel;
        return candidate !== spec ? candidate : null;
    }
    return null;
}

function walk(dir, out) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name === 'node_modules' || entry.name === 'dist') continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full, out);
        else if (/\.(ts|obs|vue)$/.test(entry.name)) out.push(full);
    }
}

const files = [];
walk(obsFw, files);
walk(path.join(root, 'Rock.JavaScript.Obsidian.Blocks', 'src'), files);

const manifest = [];
const importRe = /(from\s+["']|import\s*\(\s*["'])(@Obsidian\/[^"']+|\.[^"']+)(["'])/g;
let patchCount = 0;

for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    const fileDir = path.dirname(file);
    let changed = false;
    const updated = text.replace(importRe, (m, pre, spec, post) => {
        const fixed = resolveImportSpec(fileDir, spec);
        if (fixed) {
            changed = true;
            return pre + fixed + post;
        }
        return m;
    });
    if (changed) {
        const backup = path.join(backupDir, `f-${manifest.length}.bak`);
        fs.copyFileSync(file, backup);
        fs.writeFileSync(file, updated, 'utf8');
        manifest.push({ original: file, backup });
        patchCount++;
    }
}

fs.writeFileSync(manifestPath, JSON.stringify(manifest), 'utf8');
console.log(`Normalized Linux import casing in ${patchCount} Obsidian/Blocks file(s) for typecheck.`);
'@ | Set-Content -Path $normalizeScript -Encoding utf8

        & node $normalizeScript 'apply' $Root $backupDir
        if ($LASTEXITCODE -ne 0) { throw "Linux import casing normalization failed ($LASTEXITCODE)" }
    }

    try {
        Write-Host "::group::Typecheck Rock.JavaScript.Obsidian (MaxConcurrency=$effective)"
        Push-Location $obsDir
        try {
            & node -e "const os = require('os'); os.cpus = () => Array($fakeCpuCount).fill({}); require('./Build/build-types.js');"
            if ($LASTEXITCODE -ne 0) { throw "Obsidian build:types failed ($LASTEXITCODE)" }
        }
        finally { Pop-Location }
        Write-Host '::endgroup::'

        Write-Host "::group::Typecheck Rock.JavaScript.Obsidian.Blocks (MaxConcurrency=$effective)"
        Push-Location $blkDir
        try {
            & node -e "const os = require('os'); os.cpus = () => Array($fakeCpuCount).fill({}); require('./build/build-types.js');"
            if ($LASTEXITCODE -ne 0) { throw "Obsidian.Blocks build:types failed ($LASTEXITCODE)" }
        }
        finally { Pop-Location }
        Write-Host '::endgroup::'
    }
    finally {
        if ($normalizeScript -and (Test-Path -LiteralPath $normalizeScript)) {
            try { & node $normalizeScript 'restore' $Root $backupDir } catch { }
        }
        if ($backupDir -and (Test-Path -LiteralPath $backupDir)) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($buildAlias -and [System.IO.Directory]::Exists($buildAlias)) {
            try { [System.IO.Directory]::Delete($buildAlias, $false) } catch { }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rock-js-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    try {
        switch ($Package) {
            'javascript' {
                if (-not $SkipJavaScript) { Build-RockJavaScript -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -LogDir $logDir }
            }
            'editorjs' {
                if (-not $SkipEditorJs) { Build-RockEditorJs -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
            }
            'styles' {
                if (-not $SkipStyles) { Build-RockStyles -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
            }
            'misc' {
                if (-not $SkipJavaScript) { Build-RockJavaScript -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -LogDir $logDir }
                if (-not $SkipEditorJs) { Build-RockEditorJs -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
                if (-not $SkipStyles) { Build-RockStyles -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
            }
            'obsidian' {
                if (-not $SkipObsidian) { Build-RockObsidian -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -LogDir $logDir }
            }
            'blocks' {
                if (-not $SkipBlocks) { Build-RockBlocks -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
            }
            'typecheck' {
                Invoke-ObsidianTypecheck -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -Concurrency $TypecheckConcurrency
            }
            'all' {
                if (-not $SkipJavaScript) { Build-RockJavaScript -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -LogDir $logDir }
                if (-not $SkipEditorJs) { Build-RockEditorJs -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
                if (-not $SkipStyles) { Build-RockStyles -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
                if (-not $SkipObsidian) { Build-RockObsidian -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall -LogDir $logDir }
                if (-not $SkipBlocks) { Build-RockBlocks -Root $resolvedRoot -CacheDir $NpmCacheDir -NoInstall:$SkipInstall }
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $logDir) {
            Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
