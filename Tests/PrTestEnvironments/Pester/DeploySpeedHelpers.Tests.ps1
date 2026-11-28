<#
    Unit tests for the CD speed helpers shared across Deploy-RockEnvironment.ps1
    and Deploy-PrEnvironment.ps1:
      - Expand-ArtifactArchive (fast ZipFile / 7z extraction)
      - Remove-DirectoryFast (fast rmdir /s /q deletion)
      - Add-DeployDefenderExclusions (best-effort Windows Defender exclusion)
      - Copy-GcsObjectToFile (buffered HttpWebRequest streaming download)
      - Multi-threaded robocopy (/MT:16) and $ProgressPreference suppression
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:RockDeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    $script:PrDeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-PrEnvironment.ps1'

    . (Import-ScriptFunction -Path $script:RockDeployScript -Name `
            'Expand-ArtifactArchive', 'Remove-DirectoryFast', 'Move-DirectoryWithRetry', 'Add-DeployDefenderExclusions', `
            'Copy-GcsObjectToFile' `
        -Supplied 'Get-GcsAccessToken')
}

Describe 'Expand-ArtifactArchive' {
    BeforeEach {
        $script:WorkRoot = Join-Path $TestDrive ('expand-' + [guid]::NewGuid().ToString('n'))
        $script:SourceDir = Join-Path $script:WorkRoot 'src'
        $script:ZipPath = Join-Path $script:WorkRoot 'artifact.zip'
        $script:DestDir = Join-Path $script:WorkRoot 'dest'

        New-Item -ItemType Directory -Path (Join-Path $script:SourceDir 'Bin') -Force | Out-Null
        Set-Content -Path (Join-Path $script:SourceDir 'web.config') -Value '<configuration />' -NoNewline
        Set-Content -Path (Join-Path $script:SourceDir 'Bin/Rock.dll') -Value 'binary-payload' -NoNewline

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:SourceDir, $script:ZipPath)
    }

    It 'extracts nested files into a non-existent destination directory' {
        Expand-ArtifactArchive -Path $script:ZipPath -DestinationPath $script:DestDir

        Test-Path (Join-Path $script:DestDir 'web.config') | Should -BeTrue
        (Get-Content -Raw -Path (Join-Path $script:DestDir 'web.config')) | Should -Be '<configuration />'
        (Get-Content -Raw -Path (Join-Path $script:DestDir 'Bin/Rock.dll')) | Should -Be 'binary-payload'
    }

    It 'extracts cleanly into an existing empty destination directory' {
        New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null

        Expand-ArtifactArchive -Path $script:ZipPath -DestinationPath $script:DestDir

        Test-Path (Join-Path $script:DestDir 'web.config') | Should -BeTrue
        Test-Path (Join-Path $script:DestDir 'Bin/Rock.dll') | Should -BeTrue
    }

    It 'handles relative source and destination paths' {
        Push-Location $script:WorkRoot
        try {
            Expand-ArtifactArchive -Path 'artifact.zip' -DestinationPath 'rel-dest'

            Test-Path (Join-Path $script:WorkRoot 'rel-dest/web.config') | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'Remove-DirectoryFast' {
    It 'deletes a nested non-empty directory tree' {
        $root = Join-Path $TestDrive ('rmfast-' + [guid]::NewGuid().ToString('n'))
        $nested = Join-Path $root 'a/b/c'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -Path (Join-Path $nested 'file.txt') -Value 'hello'

        Remove-DirectoryFast -Path $root

        Test-Path $root | Should -BeFalse
    }

    It 'is a safe no-op when the directory does not exist' {
        $missing = Join-Path $TestDrive ('missing-' + [guid]::NewGuid().ToString('n'))

        { Remove-DirectoryFast -Path $missing } | Should -Not -Throw
    }

    It 'deletes cleanly when -Async is passed' {
        $root = Join-Path $TestDrive ('rmasync-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -Path (Join-Path $root 'file.txt') -Value 'hello'

        { Remove-DirectoryFast -Path $root -Async } | Should -Not -Throw
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ((Test-Path $root) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Test-Path $root | Should -BeFalse
    }
}

Describe 'Move-DirectoryWithRetry' {
    It 'moves a directory and its contents cleanly' {
        $src = Join-Path $TestDrive ('mvsrc-' + [guid]::NewGuid().ToString('n'))
        $dst = Join-Path $TestDrive ('mvdst-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $src 'file.txt') -Value 'ok'

        { Move-DirectoryWithRetry -SourcePath $src -DestinationPath $dst } | Should -Not -Throw

        Test-Path $src | Should -BeFalse
        Test-Path (Join-Path $dst 'file.txt') | Should -BeTrue
    }

    It 'throws after MaxAttempts when source does not exist' {
        $missing = Join-Path $TestDrive ('mvmissing-' + [guid]::NewGuid().ToString('n'))
        $dst = Join-Path $TestDrive ('mvdst-fail-' + [guid]::NewGuid().ToString('n'))

        { Move-DirectoryWithRetry -SourcePath $missing -DestinationPath $dst -MaxAttempts 2 -DelaySeconds 0 } | Should -Throw
    }
}

Describe 'Add-DeployDefenderExclusions' {
    It 'never throws when called with empty or non-empty paths' {
        { Add-DeployDefenderExclusions -Paths @('', $TestDrive) } | Should -Not -Throw
    }
}

Describe 'Copy-GcsObjectToFile' {
    It 'rejects an invalid GCS URI' {
        $dest = Join-Path $TestDrive 'out.zip'

        { Copy-GcsObjectToFile -GcsUri 'https://example.com/not-gs.zip' -DestinationPath $dest } |
            Should -Throw '*Invalid GCS URI*'
    }
}

Describe 'CD performance guardrails' {
    It 'suppresses PowerShell progress bars in both deploy scripts' {
        foreach ($path in @($script:RockDeployScript, $script:PrDeployScript)) {
            $text = Get-Content -Raw -Path $path
            $text | Should -Match '\$ProgressPreference\s*=\s*["'']SilentlyContinue["'']'
        }
    }

    It 'passes /MT on every robocopy call in both deploy scripts' {
        foreach ($path in @($script:RockDeployScript, $script:PrDeployScript)) {
            $lines = (Get-Content -Path $path) | Where-Object { $_.TrimStart().StartsWith('& robocopy') }
            @($lines).Count | Should -BeGreaterThan 0
            foreach ($line in $lines) {
                $line | Should -Match '/MT:(16|32)'
            }
        }
    }
}
