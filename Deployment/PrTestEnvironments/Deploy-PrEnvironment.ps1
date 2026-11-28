<#
.SYNOPSIS
Creates or updates an IIS-backed Rock RMS pull request test environment.

.DESCRIPTION
This script is intended to run on the Google Windows IIS host. It is idempotent
for a PR number: re-running it stops the app pool, replaces the site files from
the supplied artifact, reconciles IIS site/app-pool/binding state, writes the
sandbox connection string, records env.json, and starts the site again.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [int]
    $PrNumber,

    [Parameter(Mandatory = $true)]
    [string]
    $Sha,

    [Parameter(Mandatory = $true)]
    [string]
    $ArtifactGcsPath,

    [Parameter(Mandatory = $true)]
    [string]
    $HostName,

    [Parameter(Mandatory = $true)]
    [string]
    $SandboxConnectionString,

    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs",

    [Parameter(Mandatory = $false)]
    [string]
    $CertificateThumbprint = $env:PR_TEST_CERTIFICATE_THUMBPRINT,

    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetSourcePath = $env:PR_TEST_SHARED_ASSET_SOURCE_PATH,

    # Plugins is in this list because RockWeb/Plugins/.gitignore is `*/*`: not one
    # plugin subfolder is tracked in git, so none of them ride in the build
    # artifact. Passion's login page is a plugin block at
    # Plugins/org_passion/Security/Login.ascx, so without this backfill every test
    # site serves "Error Loading Block: Login -- The file
    # '/Plugins/org_passion/Security/Login.ascx' does not exist" as its landing
    # page, and that takes /Login and every admin page redirecting to it with it.
    # Nobody can sign in to a PR environment at all. Removing Plugins from this
    # list puts that failure straight back.
    # bin rides along for the same reason, one layer down: the plugin source above
    # is useless without the assemblies that define its namespaces, and those
    # exist only in the base site's bin. Missing them takes out every
    # BinaryFileType, which stores through rocks.pillars.AmazonStorageProvider,
    # so GetImage.ashx 404s every image on the site. Sync-SharedSiteAssets uses
    # robocopy /XC /XN /XO -- absent files only -- so this can never overwrite an
    # assembly the artifact shipped.
    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetDirectories = $(if ([string]::IsNullOrWhiteSpace($env:PR_TEST_SHARED_ASSET_DIRECTORIES)) { 'Themes,Content,Assets,Styles,Plugins,bin' } else { $env:PR_TEST_SHARED_ASSET_DIRECTORIES })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Import-Module WebAdministration

$SiteName = "rock-pr-$PrNumber"
$AppPoolName = "rock-pr-$PrNumber"
$EnvironmentPath = Join-Path $EnvironmentRoot "pr-$PrNumber"
$SitePath = Join-Path $EnvironmentPath "site"
$ArtifactPath = Join-Path $EnvironmentPath "artifact.zip"
$ExtractPath = Join-Path $EnvironmentPath "extract"
$ManifestPath = Join-Path $EnvironmentPath "env.json"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Stop-PrEnvironmentAppPool {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (Test-Path "IIS:\AppPools\$Name") {
        $state = (Get-WebAppPoolState -Name $Name).Value
        if ($state -ne "Stopped") {
            Stop-WebAppPool -Name $Name
        }
    }
}

function Ensure-AppPool {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (!(Test-Path "IIS:\AppPools\$Name")) {
        New-WebAppPool -Name $Name | Out-Null
    }

    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.identityType -Value "ApplicationPoolIdentity"
}

function Get-PrEnvironmentCertificateThumbprint {
    param(
        [Parameter(Mandatory = $true)][string]$HostHeader,
        [Parameter(Mandatory = $false)][string]$Thumbprint
    )

    if (![string]::IsNullOrWhiteSpace($Thumbprint)) {
        return $Thumbprint
    }

    $domain = ($HostHeader -replace '^[^.]+\.', '*.')
    $candidates = @(Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { ($_.DnsNameList -contains $HostHeader) -or ($_.DnsNameList -contains $domain) -or ($_.Subject -eq "CN=$domain") } |
        Where-Object { $_.NotAfter -gt (Get-Date) })

    # Rank CA-issued certificates ahead of the self-signed placeholder, and only
    # then prefer the later expiry. This is the same selector as
    # Deploy-RockEnvironment.ps1 and it is here for the same reason: the
    # placeholder minted below lasts two years while a Let's Encrypt certificate
    # lasts ninety days, so sorting on NotAfter alone made the placeholder win
    # forever and every PR deploy silently rebound the site to an untrusted
    # certificate. Measured 2026-08-11: pr-4 held a real Let's Encrypt
    # certificate expiring 2026-11-08 while the placeholder expires 2028-05-06.
    # A self-signed certificate is its own issuer; a CA-issued one is not.
    $cert = $candidates |
        Sort-Object -Property @(
            @{ Expression = { $_.Issuer -eq $_.Subject }; Ascending = $true },
            @{ Expression = { $_.NotAfter }; Descending = $true }
        ) |
        Select-Object -First 1

    if ($null -eq $cert) {
        $cert = New-SelfSignedCertificate -DnsName @($domain, $HostHeader) -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'Rock PR Test Environments wildcard' -NotAfter (Get-Date).AddYears(2)
    }

    return $cert.Thumbprint
}

function Remove-PluginBuildArtifacts {
    param([Parameter(Mandatory = $true)][string]$SitePath)

    $pluginRoot = Join-Path $SitePath 'Plugins'
    if (Test-Path $pluginRoot) {
        Get-ChildItem $pluginRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('bin', 'obj') } |
            Sort-Object FullName -Descending |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SharedAssetSourcePath {
    param([Parameter(Mandatory = $false)][string]$ExplicitPath)

    if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [Environment]::ExpandEnvironmentVariables($ExplicitPath)
    }

    $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($null -ne $defaultSite -and ![string]::IsNullOrWhiteSpace($defaultSite.physicalPath)) {
        return [Environment]::ExpandEnvironmentVariables($defaultSite.physicalPath)
    }

    return $null
}

function Sync-SharedSiteAssets {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$DirectoryList
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or !(Test-Path $SourceRoot)) {
        Write-Host "Shared site asset source not found; skipping shared asset overlay. SourceRoot=$SourceRoot"
        return
    }

    $directories = $DirectoryList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    foreach ($directory in $directories) {
        if ($directory -match '[\\/]|\.\.') {
            throw "Shared asset directory must be a simple child directory name: $directory"
        }

        $sourcePath = Join-Path $SourceRoot $directory
        $destinationPath = Join-Path $DestinationRoot $directory
        if (!(Test-Path $sourcePath)) {
            Write-Host "Shared asset directory not present on source site; skipping $sourcePath"
            continue
        }

        Ensure-Directory -Path $destinationPath
        Write-Host "Overlaying shared site assets from $sourcePath to $destinationPath"

        # /E plus /XC /XN /XO copies only files that do not already exist at the
        # destination. This used to be /MIR, which mirrored the base site over the
        # PR site -- overwriting every file the branch had changed and deleting any
        # file the branch had added. A PR that edited a theme, a Lava file, or a
        # stylesheet deployed green and then showed none of its own changes, which
        # is indistinguishable from "the deploy did not work."
        #
        # The point of the overlay is to fill in what the artifact cannot carry:
        # uploaded Content and Assets, and theme files customized through the Rock
        # UI rather than in git. Those are exactly the files absent from the
        # artifact, so "copy only what is missing" is the correct rule -- the
        # branch stays authoritative for everything it actually ships.
        & robocopy $sourcePath $destinationPath /E /XC /XN /XO /MT:32 /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -gt 7) {
            throw "robocopy failed for shared asset directory $directory with exit code $exitCode."
        }
        if ($exitCode -eq 0) {
            Write-Host "  No missing files to backfill for $directory (artifact already complete)."
        }
    }
}

function Ensure-Website {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$PhysicalPath,
        [Parameter(Mandatory = $true)][string]$HostHeader,
        [Parameter(Mandatory = $true)][string]$PoolName,
        [Parameter(Mandatory = $false)][string]$Thumbprint
    )

    if (!(Test-Path "IIS:\Sites\$Name")) {
        New-Website -Name $Name -PhysicalPath $PhysicalPath -ApplicationPool $PoolName -Port 80 -HostHeader $HostHeader | Out-Null
    }
    else {
        Set-ItemProperty "IIS:\Sites\$Name" -Name physicalPath -Value $PhysicalPath
        Set-ItemProperty "IIS:\Sites\$Name" -Name applicationPool -Value $PoolName
    }

    $httpBinding = Get-WebBinding -Name $Name -Protocol http -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq "*:80:$HostHeader" }
    if (!$httpBinding) {
        New-WebBinding -Name $Name -Protocol http -Port 80 -HostHeader $HostHeader | Out-Null
    }

    $httpsBinding = Get-WebBinding -Name $Name -Protocol https -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq "*:443:$HostHeader" }
    if (!$httpsBinding) {
        New-WebBinding -Name $Name -Protocol https -Port 443 -HostHeader $HostHeader -SslFlags 1 | Out-Null
        $httpsBinding = Get-WebBinding -Name $Name -Protocol https |
            Where-Object { $_.bindingInformation -eq "*:443:$HostHeader" }
    }

    $certificateThumbprint = Get-PrEnvironmentCertificateThumbprint -HostHeader $HostHeader -Thumbprint $Thumbprint
    $httpsBinding.AddSslCertificate($certificateThumbprint, "My")
}

function Get-GcsAccessToken {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    $tokenResponse = Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    return $tokenResponse.access_token
}

function Expand-ArtifactArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (!(Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $resolvedSource = (Resolve-Path -LiteralPath $Path).Path
    $resolvedDestination = (Resolve-Path -LiteralPath $DestinationPath).Path

    $sevenZipExe = $null
    $sevenZipCmd = Get-Command -Name '7z.exe', '7z' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $sevenZipCmd) {
        $sevenZipExe = $sevenZipCmd.Source
    }
    elseif ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        foreach ($candidate in @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')) {
            if (Test-Path -LiteralPath $candidate) {
                $sevenZipExe = $candidate
                break
            }
        }
    }

    if (![string]::IsNullOrWhiteSpace($sevenZipExe)) {
        & $sevenZipExe x $resolvedSource "-o$resolvedDestination" -y -bd -bso0 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($resolvedSource, $resolvedDestination)
        return
    }
    catch {
        if ($_.Exception -is [System.IO.IOException]) {
            throw
        }
    }

    Expand-Archive -Path $resolvedSource -DestinationPath $resolvedDestination -Force
}

function Remove-DirectoryFast {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Async
    )

    if (!(Test-Path -LiteralPath $Path)) {
        return
    }

    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        if ($Async) {
            try {
                Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "rmdir /s /q `"$Path`"") -WindowStyle Hidden | Out-Null
                return
            }
            catch { }
        }

        & cmd.exe /c "rmdir /s /q `"$Path`"" 2>$null | Out-Null
        if (!(Test-Path -LiteralPath $Path)) {
            return
        }
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Move-DirectoryWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $false)][int]$MaxAttempts = 15,
        [Parameter(Mandatory = $false)][int]$DelaySeconds = 1
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Add-DeployDefenderExclusions {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Paths
    )

    if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
        return
    }

    if (!(Get-Command -Name 'Add-MpPreference' -ErrorAction SilentlyContinue)) {
        return
    }

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

function Copy-GcsObjectToFile {
    param(
        [Parameter(Mandatory = $true)][string]$GcsUri,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if ($GcsUri -notmatch '^gs://([^/]+)/(.+)$') {
        throw "Invalid GCS URI: $GcsUri"
    }

    $bucket = $Matches[1]
    $objectName = $Matches[2]
    $encodedObjectName = [System.Uri]::EscapeDataString($objectName)
    $token = Get-GcsAccessToken
    $uri = "https://storage.googleapis.com/storage/v1/b/$bucket/o/$encodedObjectName`?alt=media"

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $fullDestination = if ([System.IO.Path]::IsPathRooted($DestinationPath)) {
        $DestinationPath
    }
    else {
        Join-Path (Get-Location).Path $DestinationPath
    }

    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
    $request.Method = 'GET'
    $request.Headers.Add('Authorization', "Bearer $token")
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $request.Timeout = 600000
    $request.ReadWriteTimeout = 300000

    $response = $request.GetResponse()
    try {
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Create($fullDestination)
        try {
            $buffer = New-Object byte[] 1048576
            while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $bytesRead)
            }
        }
        finally {
            $fileStream.Dispose()
            $responseStream.Dispose()
        }
    }
    finally {
        $response.Dispose()
    }
}

# The only writer of prNumber anywhere, and so the only thing that makes a
# directory under the environment root a PR environment. Cleanup stops and
# destroys by it, the sandbox refresh stops pools by it, and renewal issues
# certificates for every deployed host it finds -- three readers, none of which
# calls this.
#
# It builds the manifest itself, from parameters, rather than writing whatever
# hashtable the caller assembled. That is what lets ManifestContract.Tests.ps1
# run it: the suite writes real manifests with this function and hands them to
# the real readers, so a field renamed here and not there fails a test instead
# of quietly stopping cleanup from ever finding the site.
function Write-EnvironmentManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [int]
        $PrNumber,

        [Parameter(Mandatory = $true)]
        [string]
        $Sha,

        [Parameter(Mandatory = $true)]
        [string]
        $ArtifactGcsPath,

        [Parameter(Mandatory = $true)]
        [string]
        $HostName,

        [Parameter(Mandatory = $true)]
        [string]
        $SiteName,

        [Parameter(Mandatory = $true)]
        [string]
        $AppPoolName,

        [Parameter(Mandatory = $true)]
        [string]
        $EnvironmentPath,

        [Parameter(Mandatory = $true)]
        [string]
        $SitePath
    )

    $manifest = @{
        prNumber = $PrNumber
        sha = $Sha
        artifactGcsPath = $ArtifactGcsPath
        hostName = $HostName
        siteName = $SiteName
        appPoolName = $AppPoolName
        environmentPath = $EnvironmentPath
        sitePath = $SitePath
        status = "deployed"
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8 -Force
}

if ($PrNumber -le 0) {
    throw "PrNumber must be a positive integer."
}

$MutexName = "Global\RockPrEnvironment-$PrNumber"
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$HasLock = $false

try {
    $HasLock = $Mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (!$HasLock) {
        throw "Timed out waiting for deployment lock $MutexName."
    }

    Ensure-Directory -Path $EnvironmentRoot
    Ensure-Directory -Path $EnvironmentPath
    Add-DeployDefenderExclusions -Paths @($EnvironmentRoot, $SitePath)

    Write-Host "Deploying $SiteName from $ArtifactGcsPath to $SitePath"

    if (Test-Path $ArtifactPath) {
        Remove-Item $ArtifactPath -Force
    }

    Copy-GcsObjectToFile -GcsUri $ArtifactGcsPath -DestinationPath $ArtifactPath

    Remove-DirectoryFast -Path $ExtractPath
    Ensure-Directory -Path $ExtractPath
    Expand-ArtifactArchive -Path $ArtifactPath -DestinationPath $ExtractPath

    Stop-PrEnvironmentAppPool -Name $AppPoolName

    $previousSitePath = ''
    if (Test-Path -LiteralPath $SitePath) {
        $previousSitePath = "$SitePath.removing-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
        Move-DirectoryWithRetry -SourcePath $SitePath -DestinationPath $previousSitePath
    }
    Move-DirectoryWithRetry -SourcePath $ExtractPath -DestinationPath $SitePath
    if (![string]::IsNullOrWhiteSpace($previousSitePath)) {
        Remove-DirectoryFast -Path $previousSitePath -Async
    }
    $sharedAssetSource = Get-SharedAssetSourcePath -ExplicitPath $SharedAssetSourcePath
    Sync-SharedSiteAssets -SourceRoot $sharedAssetSource -DestinationRoot $SitePath -DirectoryList $SharedAssetDirectories

    # After the overlay, not before it. The overlay backfills Plugins from the base
    # site now, so stripping first would strip the artifact's build leftovers and
    # then copy the base site's own Plugins/*/bin and Plugins/*/obj in on top.
    Remove-PluginBuildArtifacts -SitePath $SitePath

    $RuntimeConfigScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Set-PrEnvironmentRuntimeConfiguration.ps1"
    & $RuntimeConfigScript -PrNumber $PrNumber -SitePath $SitePath -EnvironmentPath $EnvironmentPath -SandboxConnectionString $SandboxConnectionString
    Ensure-AppPool -Name $AppPoolName
    Ensure-Website -Name $SiteName -PhysicalPath $SitePath -HostHeader $HostName -PoolName $AppPoolName -Thumbprint $CertificateThumbprint

    Write-EnvironmentManifest -Path $ManifestPath -PrNumber $PrNumber -Sha $Sha `
        -ArtifactGcsPath $ArtifactGcsPath -HostName $HostName -SiteName $SiteName `
        -AppPoolName $AppPoolName -EnvironmentPath $EnvironmentPath -SitePath $SitePath

    Start-WebAppPool -Name $AppPoolName
    Start-Website -Name $SiteName

    Write-Host "Deployed $SiteName at https://$HostName"
}
finally {
    if ($HasLock) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}
