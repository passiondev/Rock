<#
    The agent refreshes its own deployment scripts from bootstrap/latest on every
    poll, and eight tests in test_command_queue_self_update.py say so. All eight
    read the source text. None of them fetched anything, and the refresh had never
    delivered a file in its life.

    gsutil types a .ps1 as application/octet-stream. Invoke-WebRequest returns
    .Content as a byte[] for every content type outside the text, JSON and XML
    families, so Read-GcsObjectText returned bytes where its one caller wanted
    text. The parse check then rejected the byte[] rendered as "35 32 82 111 ..."
    and kept the copy on disk, per file, per poll, warning to a stream nothing
    collects. The command queue was unaffected the whole time because command
    objects are written as application/json -- same function, same VM, opposite
    outcome, which is why this survived every green run.

    Measured 2026-08-24: a script published straight to bootstrap/latest did not
    reach the VM across two dispatches 36 minutes apart.

    These tests call the functions. A structural test cannot tell a byte[] from a
    string, and that distinction was the entire defect.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AgentScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Invoke-PrEnvironmentCommandQueue.ps1'
    . (Import-ScriptFunction -Path $script:AgentScript -Name 'Read-GcsObjectText', 'Sync-DeploymentScripts')

    $script:BucketName = 'connect-file-storage'
    $script:ScriptText = "param([string]`$Name)`nWrite-Host `"hello `$Name`"`n"
    $script:Prefix = 'pr-environments/bootstrap/latest/'

    # Leaf names are held in variables and concatenated, never interpolated into a
    # quoted string ending in .ps1. test_powershell_job.py reads every quoted .ps1
    # literal in this directory as a script that must exist under Deployment/, and
    # a GCS object name is not one -- rightly, since that check is what catches a
    # suite still loading a renamed script.
    $script:DeployScript = 'Deploy-RockEnvironment.ps1'
    $script:StopScript = 'Stop-PrEnvironment.ps1'
    $script:NestedFolder = 'PrTestEnvironments/'

    # Mocks are defined once, here, and steered by the script-scoped variables the
    # tests set. Redefining a function inside an It leaks it into every It that
    # follows, which is its own source of false greens.
    $script:NextContent = $null
    $script:Listed = @()
    $script:FetchMap = @{}

    function script:Get-GcsAccessToken { return 'fake-token' }

    # One mock at the network edge, so the sync tests exercise the real
    # Read-GcsObjectText and its decode rather than a stand-in for it. An earlier
    # draft shadowed Read-GcsObjectText per Describe; the override never took, the
    # real function answered from a constant, and all four sync tests passed
    # without ever reading the content they claimed to assert on.
    #
    # $script:NextContent, when set, is returned verbatim -- that is how the
    # Read-GcsObjectText tests choose a response type. Otherwise the object name is
    # recovered from the media URI and answered from $script:FetchMap as UTF-8
    # bytes, which is what GCS returns for application/octet-stream.
    function script:Invoke-WebRequest {
        param(
            [switch]$UseBasicParsing,
            $Headers,
            [string]$Uri,
            [Parameter(ValueFromRemainingArguments = $true)]$Rest
        )

        if ($null -ne $script:NextContent) {
            return [pscustomobject]@{ Content = $script:NextContent }
        }

        $encoded = ($Uri -replace '^.*/o/', '') -replace '\?alt=media$', ''
        $name = [System.Uri]::UnescapeDataString($encoded)
        if (-not $script:FetchMap.ContainsKey($name)) {
            throw "404 Not Found: $name"
        }
        return [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes($script:FetchMap[$name]) }
    }

    function script:Get-GcsObjectList {
        param([Parameter(Mandatory = $true)][string]$Prefix)
        return $script:Listed
    }
}

Describe 'Read-GcsObjectText' {
    It 'returns text when the response is already text' {
        $script:NextContent = $script:ScriptText

        $result = Read-GcsObjectText -ObjectName ($script:Prefix + $script:DeployScript)

        $result | Should -BeOfType [string]
        $result | Should -Be $script:ScriptText
    }

    It 'returns text when the response is a byte array' {
        # application/octet-stream, which is what gsutil sets on every .ps1 in the
        # bucket today. Before the decode this returned System.Byte[].
        $script:NextContent = [System.Text.Encoding]::UTF8.GetBytes($script:ScriptText)

        $result = Read-GcsObjectText -ObjectName ($script:Prefix + $script:DeployScript)

        $result | Should -BeOfType [string]
        $result | Should -Be $script:ScriptText
    }

    It 'does not hand the parser a list of numbers' {
        # The precise failure. A byte[] coerced by a [string] parameter renders as
        # its elements joined by spaces, which is not PowerShell and never parses.
        $script:NextContent = [System.Text.Encoding]::UTF8.GetBytes($script:ScriptText)

        $result = Read-GcsObjectText -ObjectName ($script:Prefix + $script:DeployScript)

        $result | Should -Not -Match '^\d+ \d+ \d+'

        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($result, [ref]$null, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -Be 0
    }

    It 'strips a UTF-8 BOM' {
        # Kept, the leading U+FEFF makes the fetched text differ from an identical
        # file on disk, so the refresh rewrites every script on every poll.
        # Cast, not concatenated: `+` on two byte arrays widens to Object[], which
        # is not the type Invoke-WebRequest returns.
        $script:NextContent = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($script:ScriptText))

        $result = Read-GcsObjectText -ObjectName ($script:Prefix + $script:DeployScript)

        $result | Should -BeOfType [string]
        $result | Should -Be $script:ScriptText
        $result.StartsWith([char]0xFEFF) | Should -BeFalse
    }
}

Describe 'Sync-DeploymentScripts' {
    BeforeEach {
        # Cleared so the Invoke-WebRequest mock answers from $script:FetchMap
        # instead of replaying whatever the last Read-GcsObjectText test set.
        $script:NextContent = $null
        $script:Destination = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-" + [System.Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:Destination -Force | Out-Null
        $script:Listed = @()
        $script:FetchMap = @{}
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Destination -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a published script to disk' {
        $name = $script:Prefix + $script:DeployScript
        $script:Listed = @($name)
        $script:FetchMap = @{ $name = $script:ScriptText }

        Sync-DeploymentScripts -Prefix $script:Prefix -Destination $script:Destination

        $landed = Join-Path $script:Destination $script:DeployScript
        Test-Path $landed | Should -BeTrue
        (Get-Content $landed -Raw) | Should -Be $script:ScriptText
    }

    It 'ignores objects in a subdirectory of the prefix' {
        # bootstrap/latest/ still holds a PrTestEnvironments/ folder of April 2026
        # scaffolding. Split-Path -Leaf flattens those onto the same destination
        # names, so without this filter the refresh overwrites eight live scripts
        # with four-month-old stubs -- and it would start doing that the moment the
        # decode above made the refresh work at all.
        $top = $script:Prefix + $script:StopScript
        $nested = $script:Prefix + $script:NestedFolder + $script:StopScript
        $script:Listed = @($top, $nested)
        $script:FetchMap = @{ $top = $script:ScriptText; $nested = "# April stub`n" }

        Sync-DeploymentScripts -Prefix $script:Prefix -Destination $script:Destination

        $landed = Join-Path $script:Destination $script:StopScript
        (Get-Content $landed -Raw) | Should -Be $script:ScriptText
        (Get-Content $landed -Raw) | Should -Not -Match 'April stub'
    }

    It 'keeps the copy on disk when the download does not parse' {
        $landed = Join-Path $script:Destination $script:StopScript
        Set-Content -LiteralPath $landed -Value $script:ScriptText -NoNewline

        $name = $script:Prefix + $script:StopScript
        $script:Listed = @($name)
        $script:FetchMap = @{ $name = 'function {{{ broken' }

        Sync-DeploymentScripts -Prefix $script:Prefix -Destination $script:Destination -WarningAction SilentlyContinue

        (Get-Content $landed -Raw) | Should -Be $script:ScriptText
    }

    It 'leaves no staging file behind' {
        $name = $script:Prefix + $script:DeployScript
        $script:Listed = @($name)
        $script:FetchMap = @{ $name = $script:ScriptText }

        Sync-DeploymentScripts -Prefix $script:Prefix -Destination $script:Destination

        @(Get-ChildItem -Path $script:Destination -Filter '*.sync').Count | Should -Be 0
    }
}
