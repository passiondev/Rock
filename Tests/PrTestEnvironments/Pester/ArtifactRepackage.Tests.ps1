<#
    .github/scripts/New-RepackagedArtifact.ps1 builds a deployable RockWeb zip without
    a build: it copies an earlier artifact entry by entry and swaps in the files that
    changed since.

    That only works if the result is the zip a full build would have made. The
    compiled output has to come across untouched, every changed file has to land
    where Compress-Archive would have put it, and a deleted file has to go. The new
    archive is written entry by entry from the base, never expanded to disk and
    re-compressed: Linux treats a dotfile as hidden and its filesystem cares about
    case, and either would make the re-compressed tree quietly differ from the
    Windows one.

    These run the real function against small zips built in $TestDrive.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:RepackageScript = Get-RepositoryPath '.github/scripts/New-RepackagedArtifact.ps1'
    . (Import-ScriptFunction -Path $script:RepackageScript -Name 'New-PatchedArtifactArchive')

    # The two entries every real artifact has. New-PatchedArtifactArchive refuses a
    # base without them, so every fixture starts from these.
    $script:Skeleton = [ordered]@{
        'Bin/Rock.dll' = 'compiled'
        'web.config' = '<configuration />'
    }

    function New-TestZip {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entry
        )
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entry.Keys) {
                $writer = New-Object System.IO.StreamWriter($archive.CreateEntry($name).Open())
                $writer.Write($Entry[$name])
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
            $stream.Dispose()
        }
    }

    # Entry name -> content, read back the way Expand-Archive would see it.
    function Read-TestZip {
        param([Parameter(Mandatory = $true)][string]$Path)
        $content = [ordered]@{}
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $archive.Entries) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                $content[$entry.FullName] = $reader.ReadToEnd()
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
        return $content
    }

    # A checkout holding one file at a repository-relative path.
    function Set-CheckoutFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Content
        )
        $full = Join-Path $script:Checkout $Path
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
        Set-Content -Path $full -Value $Content -NoNewline
    }

    function New-Change {
        param(
            [Parameter(Mandatory = $true)][string]$Status,
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $false)][string]$Class = 'patch'
        )
        return [pscustomobject]@{ Status = $Status; Path = $Path; Class = $Class; IsServerOwned = $false }
    }
}

Describe 'New-PatchedArtifactArchive' {
    BeforeEach {
        $script:Checkout = Join-Path $TestDrive 'checkout'
        if (Test-Path $script:Checkout) { Remove-Item $script:Checkout -Recurse -Force }
        New-Item -ItemType Directory -Path $script:Checkout | Out-Null

        $script:Base = Join-Path $TestDrive 'base.zip'
        $script:Output = Join-Path $TestDrive 'output.zip'
        Remove-Item $script:Output -ErrorAction SilentlyContinue
    }

    It 'replaces a modified file with the checkout''s copy' {
        $entries = [ordered]@{} + $script:Skeleton
        $entries['Themes/Rock/Assets/Lava/PageNav.lava'] = 'old'
        New-TestZip -Path $script:Base -Entry $entries
        Set-CheckoutFile -Path 'RockWeb/Themes/Rock/Assets/Lava/PageNav.lava' -Content 'new'

        New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @(
            New-Change -Status 'M' -Path 'RockWeb/Themes/Rock/Assets/Lava/PageNav.lava')

        (Read-TestZip $script:Output)['Themes/Rock/Assets/Lava/PageNav.lava'] | Should -Be 'new'
    }

    It 'drops a deleted file and adds a new one' {
        $entries = [ordered]@{} + $script:Skeleton
        $entries['Assets/Lava/Retired.lava'] = 'gone'
        New-TestZip -Path $script:Base -Entry $entries
        Set-CheckoutFile -Path 'RockWeb/Assets/Lava/Fresh.lava' -Content 'hello'

        New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @(
            New-Change -Status 'D' -Path 'RockWeb/Assets/Lava/Retired.lava'
            New-Change -Status 'A' -Path 'RockWeb/Assets/Lava/Fresh.lava')

        $result = Read-TestZip $script:Output
        $result.Keys | Should -Not -Contain 'Assets/Lava/Retired.lava'
        $result['Assets/Lava/Fresh.lava'] | Should -Be 'hello'
    }

    It 'matches an entry whatever its case or separator, and keeps the base''s separator' {
        # Which separator Compress-Archive writes on Windows has changed between
        # versions of the module. The VM expands with Expand-Archive, which takes
        # either -- but one archive holding Themes\Rock\x and Themes/Rock/x is two
        # entries for one file, and which of them lands last is up to the extractor.
        New-TestZip -Path $script:Base -Entry ([ordered]@{
            'Bin\Rock.dll' = 'compiled'
            'web.config' = '<configuration />'
            'Themes\Rock\Assets\Lava\PageNav.lava' = 'old'
        })
        Set-CheckoutFile -Path 'RockWeb/Themes/rock/Assets/Lava/PageNav.lava' -Content 'new'
        Set-CheckoutFile -Path 'RockWeb/Themes/Rock/Assets/Lava/Footer.lava' -Content 'added'

        New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @(
            New-Change -Status 'M' -Path 'RockWeb/Themes/rock/Assets/Lava/PageNav.lava'
            New-Change -Status 'A' -Path 'RockWeb/Themes/Rock/Assets/Lava/Footer.lava')

        # -ccontains: PowerShell's -Contain ignores case, which is the very thing
        # this is checking.
        $result = Read-TestZip $script:Output
        $names = @($result.Keys)
        $names | Should -HaveCount 4
        $names -ccontains 'Themes\rock\Assets\Lava\PageNav.lava' | Should -BeTrue
        $names -ccontains 'Themes\Rock\Assets\Lava\Footer.lava' | Should -BeTrue
        $result['Themes\rock\Assets\Lava\PageNav.lava'] | Should -Be 'new'
    }

    It 'carries compiled output across byte for byte' {
        # The assemblies are the whole point of reusing a base. Anything that read
        # them as text on the way through -- a newline fix, an encoding guess --
        # would ship a corrupt Rock.dll that only fails when IIS loads it.
        $assembly = [byte[]](0x4D, 0x5A, 0x90, 0x00, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE, 0x00, 0x0A)
        $stream = [System.IO.File]::Open($script:Base, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        $writer = $archive.CreateEntry('Bin/Rock.dll').Open()
        $writer.Write($assembly, 0, $assembly.Length)
        $writer.Dispose()
        $text = New-Object System.IO.StreamWriter($archive.CreateEntry('web.config').Open())
        $text.Write('<configuration />')
        $text.Dispose()
        $archive.Dispose()
        $stream.Dispose()

        New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @()

        $result = [System.IO.Compression.ZipFile]::OpenRead($script:Output)
        try {
            $copy = New-Object System.IO.MemoryStream
            $reader = $result.GetEntry('Bin/Rock.dll').Open()
            $reader.CopyTo($copy)
            $reader.Dispose()
            ,$copy.ToArray() | Should -Be (,$assembly)
        }
        finally {
            $result.Dispose()
        }
    }

    It 'leaves out a change that never reaches the artifact' {
        # A README or a test beside the site changes nothing a build would ship.
        New-TestZip -Path $script:Base -Entry $script:Skeleton
        Set-CheckoutFile -Path 'Documentation/Notes.md' -Content 'notes'

        New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @(
            New-Change -Status 'A' -Path 'Documentation/Notes.md' -Class 'ignore')

        @((Read-TestZip $script:Output).Keys) | Should -Be @('Bin/Rock.dll', 'web.config')
    }

    It 'refuses a change that needs compiling, and writes nothing' {
        # The plan job already decided, but on another runner and minutes ago.
        # This is the last point that can stop source being shipped where a
        # compiled assembly belongs.
        New-TestZip -Path $script:Base -Entry $script:Skeleton
        Set-CheckoutFile -Path 'RockWeb/Bin/Rock.dll.refresh' -Content '..\packages\x.dll'

        { New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @(
            New-Change -Status 'M' -Path 'RockWeb/Bin/Rock.dll.refresh' -Class 'build') } |
            Should -Throw '*RockWeb/Bin/Rock.dll.refresh*'

        $script:Output | Should -Not -Exist
    }

    It 'refuses a base that is not a RockWeb artifact' {
        # A repackage inherits every assembly from its base and checks none of
        # them, so a base without the core assembly would ship a site that cannot
        # start. The full build's verification step would never have let that zip
        # be uploaded; this is the cheap stand-in for it.
        New-TestZip -Path $script:Base -Entry ([ordered]@{ 'web.config' = '<configuration />' })

        { New-PatchedArtifactArchive -BasePath $script:Base -DestinationPath $script:Output -SourceRoot $script:Checkout -Change @() } |
            Should -Throw '*Bin/Rock.dll*'
    }
}
