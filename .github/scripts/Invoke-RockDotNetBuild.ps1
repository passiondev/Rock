<#
.SYNOPSIS
    Cross-platform .NET Framework 4.7.2 build for RockWeb using the .NET SDK
    (Linux, macOS, and Windows) without modifying upstream .csproj files.

.DESCRIPTION
    Builds the exact required Rock project set (DotLiquid, Rock, and all Rock.*
    runtime projects -- excluding RockWeb, Rock.Client, Rock.CodeGeneration,
    Rock.RestClient, Rock.Common.Tv, Rock.Mandrill, and *Tests* whose outputs
    never enter RockWeb/Bin), single-targeted to net472 so multi-targeted core
    projects (Rock.Enums, Rock.Common, Rock.Lava.Shared, Rock.ViewModels) do not
    waste time compiling unused net9.0 outputs.

    On non-Windows hosts (ubuntu-latest CI and developer MacBooks), injects
    Microsoft.NETFramework.ReferenceAssemblies.net472 via temporary MSBuild
    props/targets CLI overrides and stubs Rock.csproj's Release-noop Windows
    cmd.exe PreBuild target. Also restores RockWeb/packages.config through a
    synthetic PackageReference project straight into ~/.nuget/packages so all
    *.dll.refresh pointers resolve without nuget.exe or a packages\ extraction.

    Reusable both in GitHub Actions (ubuntu-latest or windows-latest) and
    locally via Build-RockWebLocal.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory = $false)][string]$Configuration = 'Release',
    [Parameter(Mandatory = $false)][string]$NuGetPackagesDir = '',
    [Parameter(Mandatory = $false)][switch]$NoRestore,
    [Parameter(Mandatory = $false)][switch]$SkipCleanupTsConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NuGetNormalizedVersion {
    <#
        .SYNOPSIS
        Returns candidate folder names for a NuGet package version inside the
        global ~/.nuget/packages cache.

        .DESCRIPTION
        NuGet v3 normalizes package versions (e.g. "1.0" -> "1.0.0",
        "10.0.10586.0" -> "10.0.10586") while packages.config and *.dll.refresh
        preserve the raw version string. Trying the raw string plus normalized
        forms matches both conventions cleanly.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Version
    )

    $raw = $Version.Trim().ToLowerInvariant()
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($raw)

    $parts = $raw -split '-', 2
    $numeric = $parts[0]
    $suffix = if ($parts.Count -gt 1) { '-' + $parts[1] } else { '' }
    $segs = @($numeric -split '\.')

    if ($segs.Count -eq 2 -and @($segs | Where-Object { $_ -notmatch '^\d+$' }).Count -eq 0) {
        $norm = "$([int]$segs[0]).$([int]$segs[1]).0$suffix"
        if (-not $candidates.Contains($norm)) { $candidates.Add($norm) }
    }
    elseif ($segs.Count -eq 4 -and $segs[3] -eq '0' -and @($segs | Where-Object { $_ -notmatch '^\d+$' }).Count -eq 0) {
        $norm = "$([int]$segs[0]).$([int]$segs[1]).$([int]$segs[2])$suffix"
        if (-not $candidates.Contains($norm)) { $candidates.Add($norm) }
    }
    elseif ($segs.Count -eq 3 -and @($segs | Where-Object { $_ -notmatch '^\d+$' }).Count -eq 0) {
        $norm = "$([int]$segs[0]).$([int]$segs[1]).$([int]$segs[2])$suffix"
        if (-not $candidates.Contains($norm)) { $candidates.Add($norm) }
    }

    return $candidates.ToArray()
}

function Read-RefreshPointerText {
    <#
        .SYNOPSIS
        Decodes a RockWeb/Bin/*.dll.refresh file regardless of UTF-16 or UTF-8 BOM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $raw = [System.IO.File]::ReadAllBytes($Path)
    if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
    }
    elseif ($raw.Length -ge 2 -and $raw[0] -eq 0xFE -and $raw[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($raw, 2, $raw.Length - 2)
    }
    else {
        # Strip NULs (handles BOM-less UTF-16LE) and decode as UTF-8.
        $filtered = New-Object System.Collections.Generic.List[byte]
        foreach ($b in $raw) {
            if ($b -ne 0) { $filtered.Add($b) }
        }
        $text = [System.Text.Encoding]::UTF8.GetString($filtered.ToArray())
    }

    $trimChars = [char[]]@(0xFEFF, 0x20, 0x09, 0x0D, 0x0A)
    return $text.Trim($trimChars)
}

function Get-RockRequiredProjects {
    <#
        .SYNOPSIS
        Returns the relative paths (using backslash separators for .slnf) of all
        required runtime .csproj files that ship assemblies into RockWeb/Bin.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    # Same exclusion list as pr-test-artifact.yml plus *Tests* (which never copy
    # into RockWeb/Bin). Rock.Mandrill is excluded so passion-19.x builds cleanly
    # without editing upstream .csproj files.
    $excludePatterns = @(
        '*RockWeb*',
        '*Rock.Client*',
        '*Rock.CodeGeneration*',
        '*Rock.RestClient*',
        '*Rock.Common.Tv*',
        '*Rock.Mandrill*'
    )

    $projects = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $core = @(
        'DotLiquid/DotLiquid.csproj',
        'Rock.Enums/Rock.Enums.csproj',
        'Rock.Common/Rock.Common.csproj',
        'Rock.Version/Rock.Version.csproj',
        'Rock.ViewModels/Rock.ViewModels.csproj',
        'Rock/Rock.csproj'
    )
    foreach ($rel in $core) {
        $full = Join-Path $RootPath $rel
        if (Test-Path -LiteralPath $full) {
            $slnfPath = $rel.Replace('/', '\')
            if ($seen.Add($slnfPath)) { $projects.Add($slnfPath) }
        }
    }

    $rockDirs = @(Get-ChildItem -Path $RootPath -Directory -Filter 'Rock.*' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($dir in $rockDirs) {
        $csprojs = @(Get-ChildItem -Path $dir.FullName -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($proj in $csprojs) {
            if ($proj.Name -like '*Tests*') { continue }
            $excluded = $false
            foreach ($pattern in $excludePatterns) {
                if ($proj.FullName -like $pattern) { $excluded = $true; break }
            }
            if ($excluded) { continue }

            $rel = [System.IO.Path]::GetRelativePath($RootPath, $proj.FullName).Replace('/', '\')
            if ($seen.Add($rel)) { $projects.Add($rel) }
        }
    }

    return $projects.ToArray()
}

function New-RockRequiredFilter {
    <#
        .SYNOPSIS
        Writes a temporary .slnf solution filter listing only required projects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $projects = @(Get-RockRequiredProjects -RootPath $RootPath)
    if ($projects.Count -eq 0) {
        throw "Found zero required Rock .csproj files under $RootPath."
    }

    $slnf = [ordered]@{
        solution = [ordered]@{
            path = 'Rock.sln'
            projects = $projects
        }
    }
    $slnf | ConvertTo-Json -Depth 4 | Set-Content -Path $DestinationPath -Encoding utf8
    return $projects.Count
}

function New-RockWebPackagesProject {
    <#
        .SYNOPSIS
        Generates a synthetic SDK-style .csproj containing exact-version
        PackageReferences for every entry in RockWeb/packages.config so
        `dotnet restore` populates ~/.nuget/packages cross-platform without
        nuget.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackagesConfigPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $xml = [xml](Get-Content -Raw -Path $PackagesConfigPath)
    $nodes = @($xml.packages.package)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<Project Sdk="Microsoft.NET.Sdk">')
    $lines.Add('  <PropertyGroup>')
    $lines.Add('    <TargetFramework>net472</TargetFramework>')
    $lines.Add('    <NuGetAudit>false</NuGetAudit>')
    $lines.Add('    <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>')
    $lines.Add('  </PropertyGroup>')
    $lines.Add('  <ItemGroup>')
    foreach ($node in $nodes) {
        $id = [System.Security.SecurityElement]::Escape($node.id)
        $ver = [System.Security.SecurityElement]::Escape($node.version)
        $lines.Add("    <PackageReference Include=""$id"" Version=""[$ver]"" ExcludeAssets=""all"" GeneratePathProperty=""false"" />")
    }
    $lines.Add('  </ItemGroup>')
    $lines.Add('</Project>')
    Set-Content -Path $DestinationPath -Value $lines -Encoding utf8
    return $nodes.Count
}

function Resolve-CaseInsensitiveFile {
    <#
        .SYNOPSIS
        Finds a relative subpath inside a directory even on case-sensitive
        Linux filesystems.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$RelativeSubpath
    )

    $normalized = $RelativeSubpath.Replace('\', '/')
    $direct = Join-Path $BaseDir $normalized
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        return $direct
    }
    if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) {
        return $null
    }

    $segments = @($normalized -split '/' | Where-Object { $_ -ne '' })
    $current = $BaseDir
    foreach ($seg in $segments) {
        $entries = @(Get-ChildItem -LiteralPath $current -ErrorAction SilentlyContinue)
        $match = $entries | Where-Object { $_.Name.Equals($seg, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -eq $match) {
            return $null
        }
        $current = $match.FullName
    }

    if (Test-Path -LiteralPath $current -PathType Leaf) {
        return $current
    }
    return $null
}

function Resolve-RefreshAssemblies {
    <#
        .SYNOPSIS
        Resolves RockWeb/Bin/*.dll.refresh pointers into RockWeb/Bin from the
        global ~/.nuget/packages cache (and optional packages\ fallback).

        .DESCRIPTION
        Deliberately non-recursive and restricted to *.dll.refresh so
        RockWeb/Bin/roslyn/* (already committed) and upstream's malformed
        Microsoft.Extensions.Primitives.refresh are skipped. Existing DLLs
        emitted by project builds always win.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$NuGetCacheDir
    )

    $binDir = Join-Path $RootPath (Join-Path 'RockWeb' 'Bin')
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    # Build packages\<Id>.<Version> -> (id-lower, version) lookup from packages.config.
    $pkgMap = @{}
    $packagesConfigPath = Join-Path $RootPath (Join-Path 'RockWeb' 'packages.config')
    if (Test-Path -LiteralPath $packagesConfigPath) {
        $xml = [xml](Get-Content -Raw -Path $packagesConfigPath)
        foreach ($node in @($xml.packages.package)) {
            $key = "$($node.id).$($node.version)".ToLowerInvariant()
            $pkgMap[$key] = [pscustomobject]@{
                Id = $node.id.ToLowerInvariant()
                Version = $node.version
            }
        }
    }

    $copied = New-Object System.Collections.Generic.List[string]
    $unresolved = New-Object System.Collections.Generic.List[string]
    $alreadyBuilt = 0

    $refreshFiles = @(Get-ChildItem -LiteralPath $binDir -Filter '*.dll.refresh' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($refresh in $refreshFiles) {
        $targetName = $refresh.Name -replace '\.refresh$', ''
        $targetPath = Join-Path $refresh.DirectoryName $targetName
        if (Test-Path -LiteralPath $targetPath) {
            $alreadyBuilt++
            continue
        }

        $relative = Read-RefreshPointerText -Path $refresh.FullName
        if ([string]::IsNullOrWhiteSpace($relative)) {
            $unresolved.Add("$targetName (empty .refresh)")
            continue
        }

        $resolved = $null

        # 1. Resolve directly from global ~/.nuget/packages using packages.config mapping.
        if ($relative -match 'packages[\\/](?<pkg>[^\\/]+)[\\/](?<subpath>.+)$') {
            $pkgFolder = $Matches['pkg'].ToLowerInvariant()
            $subpath = $Matches['subpath']
            $id = $null
            $ver = $null

            if ($pkgMap.ContainsKey($pkgFolder)) {
                $id = $pkgMap[$pkgFolder].Id
                $ver = $pkgMap[$pkgFolder].Version
            }
            elseif ($pkgFolder -match '^(?<id>.+?)\.(?<ver>\d+\.\d.*)$') {
                $id = $Matches['id'].ToLowerInvariant()
                $ver = $Matches['ver']
            }

            if ($id -and $ver) {
                foreach ($normVer in (Get-NuGetNormalizedVersion -Version $ver)) {
                    $pkgDir = Join-Path (Join-Path $NuGetCacheDir $id) $normVer
                    $candidate = Resolve-CaseInsensitiveFile -BaseDir $pkgDir -RelativeSubpath $subpath
                    if ($null -ne $candidate) {
                        $resolved = $candidate
                        break
                    }
                }
            }
        }

        # 2. Fallback to traditional solution packages\ directory if present.
        if ($null -eq $resolved) {
            $normRel = $relative.Replace('\', '/')
            foreach ($base in @((Join-Path $RootPath 'RockWeb'), $RootPath, $binDir)) {
                $candidate = Join-Path $base $normRel
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $resolved = (Resolve-Path -LiteralPath $candidate).Path
                    break
                }
            }
        }

        if ($null -eq $resolved) {
            $unresolved.Add("$targetName -> $relative")
            continue
        }

        Copy-Item -LiteralPath $resolved -Destination $targetPath -Force
        $copied.Add($targetName)
    }

    return [pscustomobject]@{
        AlreadyBuilt = $alreadyBuilt
        Copied = $copied.ToArray()
        Unresolved = $unresolved.ToArray()
    }
}

function Invoke-RockDotNetBuildMain {
    param(
        [string]$RootPath,
        [string]$Config,
        [string]$CacheDir,
        [bool]$SkipRestore,
        [bool]$KeepTsConfig
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
    if ([string]::IsNullOrWhiteSpace($CacheDir)) {
        if ($env:NUGET_PACKAGES) {
            $CacheDir = $env:NUGET_PACKAGES
        }
        else {
            $CacheDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) (Join-Path '.nuget' 'packages')
        }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rock-dotnet-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # The .slnf must sit beside Rock.sln so its relative path "Rock.sln" resolves.
    $slnfPath = Join-Path $resolvedRoot '.rock-required.tmp.slnf'
    $beforeProps = Join-Path $tempRoot 'rock-cross-before.props'
    $afterTargets = Join-Path $tempRoot 'rock-cross-after.targets'
    $rwPackagesProj = Join-Path $tempRoot 'rockweb-packages.csproj'
    $pluginsDir = Join-Path $resolvedRoot (Join-Path 'RockWeb' 'Plugins')
    $movedPlugins = Join-Path $tempRoot 'Plugins'
    $pluginsWereMoved = $false

    try {
        $projectCount = New-RockRequiredFilter -RootPath $resolvedRoot -DestinationPath $slnfPath
        Write-Host "Generated .slnf for $projectCount required net472 projects (skipping *Tests* and excluded projects)"

        $beforeLines = @(
            '<Project>',
            '  <PropertyGroup>',
            '    <NuGetAudit>false</NuGetAudit>',
            '  </PropertyGroup>'
        )
        if (-not $IsWindows) {
            $beforeLines += @(
                '  <ItemGroup Condition="''$(TargetFramework)'' == ''net472'' or ''$(TargetFrameworks)'' != ''''">',
                '    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies.net472" Version="1.0.3" PrivateAssets="all" />',
                '  </ItemGroup>'
            )
        }
        $beforeLines += '</Project>'
        Set-Content -Path $beforeProps -Value $beforeLines -Encoding utf8

        $afterLines = @('<Project>')
        if (-not $IsWindows) {
            # Rock.csproj's PreBuild target runs a Windows cmd.exe script that is a
            # no-op in Release mode (only cleans long-deleted DLLs). Stub it on Unix.
            $afterLines += '  <Target Name="PreBuild" />'
        }
        $afterLines += '</Project>'
        Set-Content -Path $afterTargets -Value $afterLines -Encoding utf8

        # Move RockWeb/Plugins aside during core build, matching original build behavior.
        if (Test-Path -LiteralPath $pluginsDir) {
            Move-Item -LiteralPath $pluginsDir -Destination $movedPlugins
            $pluginsWereMoved = $true
        }

        $nugetConfig = Join-Path $resolvedRoot 'NuGet.config'
        $packagesConfig = Join-Path $resolvedRoot (Join-Path 'RockWeb' 'packages.config')

        if (-not $SkipRestore) {
            Write-Host '::group::dotnet restore (29 required projects, net472)'
            & dotnet restore $slnfPath `
                "-p:CustomBeforeMicrosoftCommonProps=$beforeProps" `
                '-p:TargetFrameworks=net472' `
                '-v:minimal'
            $code = $LASTEXITCODE
            Write-Host '::endgroup::'
            if ($code -ne 0) {
                Write-Host "::error::dotnet restore failed for $slnfPath (exit $code)."
                exit $code
            }

            if (Test-Path -LiteralPath $packagesConfig) {
                $pkgCount = New-RockWebPackagesProject -PackagesConfigPath $packagesConfig -DestinationPath $rwPackagesProj
                Write-Host "::group::dotnet restore RockWeb/packages.config ($pkgCount packages -> global cache)"
                $rwArgs = @('restore', $rwPackagesProj, '-v:minimal')
                if (Test-Path -LiteralPath $nugetConfig) {
                    $rwArgs += @('--configfile', $nugetConfig)
                }
                & dotnet @rwArgs
                $code = $LASTEXITCODE
                Write-Host '::endgroup::'
                if ($code -ne 0) {
                    Write-Host "::error::dotnet restore failed for RockWeb/packages.config (exit $code)."
                    exit $code
                }
            }
        }

        # Ensure empty ConnectionStrings config exists (same as original workflow).
        $connConfig = Join-Path $resolvedRoot (Join-Path 'RockWeb' (Join-Path 'path' 'app.ConnectionStrings.config'))
        $connDir = Split-Path -Path $connConfig -Parent
        if (-not (Test-Path -LiteralPath $connDir)) { New-Item -ItemType Directory -Path $connDir -Force | Out-Null }
        New-Item -Path $connConfig -ItemType File -Force | Out-Null

        Write-Host "::group::dotnet build ($projectCount required projects, $Config, net472)"
        & dotnet build $slnfPath --no-restore -c $Config `
            '-p:TargetFrameworks=net472' `
            "-p:CustomBeforeMicrosoftCommonProps=$beforeProps" `
            "-p:CustomAfterMicrosoftCommonTargets=$afterTargets" `
            '-v:minimal'
        $code = $LASTEXITCODE
        Write-Host '::endgroup::'
        if ($code -ne 0) {
            Write-Host "::error::dotnet build failed (exit $code). Required Rock assemblies failed to compile."
            exit $code
        }

        # Build any plugin projects (advisory, matching original policy).
        $advisoryFailures = @()
        if ($pluginsWereMoved) {
            $pluginProjects = @(Get-ChildItem -Path $movedPlugins -Filter '*.csproj' -Recurse -File -ErrorAction SilentlyContinue)
            if ($pluginProjects.Count -gt 0) {
                $tempRefDir = Join-Path $tempRoot 'RockRefs'
                New-Item -ItemType Directory -Path $tempRefDir -Force | Out-Null
                foreach ($refDll in @(
                    (Join-Path $resolvedRoot (Join-Path 'Rock' (Join-Path 'bin' (Join-Path $Config (Join-Path 'net472' 'Rock.dll'))))),
                    (Join-Path $resolvedRoot (Join-Path 'DotLiquid' (Join-Path 'bin' (Join-Path $Config (Join-Path 'net472' 'DotLiquid.dll')))))
                )) {
                    if (Test-Path -LiteralPath $refDll) { Copy-Item -LiteralPath $refDll -Destination $tempRefDir -Force }
                }

                foreach ($plugin in $pluginProjects) {
                    Write-Host "::group::Building plugin $($plugin.Name) (advisory)"
                    & dotnet build $plugin.FullName -c $Config "-p:SolutionDir=$resolvedRoot$([System.IO.Path]::DirectorySeparatorChar)" `
                        "-p:CustomBeforeMicrosoftCommonProps=$beforeProps" '-v:minimal'
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "::warning::$($plugin.Name) failed to build (exit $LASTEXITCODE); continuing."
                        $advisoryFailures += $plugin.Name
                    }
                    Write-Host '::endgroup::'
                }
            }
        }

        # Resolve RockWeb/Bin/*.dll.refresh pointers directly from ~/.nuget/packages.
        $refreshResult = Resolve-RefreshAssemblies -RootPath $resolvedRoot -NuGetCacheDir $CacheDir
        Write-Host "Already emitted by a project build: $($refreshResult.AlreadyBuilt)"
        Write-Host "Copied from NuGet cache:           $($refreshResult.Copied.Count)"
        if ($refreshResult.Unresolved.Count -gt 0) {
            Write-Host "::warning::$($refreshResult.Unresolved.Count) .refresh pointer(s) did not resolve; those assemblies are absent from the artifact."
            foreach ($u in $refreshResult.Unresolved) { Write-Host "::warning::unresolved: $u" }
        }

        if ($env:GITHUB_ENV) {
            "RESOLVED_REFRESH_COUNT=$($refreshResult.Copied.Count)" | Out-File -FilePath $env:GITHUB_ENV -Append
            "UNRESOLVED_REFRESH_COUNT=$($refreshResult.Unresolved.Count)" | Out-File -FilePath $env:GITHUB_ENV -Append
        }

        if (-not $KeepTsConfig) {
            $tsConfig = Join-Path $resolvedRoot (Join-Path 'RockWeb' 'tsconfig.json')
            if (Test-Path -LiteralPath $tsConfig) { Remove-Item -LiteralPath $tsConfig -Force }
        }

        if ($env:GITHUB_STEP_SUMMARY) {
            if ($advisoryFailures.Count -gt 0) {
                $lines = @('### Advisory build failures', '', 'These did not fail the build, but their assemblies are missing from the artifact:', '')
                $lines += $advisoryFailures | ForEach-Object { "- ``$_``" }
                $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            }
            else {
                "### Build clean`n`nAll $projectCount required Rock .NET projects compiled for ``net472``." | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
            }
        }

        $binDir = Join-Path $resolvedRoot (Join-Path 'RockWeb' 'Bin')
        $dllCount = @(Get-ChildItem -LiteralPath $binDir -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count
        Write-Host "Total DLLs in RockWeb/Bin: $dllCount"
    }
    finally {
        if ($pluginsWereMoved -and (Test-Path -LiteralPath $movedPlugins)) {
            Move-Item -LiteralPath $movedPlugins -Destination $pluginsDir
        }
        if (Test-Path -LiteralPath $slnfPath) {
            Remove-Item -LiteralPath $slnfPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Run only when executed directly (not dot-sourced for Pester tests).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RockDotNetBuildMain -RootPath $RepoRoot -Config $Configuration -CacheDir $NuGetPackagesDir `
        -SkipRestore:$NoRestore -KeepTsConfig:$SkipCleanupTsConfig
}
