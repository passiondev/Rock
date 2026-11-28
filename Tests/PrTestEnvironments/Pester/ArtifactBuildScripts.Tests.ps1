<#
    Unit tests for the cross-platform build, verification, and partial-layer
    GCS reuse scripts under .github/scripts/:
      - Invoke-RockDotNetBuild.ps1
      - Test-RockWebArtifact.ps1
      - Restore-ReusableArtifactLayer.ps1
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactRecord.psm1') -Force

    . (Import-ScriptFunction -Path (Get-RepositoryPath '.github/scripts/Invoke-RockDotNetBuild.ps1') -Name @(
        'Get-NuGetNormalizedVersion',
        'Read-RefreshPointerText',
        'Get-RockRequiredProjects',
        'Resolve-CaseInsensitiveFile',
        'Resolve-RefreshAssemblies'
    ))
    . (Import-ScriptFunction -Path (Get-RepositoryPath '.github/scripts/Test-RockWebArtifact.ps1') -Name @(
        'Test-RockWebBuild'
    ))
    . (Import-ScriptFunction -Path (Get-RepositoryPath '.github/scripts/Restore-ReusableArtifactLayer.ps1') -Name @(
        'Test-EntryBelongsToLayer',
        'Expand-ArtifactLayerFromZip',
        'Invoke-RestoreReusableLayer'
    ))
}

Describe '.github/scripts/Invoke-RockDotNetBuild.ps1 helpers' {
    It 'normalizes NuGet v3 semver folders for 2-part and 4-part trailing-zero versions' {
        @(Get-NuGetNormalizedVersion -Version '1.0') | Should -Contain '1.0.0'
        @(Get-NuGetNormalizedVersion -Version '10.0.10586.0') | Should -Contain '10.0.10586'
        @(Get-NuGetNormalizedVersion -Version '3.31.1') | Should -Contain '3.31.1'
    }

    It 'decodes UTF-16LE BOM, UTF-8 BOM, and BOM-less UTF-16LE refresh pointers' {
        $dir = Join-Path $TestDrive 'refresh-enc'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $utf16Path = Join-Path $dir 'u16.dll.refresh'
        [System.IO.File]::WriteAllText($utf16Path, "..\packages\Google.Protobuf.3.31.1\lib\net45\Google.Protobuf.dll`r`n", [System.Text.Encoding]::Unicode)
        Read-RefreshPointerText -Path $utf16Path | Should -Be '..\packages\Google.Protobuf.3.31.1\lib\net45\Google.Protobuf.dll'

        $utf8Path = Join-Path $dir 'u8.dll.refresh'
        [System.IO.File]::WriteAllText($utf8Path, "..\packages\Owin.1.0\lib\net40\Owin.dll`n", [System.Text.UTF8Encoding]::new($true))
        Read-RefreshPointerText -Path $utf8Path | Should -Be '..\packages\Owin.1.0\lib\net40\Owin.dll'
    }

    It 'selects required runtime Rock projects and excludes Tests and Rock.Mandrill' {
        $repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Get-RepositoryPath '.github/scripts/Invoke-RockDotNetBuild.ps1')))
        $projects = @(Get-RockRequiredProjects -RootPath $repo)

        $projects | Should -Contain 'DotLiquid\DotLiquid.csproj'
        $projects | Should -Contain 'Rock\Rock.csproj'
        $projects | Should -Contain 'Rock.Blocks\Rock.Blocks.csproj'
        @($projects | Where-Object { $_ -like '*Tests*' }) | Should -BeNullOrEmpty
        @($projects | Where-Object { $_ -like '*Rock.Mandrill*' }) | Should -BeNullOrEmpty
    }

    It 'resolves .dll.refresh pointers from ~/.nuget/packages using semver normalization' {
        $root = Join-Path $TestDrive 'resolve-root'
        $bin = Join-Path $root (Join-Path 'RockWeb' 'Bin')
        $cache = Join-Path $TestDrive 'nuget-cache'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null

        # Fake packages.config + UTF-16LE refresh pointer for Owin 1.0 -> cache folder 1.0.0.
        Set-Content -Path (Join-Path $root (Join-Path 'RockWeb' 'packages.config')) -Value @'
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="Owin" version="1.0" targetFramework="net472" />
</packages>
'@
        [System.IO.File]::WriteAllText(
            (Join-Path $bin 'Owin.dll.refresh'),
            "..\packages\Owin.1.0\lib\net40\Owin.dll`r`n",
            [System.Text.Encoding]::Unicode
        )

        $pkgDll = Join-Path $cache (Join-Path 'owin' (Join-Path '1.0.0' (Join-Path 'lib' (Join-Path 'net40' 'Owin.dll'))))
        New-Item -ItemType Directory -Path (Split-Path $pkgDll -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($pkgDll, [byte[]](0x4D, 0x5A, 0x01, 0x02))

        $res = Resolve-RefreshAssemblies -RootPath $root -NuGetCacheDir $cache
        $res.Unresolved | Should -BeNullOrEmpty
        $res.Copied | Should -Be @('Owin.dll')
        Test-Path -LiteralPath (Join-Path $bin 'Owin.dll') | Should -BeTrue
    }
}

Describe '.github/scripts/Test-RockWebArtifact.ps1' {
    BeforeEach {
        $script:Site = Join-Path $TestDrive 'verify-site'
        if (Test-Path $script:Site) { Remove-Item $script:Site -Recurse -Force }
        $bin = Join-Path $script:Site 'Bin'
        $blocks = Join-Path $script:Site (Join-Path 'Obsidian' 'Blocks')
        $icons = Join-Path $script:Site (Join-Path 'Styles' (Join-Path 'styles-v2' 'icons'))
        New-Item -ItemType Directory -Path $bin, $blocks, $icons -Force | Out-Null

        foreach ($dll in @(
            'Rock.dll', 'Rock.Common.dll', 'Rock.Enums.dll', 'Rock.ViewModels.dll',
            'Rock.Blocks.dll', 'Rock.Rest.dll', 'Rock.Migrations.dll',
            'Rock.WebStartup.dll', 'DotLiquid.dll', 'Google.Protobuf.dll'
        )) {
            Set-Content -Path (Join-Path $bin $dll) -Value 'dll'
        }
        Set-Content -Path (Join-Path $script:Site (Join-Path 'Obsidian' 'obsidian-core.js')) -Value 'core'
        Set-Content -Path (Join-Path $blocks 'sample.obs.js') -Value 'block'
        [System.IO.File]::WriteAllBytes((Join-Path $icons 'tabler-icon.css'), (New-Object byte[] 60000))
        [System.IO.File]::WriteAllBytes((Join-Path $script:Site (Join-Path 'Styles' (Join-Path 'styles-v2' 'core.css'))), (New-Object byte[] 120000))
    }

    It 'passes a complete RockWeb tree' {
        $res = Test-RockWebBuild -RootPath $script:Site
        $res.Success | Should -BeTrue
        $res.Failures | Should -BeNullOrEmpty
    }

    It 'fails when Google.Protobuf.dll is missing' {
        Remove-Item (Join-Path $script:Site (Join-Path 'Bin' 'Google.Protobuf.dll'))
        $res = Test-RockWebBuild -RootPath $script:Site
        $res.Success | Should -BeFalse
        ($res.Failures -join '; ') | Should -BeLike '*Google.Protobuf.dll*'
    }

    It 'fails when tabler-icon.css or core.css is a tiny stub' {
        [System.IO.File]::WriteAllBytes((Join-Path $script:Site (Join-Path 'Styles' (Join-Path 'styles-v2' 'core.css'))), (New-Object byte[] 200))
        $res = Test-RockWebBuild -RootPath $script:Site
        $res.Success | Should -BeFalse
        ($res.Failures -join '; ') | Should -BeLike '*core.css*'
    }
}

Describe '.github/scripts/Restore-ReusableArtifactLayer.ps1' {
    It 'extracts only requested layers and canonicalizes bin/ -> Bin/' {
        $zipPath = Join-Path $TestDrive 'layer-base.zip'
        $dest = Join-Path $TestDrive 'layer-dest'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entryName in @('bin/Rock.dll', 'Obsidian/obsidian-core.js', 'Obsidian/Blocks/Cms/x.obs.js', 'Styles/styles-v2/core.css', 'web.config')) {
                $w = New-Object System.IO.StreamWriter($archive.CreateEntry($entryName).Open())
                $w.Write("content:$entryName")
                $w.Dispose()
            }
        }
        finally {
            $archive.Dispose()
            $stream.Dispose()
        }

        $count = Expand-ArtifactLayerFromZip -ZipPath $zipPath -DestinationRoot $dest -Layers @('dotnet', 'js-obsidian') -Themes @('RockNextGen')
        $count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $dest (Join-Path 'Bin' 'Rock.dll')) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest (Join-Path 'Obsidian' 'obsidian-core.js')) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest (Join-Path 'Obsidian' (Join-Path 'Blocks' (Join-Path 'Cms' 'x.obs.js')))) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dest 'web.config') | Should -BeFalse
    }
}
