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

    These run the real functions against small zips built in $TestDrive.

    Invoke-ArtifactRepackage is the whole script, handed an artifact store and
    git rather than calling gsutil and git itself. Its cases hand it a store held
    in memory, filled the way the packaging jobs fill the bucket: a zip, and its
    pr-test-artifact.json beside it. That is what lets a chain of repackages, a
    base whose hash is wrong and a base with no record each run end to end.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:RepackageScript = Get-RepositoryPath '.github/scripts/New-RepackagedArtifact.ps1'
    $script:RulePath = Get-RepositoryPath '.github/scripts/artifact-paths.json'

    # The classifier and the artifact address are modules the script imports.
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactPaths.psm1') -Force
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactRecord.psm1') -Force
    . (Import-ScriptFunction -Path $script:RepackageScript -Name @(
        'New-PatchedArtifactArchive',
        'Invoke-ArtifactRepackage'))

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

Describe 'Invoke-ArtifactRepackage' {
    BeforeAll {
        # The bucket the stored artifacts' records name.
        $script:Bucket = 'rock-pr-env'

        # What every stored base holds: a RockWeb build, and the Lava template
        # each case's change patches.
        $script:BaseEntries = [ordered]@{} + $script:Skeleton
        $script:BaseEntries['Themes/Rock/Assets/Lava/PageNav.lava'] = 'old'

        # An artifact store held in memory, over a table of object path to
        # bytes. It has only Download, because that is all a repackage asks of
        # a store, and like gsutil it fails for an object that is not there.
        function New-MemoryArtifactStore {
            param([Parameter(Mandatory = $true)][hashtable]$Object)
            return @{
                Download = {
                    param(
                        [Parameter(Mandatory = $true)][string]$ObjectPath,
                        [Parameter(Mandatory = $true)][string]$Destination
                    )
                    if (-not $Object.ContainsKey($ObjectPath)) {
                        throw "No object at $ObjectPath"
                    }
                    [System.IO.File]::WriteAllBytes($Destination, $Object[$ObjectPath])
                }.GetNewClosure()
            }
        }

        # A staging artifact as the package job leaves it in the bucket: the
        # zip, and beside it a record naming the zip's hash. -RecordedSha256
        # makes the record name another hash; -WithoutRecord leaves the record
        # out.
        function Add-StoredArtifact {
            param(
                [Parameter(Mandatory = $true)][string]$Sha,
                [Parameter(Mandatory = $false)][string]$RecordedSha256 = '',
                [switch]$WithoutRecord
            )
            $address = Get-ArtifactAddress -Slug 'staging' -Sha $Sha
            $zip = Join-Path $TestDrive "stored-$($address.ShortSha).zip"
            New-TestZip -Path $zip -Entry $script:BaseEntries
            $script:Objects[$address.ObjectPath] = [System.IO.File]::ReadAllBytes($zip)
            if ($WithoutRecord) {
                return
            }

            $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
            if ($RecordedSha256) {
                $hash = $RecordedSha256
            }
            $recordPath = Join-Path $TestDrive "stored-$($address.ShortSha).json"
            $record = New-ArtifactRecord -Address $address -Bucket $script:Bucket -PrNumber '' -HostName 'staging.example.org' -Sha256 $hash
            Write-ArtifactRecord -Record $record -Path $recordPath
            $script:Objects[$address.RecordPath] = [System.IO.File]::ReadAllBytes($recordPath)
        }

        # What the repackage job's upload does with a run's zip and record:
        # puts them at the target's address, where a later run finds them.
        function Publish-CheckoutArtifact {
            param([Parameter(Mandatory = $true)][string]$Sha)
            $address = Get-ArtifactAddress -Slug 'staging' -Sha $Sha
            $script:Objects[$address.ObjectPath] = [System.IO.File]::ReadAllBytes((Join-Path $script:Checkout $address.Name))
            $script:Objects[$address.RecordPath] = [System.IO.File]::ReadAllBytes((Join-Path $script:Checkout $address.RecordName))
        }

        # A staging repackage of TargetSha from BaseSha's artifact, against the
        # shipped rules. Git reports Diff between the two, and refuses to diff
        # anything but the base: the patch has to be taken from the commit the
        # base zip's files are from.
        function Invoke-Repackage {
            param(
                [Parameter(Mandatory = $true)][string]$BaseSha,
                [Parameter(Mandatory = $true)][string]$TargetSha,
                [Parameter(Mandatory = $false)][string]$BaseObjectPath = '',
                [Parameter(Mandatory = $false)][string[]]$Diff = @("M`tRockWeb/Themes/Rock/Assets/Lava/PageNav.lava")
            )
            if (-not $BaseObjectPath) {
                $BaseObjectPath = (Get-ArtifactAddress -Slug 'staging' -Sha $BaseSha).ObjectPath
            }
            $getChange = {
                param($Sha)
                if ($Sha -ne $BaseSha) {
                    throw "diffed $Sha, which is not the base"
                }
                return $Diff
            }.GetNewClosure()

            Invoke-ArtifactRepackage -BaseSha $BaseSha -BaseObjectPath $BaseObjectPath -TargetSha $TargetSha `
                -Bucket $script:Bucket -ArtifactSlug 'staging' -PrNumber '' -HostName 'staging.example.org' `
                -Store $script:Store -GetChange $getChange `
                -GetGeneratedThemeName { 'RockNextGen', 'RockManagerNextGen', 'NextGenCheckin' } `
                -RuleSetPath $script:RulePath `
                -CheckoutPath $script:Checkout -WorkPath $script:Work `
                -OutputPath $script:OutputFile -SummaryPath $script:SummaryFile
        }
    }

    BeforeEach {
        $script:Checkout = Join-Path $TestDrive 'repackage-checkout'
        $script:Work = Join-Path $TestDrive 'repackage-work'
        foreach ($directory in @($script:Checkout, $script:Work)) {
            if (Test-Path $directory) {
                Remove-Item $directory -Recurse -Force
            }
        }
        New-Item -ItemType Directory -Path $script:Checkout | Out-Null
        Set-CheckoutFile -Path 'RockWeb/Themes/Rock/Assets/Lava/PageNav.lava' -Content 'new'

        # GITHUB_OUTPUT and GITHUB_STEP_SUMMARY, absent until something writes them.
        $script:OutputFile = Join-Path $TestDrive 'github-output'
        $script:SummaryFile = Join-Path $TestDrive 'step-summary'
        Remove-Item -Path $script:OutputFile, $script:SummaryFile -ErrorAction SilentlyContinue

        $script:Objects = @{}
        $script:Store = New-MemoryArtifactStore -Object $script:Objects
    }

    It 'writes the zip, its record, the outputs and the summary where it is told' {
        # The control for the cases below: a built base, with its record.
        Add-StoredArtifact -Sha '1111111111111111111111111111111111111111'

        Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222'

        $zip = Read-TestZip (Join-Path $script:Checkout 'RockWeb-staging-2222222.zip')
        $zip['Themes/Rock/Assets/Lava/PageNav.lava'] | Should -Be 'new'
        $zip['Bin/Rock.dll'] | Should -Be 'compiled'
        (Read-ArtifactRecord -Path (Join-Path $script:Checkout 'pr-test-artifact.json')).builtFromSha |
            Should -Be '1111111111111111111111111111111111111111'
        Get-Content -Path $script:OutputFile |
            Should -Contain 'artifact_gcs_object_path=pr-environments/staging/2222222222222222222222222222222222222222/RockWeb-staging-2222222.zip'
        @(Get-Content -Path $script:SummaryFile) | Should -Be @(
            '### Repackaged artifact'
            ''
            '`RockWeb-staging-2222222.zip` is `pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-staging-1111111.zip` with 1 file(s) swapped in. Its compiled output was built from `1111111111111111111111111111111111111111`.'
        )
    }

    It 'keeps naming the build a chain of repackages started from' {
        # 1 was built. 2 was repackaged from 1, and 3 is repackaged from 2. The
        # zip 3 starts from holds 1's compiled output, so 3's record has to
        # name 1, or a repackage from 3 would credit 2 with assemblies no
        # build of 2 ever made.
        Add-StoredArtifact -Sha '1111111111111111111111111111111111111111'
        Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222'
        Publish-CheckoutArtifact -Sha '2222222222222222222222222222222222222222'

        Invoke-Repackage -BaseSha '2222222222222222222222222222222222222222' -TargetSha '3333333333333333333333333333333333333333'

        $record = Read-ArtifactRecord -Path (Join-Path $script:Checkout 'pr-test-artifact.json')
        $record.sha | Should -Be '3333333333333333333333333333333333333333'
        $record.builtFromSha | Should -Be '1111111111111111111111111111111111111111'
        $record.baseArtifactGcsPath | Should -Be 'gs://rock-pr-env/pr-environments/staging/2222222222222222222222222222222222222222/RockWeb-staging-2222222.zip'
    }

    It 'refuses a base whose hash is not the one its record names, and leaves nothing to upload' {
        # A zip cut short on upload still opens, minus whatever was cut.
        Add-StoredArtifact -Sha '1111111111111111111111111111111111111111' -RecordedSha256 '0000000000000000000000000000000000000000000000000000000000000000'

        { Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222' } |
            Should -Throw '*SHA-256*metadata says 0000000000000000000000000000000000000000000000000000000000000000*force_build*'

        Join-Path $script:Checkout 'RockWeb-staging-2222222.zip' | Should -Not -Exist
        Join-Path $script:Checkout 'pr-test-artifact.json' | Should -Not -Exist
        $script:OutputFile | Should -Not -Exist
    }

    It 'records the base''s own commit as the build when no record sits beside it' {
        # The build has always written one, so this is an upload cut short
        # after the zip, or a zip copied in by hand. The folder's commit is
        # then the best answer there is, and not knowing more is no reason to
        # fail the run.
        Add-StoredArtifact -Sha '1111111111111111111111111111111111111111' -WithoutRecord

        Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222'

        (Read-ArtifactRecord -Path (Join-Path $script:Checkout 'pr-test-artifact.json')).builtFromSha |
            Should -Be '1111111111111111111111111111111111111111'
    }

    It 'fails the run when the base cannot be downloaded, and says how to build instead' {
        # The plan listed it minutes ago, but a lifecycle rule or a clean-up
        # can take it first. The repackage job has no build to fall back on,
        # so the message has to say what to do.
        { Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222' } |
            Should -Throw '*Could not download the base artifact gs://rock-pr-env/pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-staging-1111111.zip*force_build*'
    }

    It 'refuses a base no packaging job would have written, before downloading it' {
        # The store holds it, so a download would succeed: the address is the
        # only thing that can refuse it.
        $renamed = 'pr-environments/staging/1111111111111111111111111111111111111111/RockWeb-renamed.zip'
        $zip = Join-Path $TestDrive 'renamed.zip'
        New-TestZip -Path $zip -Entry $script:BaseEntries
        $script:Objects[$renamed] = [System.IO.File]::ReadAllBytes($zip)

        { Invoke-Repackage -BaseSha '1111111111111111111111111111111111111111' -TargetSha '2222222222222222222222222222222222222222' -BaseObjectPath $renamed } |
            Should -Throw '*RockWeb-renamed.zip is not where a packaging job puts an artifact*'

        # The download directory is made just before the download.
        $script:Work | Should -Not -Exist
    }
}
