<#
    .github/scripts/ArtifactRecord.psm1 says where a RockWeb artifact lives in the
    bucket and what the pr-test-artifact.json beside it records. The package job
    writes through it (New-PackagedArtifact.ps1), the repackage job writes through
    it, and the plan reads the bucket back through it.

    Those three used to spell the address out for themselves, and the only thing
    holding them together was a Python test comparing two regexes. What matters
    is not that the spellings match but that the round trips close: an address
    composed and then parsed comes back as itself, a record written and then read
    comes back as itself, and a zip the package step writes is one the plan can
    find. So that is what these check, against literal paths and literal field
    lists, because an artifact already in the bucket was written with exactly
    those and a later run has to keep finding it.

    The package script runs for real here, in $TestDrive, against a two-file
    RockWeb.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force
    Import-Module (Get-RepositoryPath '.github/scripts/ArtifactRecord.psm1') -Force

    $script:PackageScript = Get-RepositoryPath '.github/scripts/New-PackagedArtifact.ps1'

    # The record's fields in the order every writer has put them: the seven the
    # package job has always written, then the two only a repackage adds.
    $script:BuildFields = 'prNumber,sha,shortSha,artifactName,artifactGcsPath,hostName,sha256'
    $script:RepackageFields = "$script:BuildFields,builtFromSha,baseArtifactGcsPath"

    # The field names of a record file, in file order, as one string so the
    # comparison is case-sensitive and order-sensitive at once.
    function Get-RecordFieldOrder {
        param([Parameter(Mandatory = $true)][string]$Path)
        return ((Get-Content -Raw -Path $Path | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name }) -join ','
    }
}

Describe 'Get-ArtifactAddress' {
    It 'names the zip for the slug and short commit, in a folder for the full commit' {
        # Every artifact in the bucket was written at this shape. A change to it
        # strands all of them: the plan stops finding any base, and every run
        # builds until the bucket has refilled.
        $sha = 'a' * 40

        $address = Get-ArtifactAddress -Slug 'staging' -Sha $sha

        $address.Slug | Should -BeExactly 'staging'
        $address.Sha | Should -BeExactly $sha
        $address.ShortSha | Should -BeExactly 'aaaaaaa'
        $address.Name | Should -BeExactly 'RockWeb-staging-aaaaaaa.zip'
        $address.Folder | Should -BeExactly "pr-environments/staging/$sha"
        $address.ObjectPath | Should -BeExactly "pr-environments/staging/$sha/RockWeb-staging-aaaaaaa.zip"
        $address.RecordName | Should -BeExactly 'pr-test-artifact.json'
        $address.RecordPath | Should -BeExactly "pr-environments/staging/$sha/pr-test-artifact.json"
    }

    It 'takes a commit shorter than seven characters whole, as the package job always has' {
        # A hand dispatch can name a short commit. The package job packaged it
        # rather than failing, so composing an address must not throw either.
        $address = Get-ArtifactAddress -Slug 'pr-7' -Sha 'abc12'

        $address.ShortSha | Should -BeExactly 'abc12'
        $address.ObjectPath | Should -BeExactly 'pr-environments/pr-7/abc12/RockWeb-pr-7-abc12.zip'
    }
}

Describe 'ConvertFrom-ArtifactObjectPath' {
    It 'reads back the address it was composed from, for <Slug>' -ForEach @(
        @{ Slug = 'pr-42' }
        @{ Slug = 'staging' }
        @{ Slug = 'production' }
    ) {
        $composed = Get-ArtifactAddress -Slug $Slug -Sha '0123456789abcdef0123456789abcdef01234567'

        $parsed = @(ConvertFrom-ArtifactObjectPath -ObjectPath $composed.ObjectPath)

        $parsed.Count | Should -Be 1
        $parsed[0].Slug | Should -BeExactly $composed.Slug
        $parsed[0].Sha | Should -BeExactly $composed.Sha
        $parsed[0].ObjectPath | Should -BeExactly $composed.ObjectPath
        $parsed[0].RecordPath | Should -BeExactly $composed.RecordPath
    }

    It 'finds no artifact at <Path> (<Why>)' -ForEach @(
        @{ Path = "pr-environments/staging/$('a' * 40)/pr-test-artifact.json"; Why = 'the record beside a zip' }
        @{ Path = "pr-environments/staging/$('a' * 40)/RockWeb-staging-renamed.zip"; Why = 'a zip renamed by hand' }
        @{ Path = "pr-environments/staging/$('a' * 40)/rockweb-staging-aaaaaaa.zip"; Why = 'object names keep their case' }
        @{ Path = "pr-environments/staging/$('a' * 40)/RockWeb-pr-42-aaaaaaa.zip"; Why = 'a name for another slug than its folder' }
        @{ Path = 'pr-environments/staging/abc1234/RockWeb-staging-abc1234.zip'; Why = 'a short commit cannot be diffed against' }
        @{ Path = "elsewhere/staging/$('a' * 40)/RockWeb-staging-aaaaaaa.zip"; Why = 'outside the artifact prefix' }
        @{ Path = ''; Why = 'nothing at all' }
    ) {
        # Each of these is a base the plan would offer and the repackage could
        # not use: no zip, no record beside it, or no commit to diff from.
        $parsed = @(ConvertFrom-ArtifactObjectPath -ObjectPath $Path)

        $parsed.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ArtifactListing' {
    It 'keeps each artifact zip in a gsutil ls -l listing, with its slug, commit and age' {
        $sha = 'a' * 40
        $listing = @(
            "  412345678  2026-10-14T18:02:11Z  gs://rock-pr-env/pr-environments/staging/$sha/RockWeb-staging-aaaaaaa.zip"
            "        312  2026-10-14T18:02:12Z  gs://rock-pr-env/pr-environments/staging/$sha/pr-test-artifact.json"
            '  412345678  2026-10-13T09:00:00Z  gs://rock-pr-env/pr-environments/pr-42/abc1234/RockWeb-pr-42-abc1234.zip'
            'TOTAL: 3 objects, 824691368 bytes (786.48 MiB)'
        )

        $artifact = @(ConvertFrom-ArtifactListing -Line $listing)

        $artifact.Count | Should -Be 1
        $artifact[0].Slug | Should -BeExactly 'staging'
        $artifact[0].Sha | Should -BeExactly $sha
        $artifact[0].ObjectPath | Should -BeExactly "pr-environments/staging/$sha/RockWeb-staging-aaaaaaa.zip"
        $artifact[0].Updated | Should -Be ([DateTimeOffset]'2026-10-14T18:02:11Z')
    }
}

Describe 'the artifact record' {
    BeforeEach {
        $script:RecordPath = Join-Path $TestDrive 'pr-test-artifact.json'
        Remove-Item -Path $script:RecordPath -ErrorAction SilentlyContinue
        $script:Address = Get-ArtifactAddress -Slug 'pr-42' -Sha ('b' * 40)
    }

    It 'reads back what a build writes, in the order the build has always written it' {
        $record = New-ArtifactRecord -Address $script:Address -Bucket 'rock-pr-env' -PrNumber '42' -HostName 'pr-42.rock-dev.example' -Sha256 'ABC123'
        Write-ArtifactRecord -Record $record -Path $script:RecordPath

        Get-RecordFieldOrder -Path $script:RecordPath | Should -BeExactly $script:BuildFields

        $read = Read-ArtifactRecord -Path $script:RecordPath
        $read.prNumber | Should -BeExactly '42'
        $read.sha | Should -BeExactly ('b' * 40)
        $read.shortSha | Should -BeExactly 'bbbbbbb'
        $read.artifactName | Should -BeExactly 'RockWeb-pr-42-bbbbbbb.zip'
        $read.artifactGcsPath | Should -BeExactly "gs://rock-pr-env/pr-environments/pr-42/$('b' * 40)/RockWeb-pr-42-bbbbbbb.zip"
        $read.hostName | Should -BeExactly 'pr-42.rock-dev.example'
        $read.sha256 | Should -BeExactly 'ABC123'
        # A built zip carries its own commit's output; "not recorded" is how a
        # later repackage learns that.
        $read.builtFromSha | Should -BeExactly ''
        $read.baseArtifactGcsPath | Should -BeExactly ''
    }

    It 'reads back what a repackage writes: the build''s fields first, then where it came from' {
        $base = Get-ArtifactAddress -Slug 'staging' -Sha ('c' * 40)
        $record = New-ArtifactRecord -Address $script:Address -Bucket 'rock-pr-env' -PrNumber '42' -HostName 'pr-42.rock-dev.example' `
            -Sha256 'DEF456' -BuiltFromSha ('d' * 40) -BaseObjectPath $base.ObjectPath
        Write-ArtifactRecord -Record $record -Path $script:RecordPath

        Get-RecordFieldOrder -Path $script:RecordPath | Should -BeExactly $script:RepackageFields

        $read = Read-ArtifactRecord -Path $script:RecordPath
        $read.sha | Should -BeExactly ('b' * 40)
        $read.builtFromSha | Should -BeExactly ('d' * 40)
        $read.baseArtifactGcsPath | Should -BeExactly "gs://rock-pr-env/pr-environments/staging/$('c' * 40)/RockWeb-staging-ccccccc.zip"
    }

    It 'reads a record an older package step wrote' {
        # Written by hand, as the inline package step wrote it before the
        # module existed: every base in the bucket today looks like this. An
        # unknown field is dropped rather than refused.
        Set-Content -Path $script:RecordPath -Value @'
{
  "prNumber": "",
  "sha": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "shortSha": "eeeeeee",
  "artifactName": "RockWeb-staging-eeeeeee.zip",
  "artifactGcsPath": "gs://rock-pr-env/pr-environments/staging/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/RockWeb-staging-eeeeeee.zip",
  "hostName": "",
  "sha256": "0F1E2D",
  "somethingNewer": "ignored"
}
'@

        $read = Read-ArtifactRecord -Path $script:RecordPath

        ($read.PSObject.Properties | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly $script:RepackageFields
        $read.sha256 | Should -BeExactly '0F1E2D'
        $read.prNumber | Should -BeExactly ''
        $read.builtFromSha | Should -BeExactly ''
    }
}

Describe 'Write-ArtifactOutput' {
    It 'hands on the five outputs pr-test-artifact.yml returns from whichever job packaged' {
        $outputPath = Join-Path $TestDrive 'github-output.txt'
        Remove-Item -Path $outputPath -ErrorAction SilentlyContinue
        $address = Get-ArtifactAddress -Slug 'pr-42' -Sha ('b' * 40)

        Write-ArtifactOutput -Address $address -PrNumber '42' -HostName 'pr-42.rock-dev.example' -Path $outputPath

        (Get-Content -Path $outputPath) -join "`n" | Should -BeExactly (@(
            'artifact_name=RockWeb-pr-42-bbbbbbb.zip'
            "artifact_gcs_object_path=pr-environments/pr-42/$('b' * 40)/RockWeb-pr-42-bbbbbbb.zip"
            'host_name=pr-42.rock-dev.example'
            'pr_number=42'
            "sha=$('b' * 40)"
        ) -join "`n")
    }
}

Describe 'packaging a built RockWeb' {
    BeforeEach {
        # A built RockWeb, as far as packaging can tell: one file at its root and
        # one below it.
        $script:Work = Join-Path $TestDrive 'package'
        if (Test-Path $script:Work) { Remove-Item $script:Work -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'RockWeb/Bin') -Force | Out-Null
        Set-Content -Path (Join-Path $script:Work 'RockWeb/web.config') -Value '<configuration />' -NoNewline
        Set-Content -Path (Join-Path $script:Work 'RockWeb/Bin/Rock.dll') -Value 'compiled' -NoNewline

        $script:OutputPath = Join-Path $TestDrive 'package-output.txt'
        Remove-Item -Path $script:OutputPath -ErrorAction SilentlyContinue
        $script:SavedOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = $script:OutputPath

        # The script works in the current directory, as the job's step does.
        Push-Location $script:Work
    }

    AfterEach {
        Pop-Location
        $env:GITHUB_OUTPUT = $script:SavedOutput
    }

    It 'zips the contents of RockWeb, records the zip, and hands on where it goes' {
        $sha = '0123456789abcdef0123456789abcdef01234567'

        & $script:PackageScript -TargetSha $sha -ArtifactSlug 'pr-42' -Bucket 'rock-pr-env' -PrNumber '42' -HostName 'pr-42.rock-dev.example'

        $zip = Join-Path $script:Work 'RockWeb-pr-42-0123456.zip'
        $zip | Should -Exist

        # At the zip's root, not under RockWeb/: the deploy expands it into the
        # site directory itself.
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        }
        finally {
            $archive.Dispose()
        }
        $entries | Should -Contain 'web.config'
        $entries | Should -Contain 'Bin/Rock.dll'

        # The hash a later repackage checks this zip against before reusing it.
        $record = Read-ArtifactRecord -Path (Join-Path $script:Work 'pr-test-artifact.json')
        $record.sha256 | Should -BeExactly (Get-FileHash -Path $zip -Algorithm SHA256).Hash
        $record.artifactGcsPath | Should -BeExactly "gs://rock-pr-env/pr-environments/pr-42/$sha/RockWeb-pr-42-0123456.zip"
        $record.prNumber | Should -BeExactly '42'
        $record.hostName | Should -BeExactly 'pr-42.rock-dev.example'
        Get-RecordFieldOrder -Path (Join-Path $script:Work 'pr-test-artifact.json') | Should -BeExactly $script:BuildFields

        (Get-Content -Path $script:OutputPath) -join "`n" | Should -BeExactly (@(
            'artifact_name=RockWeb-pr-42-0123456.zip'
            "artifact_gcs_object_path=pr-environments/pr-42/$sha/RockWeb-pr-42-0123456.zip"
            'host_name=pr-42.rock-dev.example'
            'pr_number=42'
            "sha=$sha"
        ) -join "`n")
    }

    It 'writes a zip a later plan can find as a base' {
        # The point of the shared module: what the package step uploads is what
        # the plan's listing recognises, so a Lava change after this build can
        # skip the next one.
        $sha = '0123456789abcdef0123456789abcdef01234567'

        & $script:PackageScript -TargetSha $sha -ArtifactSlug 'staging' -Bucket 'rock-pr-env'

        $objectPath = (Get-Content -Path $script:OutputPath | Where-Object { $_ -like 'artifact_gcs_object_path=*' }) -replace '^artifact_gcs_object_path=', ''
        $listing = "  412345678  2026-10-14T18:02:11Z  gs://rock-pr-env/$objectPath"

        $found = @(ConvertFrom-ArtifactListing -Line @($listing))

        $found.Count | Should -Be 1
        $found[0].Slug | Should -BeExactly 'staging'
        $found[0].Sha | Should -BeExactly $sha
    }

    It 'records a run with no pull request, as staging and production are' {
        # Their PR_NUMBER and HOST_NAME are unset on the Windows runner, so the
        # step hands the script $null rather than an empty string.
        & $script:PackageScript -TargetSha ('f' * 40) -ArtifactSlug 'production' -Bucket 'rock-pr-env' -PrNumber $null -HostName $null

        $record = Read-ArtifactRecord -Path (Join-Path $script:Work 'pr-test-artifact.json')
        $record.prNumber | Should -BeExactly ''
        $record.hostName | Should -BeExactly ''
        Get-Content -Path $script:OutputPath | Should -Contain 'pr_number='
    }
}
