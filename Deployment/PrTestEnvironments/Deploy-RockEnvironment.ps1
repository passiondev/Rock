<#
.SYNOPSIS
Deploys a built RockWeb artifact to a named long-lived environment (staging, production).

.DESCRIPTION
Runs on a Windows IIS host through the environment command queue, the same
control plane the PR test environments use. Two modes:

  DedicatedSite  Creates/updates its own IIS site and app pool, exactly like a PR
                 environment but keyed by name instead of PR number. Used for
                 staging on the test VM.

  InPlace        Updates an existing IIS site's files without recreating the site
                 or its bindings. Used for production, where the site, host
                 headers, certificate, and uploaded content already exist and
                 must survive the deploy. Takes a full backup first and refuses
                 to do anything unless -Apply is passed.

Both modes are idempotent for a given environment name.

.NOTES
DedicatedSite writes its manifest under $EnvironmentRoot (default C:\RockTestEnvs)
so Invoke-PrEnvironmentCertificateRenewal.ps1 discovers and renews its Let's
Encrypt certificate with no extra configuration -- that script keys off
hostName/siteName in env.json, not off a PR number.

InPlace deliberately writes its manifest somewhere else, so a certificate
renewal run on the test VM can never reach a production site.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]
    $Sha,

    [Parameter(Mandatory = $true)]
    [string]
    $ArtifactGcsPath,

    [Parameter(Mandatory = $true)]
    [string]
    $HostName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('DedicatedSite', 'InPlace')]
    [string]
    $Mode = 'DedicatedSite',

    # Optional for InPlace: production already has a working
    # web.ConnectionStrings.config on disk that must be left alone.
    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs",

    # InPlace only: the existing site root to update, e.g. C:\inetpub\wwwroot.
    [Parameter(Mandatory = $false)]
    [string]
    $TargetSitePath,

    # InPlace only: which IIS site/app pool front the target path.
    [Parameter(Mandatory = $false)]
    [string]
    $TargetSiteName = 'Default Web Site',

    [Parameter(Mandatory = $false)]
    [string]
    $TargetAppPoolName,

    [Parameter(Mandatory = $false)]
    [string]
    $BackupRoot = "C:\RockBackups",

    # InPlace is a no-op that only reports its plan unless this is passed. A
    # production overwrite should never be one typo away from happening.
    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [string]
    $CertificateThumbprint = $env:PR_TEST_CERTIFICATE_THUMBPRINT,

    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetSourcePath = $env:PR_TEST_SHARED_ASSET_SOURCE_PATH,

    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetDirectories = $(if ([string]::IsNullOrWhiteSpace($env:PR_TEST_SHARED_ASSET_DIRECTORIES)) { 'Themes,Content,Assets,Styles' } else { $env:PR_TEST_SHARED_ASSET_DIRECTORIES }),

    [Parameter(Mandatory = $false)]
    [int]
    $HealthCheckTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module WebAdministration

if ($EnvironmentName -notmatch '^[a-z][a-z0-9-]{1,30}$') {
    throw "EnvironmentName must be lowercase letters, digits and hyphens, starting with a letter: '$EnvironmentName'."
}

# Directories the artifact must never overwrite or delete. Content and uploaded
# files live only on the server -- they are user data, not build output. App_Data
# holds the Rock cache and the migration lock. Logs are forensic evidence.
$PreservedDirectories = @('Content', 'App_Data', 'Logs', 'Uploads')

# Files that are per-server configuration, not build output.
$PreservedFiles = @('web.ConnectionStrings.config')

$EnvironmentPath = Join-Path $EnvironmentRoot $EnvironmentName
$ArtifactPath = Join-Path $EnvironmentPath "artifact.zip"
$ExtractPath = Join-Path $EnvironmentPath "extract"

if ($Mode -eq 'DedicatedSite') {
    $SiteName = "rock-$EnvironmentName"
    $AppPoolName = "rock-$EnvironmentName"
    $SitePath = Join-Path $EnvironmentPath "site"
    $ManifestPath = Join-Path $EnvironmentPath "env.json"
}
else {
    if ([string]::IsNullOrWhiteSpace($TargetSitePath)) {
        throw "TargetSitePath is required when Mode is InPlace."
    }
    if (!(Test-Path $TargetSitePath)) {
        throw "TargetSitePath does not exist: $TargetSitePath"
    }
    $SiteName = $TargetSiteName
    $AppPoolName = if ([string]::IsNullOrWhiteSpace($TargetAppPoolName)) {
        (Get-ItemProperty "IIS:\Sites\$TargetSiteName" -Name applicationPool).Value
    } else { $TargetAppPoolName }
    $SitePath = $TargetSitePath
    # Never under $EnvironmentRoot: the certificate renewal job walks that tree
    # and stops/starts every site it finds a manifest for.
    $ManifestPath = Join-Path (Join-Path $BackupRoot $EnvironmentName) "env.json"
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-GcsAccessToken {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    $tokenResponse = Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    return $tokenResponse.access_token
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
    $encodedObjectName = [System.Uri]::EscapeDataString($Matches[2])
    $headers = @{ Authorization = "Bearer $(Get-GcsAccessToken)" }
    $uri = "https://storage.googleapis.com/storage/v1/b/$bucket/o/$encodedObjectName`?alt=media"
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $uri -OutFile $DestinationPath
}

function Write-GcsObjectFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][string]$ObjectName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $encodedObjectName = [System.Uri]::EscapeDataString($ObjectName)
    $headers = @{ Authorization = "Bearer $(Get-GcsAccessToken)" }
    $uri = "https://storage.googleapis.com/upload/storage/v1/b/$Bucket/o?uploadType=media&name=$encodedObjectName"
    Invoke-RestMethod -Headers $headers -Method POST -Uri $uri -InFile $Path -ContentType 'text/plain; charset=utf-8' | Out-Null
}

function Save-UnhealthyDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$Url
    )

    # When a deploy copies every file, starts the app pool, and the site still will
    # not answer, the reason is in the application's own logs on this box -- and
    # before this existed, reading them meant an RDP session. Collect them into one
    # report and put it in the deployment bucket.
    #
    # Deliberately NOT printed to standard output. This script's output is uploaded
    # and printed in a public repository's Actions log, and an application log can
    # carry a person's email address or a stack trace full of internal detail. The
    # bucket is private; the run log gets the object name and nothing else.
    $since = (Get-Date).AddHours(-1)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Rock environment diagnostics")
    $lines.Add("Collected (UTC): $((Get-Date).ToUniversalTime().ToString('o'))")
    $lines.Add("Environment:     $EnvironmentName")
    $lines.Add("Commit:          $Sha")
    $lines.Add("Host name:       $HostName")
    $lines.Add("Mode:            $Mode")
    $lines.Add("Site root:       $SiteRoot")
    $lines.Add("Health check:    $Url")
    $lines.Add("")

    $lines.Add("=== IIS state ===")
    try {
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            $lines.Add("App pool ${AppPoolName}: $((Get-WebAppPoolState -Name $AppPoolName).Value)")
        }
        else { $lines.Add("App pool ${AppPoolName}: missing") }
        if (Test-Path "IIS:\Sites\$SiteName") {
            $lines.Add("Site ${SiteName}: $((Get-Website -Name $SiteName).State)")
            foreach ($binding in @(Get-WebBinding -Name $SiteName)) {
                $lines.Add("  binding: $($binding.protocol) $($binding.bindingInformation)")
            }
        }
        else { $lines.Add("Site ${SiteName}: missing") }
    }
    catch { $lines.Add("Could not read IIS state: $($_.Exception.Message)") }
    $lines.Add("")

    $lines.Add("=== Deployed files ===")
    # Presence, size and version only. web.ConnectionStrings.config holds a
    # password, so its contents are never read here.
    foreach ($relative in @('web.config', 'web.ConnectionStrings.config', 'bin\Rock.dll', 'bin\Rock.Version.dll')) {
        $path = Join-Path $SiteRoot $relative
        if (Test-Path $path) {
            $item = Get-Item $path
            $version = ''
            if ($relative -like '*.dll') { $version = " version=$($item.VersionInfo.FileVersion)" }
            $lines.Add("$relative present bytes=$($item.Length) modified=$($item.LastWriteTimeUtc.ToString('o'))$version")
        }
        else { $lines.Add("$relative MISSING") }
    }
    $lines.Add("")

    $lines.Add("=== Windows Application event log, last hour, ASP.NET and .NET Runtime ===")
    try {
        $events = @(Get-WinEvent -LogName Application -MaxEvents 400 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $since -and $_.ProviderName -match 'ASP\.NET|\.NET Runtime|Application Error|IIS' } |
            Select-Object -First 25)
        if ($events.Count -eq 0) { $lines.Add("(no matching events -- the failure may not have reached the event log)") }
        foreach ($entry in $events) {
            $lines.Add("--- $($entry.TimeCreated.ToUniversalTime().ToString('o')) $($entry.ProviderName) id=$($entry.Id) level=$($entry.LevelDisplayName)")
            $lines.Add($entry.Message)
            $lines.Add("")
        }
    }
    catch { $lines.Add("Could not read the event log: $($_.Exception.Message)") }
    $lines.Add("")

    $lines.Add("=== Application logs under App_Data\Logs ===")
    try {
        $logFiles = @(Get-ChildItem (Join-Path $SiteRoot 'App_Data\Logs') -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)
        if ($logFiles.Count -eq 0) { $lines.Add("(no log files)") }
        foreach ($logFile in $logFiles) {
            $lines.Add("--- $($logFile.Name) modified=$($logFile.LastWriteTimeUtc.ToString('o')) bytes=$($logFile.Length)")
            $lines.Add(((Get-Content $logFile.FullName -Tail 120 -ErrorAction SilentlyContinue) -join "`n"))
            $lines.Add("")
        }
    }
    catch { $lines.Add("Could not read the application logs: $($_.Exception.Message)") }
    $lines.Add("")

    $lines.Add("=== Response body from the health check URL ===")
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 60 -ErrorAction SilentlyContinue
        $lines.Add("HTTP $($response.StatusCode)")
        $lines.Add([string]$response.Content)
    }
    catch {
        $lines.Add("Request threw: $($_.Exception.Message)")
        try {
            $errorResponse = $_.Exception.Response
            if ($errorResponse) {
                $reader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream())
                $lines.Add($reader.ReadToEnd())
                $reader.Dispose()
            }
        }
        catch { $lines.Add("(could not read the error response body)") }
    }

    # Light redaction even though the destination is private: a connection string
    # can reach a log through an exception message, and a password should not be
    # sitting in an object anyone with bucket read access can list.
    $report = [regex]::Replace(($lines -join "`r`n"), '(?i)(password\s*=\s*)([^;"''\r\n]+)', '${1}<redacted>')

    $bucket = ''
    if ($ArtifactGcsPath -match '^gs://([^/]+)/') { $bucket = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($bucket)) {
        Write-Warning "Could not determine the bucket from $ArtifactGcsPath; diagnostics not uploaded."
        return
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $localPath = Join-Path $env:TEMP "rock-diagnostics-$EnvironmentName-$stamp.txt"
    $report | Out-File -FilePath $localPath -Encoding utf8 -Force
    $objectName = "pr-environments/diagnostics/$EnvironmentName/$stamp-$Sha.txt"
    Write-GcsObjectFromFile -Bucket $bucket -ObjectName $objectName -Path $localPath
    Write-Host "Collected diagnostics for the unhealthy site: gs://$bucket/$objectName"
    Write-Host "Read it with: gsutil cat gs://$bucket/$objectName"
}

function Stop-EnvironmentAppPool {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (Test-Path "IIS:\AppPools\$Name") {
        if ((Get-WebAppPoolState -Name $Name).Value -ne "Stopped") {
            Stop-WebAppPool -Name $Name
        }
        # Give the worker process time to release file handles on Rock's
        # assemblies; robocopy against a live w3wp fails with sharing violations.
        for ($i = 0; $i -lt 30; $i++) {
            if ((Get-WebAppPoolState -Name $Name).Value -eq "Stopped") { break }
            Start-Sleep -Seconds 1
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

function Get-EnvironmentCertificateThumbprint {
    param(
        [Parameter(Mandatory = $true)][string]$HostHeader,
        [Parameter(Mandatory = $false)][string]$Thumbprint
    )

    if (![string]::IsNullOrWhiteSpace($Thumbprint)) { return $Thumbprint }

    $domain = ($HostHeader -replace '^[^.]+\.', '*.')
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { ($_.DnsNameList -contains $HostHeader) -or ($_.DnsNameList -contains $domain) -or ($_.Subject -eq "CN=$domain") } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $cert) {
        # A self-signed placeholder keeps the HTTPS binding valid until the
        # scheduled Let's Encrypt renewal replaces it.
        $cert = New-SelfSignedCertificate -DnsName @($domain, $HostHeader) -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'Rock environments wildcard' -NotAfter (Get-Date).AddYears(2)
    }

    return $cert.Thumbprint
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

    $httpsBinding.AddSslCertificate((Get-EnvironmentCertificateThumbprint -HostHeader $HostHeader -Thumbprint $Thumbprint), "My")
}

function Remove-PluginBuildArtifacts {
    param([Parameter(Mandatory = $true)][string]$Path)

    $pluginRoot = Join-Path $Path 'Plugins'
    if (Test-Path $pluginRoot) {
        Get-ChildItem $pluginRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('bin', 'obj') } |
            Sort-Object FullName -Descending |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Sync-SharedSiteAssets {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$DirectoryList
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or !(Test-Path $SourceRoot)) {
        Write-Host "Shared site asset source not found; skipping overlay. SourceRoot=$SourceRoot"
        return
    }
    if ((Resolve-Path $SourceRoot).Path -eq (Resolve-Path $DestinationRoot).Path) {
        Write-Host "Shared asset source is the destination; skipping overlay."
        return
    }

    foreach ($directory in ($DirectoryList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
        if ($directory -match '[\\/]|\.\.') {
            throw "Shared asset directory must be a simple child directory name: $directory"
        }

        $sourcePath = Join-Path $SourceRoot $directory
        $destinationPath = Join-Path $DestinationRoot $directory
        if (!(Test-Path $sourcePath)) { continue }

        Ensure-Directory -Path $destinationPath
        # /XC /XN /XO means "only files that do not exist at the destination", so
        # the branch stays authoritative for everything it actually ships. See the
        # long note in Deploy-PrEnvironment.ps1 -- this was /MIR and it silently
        # reverted every theme change a branch made.
        & robocopy $sourcePath $destinationPath /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -gt 7) {
            throw "robocopy failed for shared asset directory $directory with exit code $exitCode."
        }
    }
}

function Write-RuntimeConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PublicRoot,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Connection
    )

    Ensure-Directory -Path (Join-Path $Path "App_Data")

    if (![string]::IsNullOrWhiteSpace($Connection)) {
        $connectionStringConfig = @"
<!-- Rock RMS $EnvironmentName connection strings. Generated by Deploy-RockEnvironment.ps1. -->
<connectionStrings>
  <add name="RockContext" connectionString="$Connection" providerName="System.Data.SqlClient" />
</connectionStrings>
"@
        $connectionStringConfig | Out-File -FilePath (Join-Path $Path "web.ConnectionStrings.config") -Encoding UTF8 -Force
    }
    else {
        # Production deliberately omits the connection string so CI never touches
        # the one already on that box. That is only safe when the file is actually
        # there. web.config binds connectionStrings through a configSource, so a
        # missing file is not a degraded site -- it is a site that cannot serve a
        # single request, error page included. Fail here, where the cause is
        # obvious, instead of 300 seconds later as an unexplained health-check
        # timeout.
        $existingConnectionConfig = Join-Path $Path "web.ConnectionStrings.config"
        if (Test-Path $existingConnectionConfig) {
            Write-Host "No connection string supplied; leaving the existing web.ConnectionStrings.config in place."
        }
        else {
            throw "No connection string was supplied and $existingConnectionConfig does not exist. web.config binds connectionStrings with a configSource, so the site would fail every request at startup. Re-run with write_connection_string enabled, or restore that file on the server."
        }
    }

    $webConfigPath = Join-Path $Path "web.config"
    if (Test-Path $webConfigPath) {
        $webConfig = Get-Content $webConfigPath -Raw
        $webConfig = $webConfig -replace '(<attributeValue\s+attributeKey="PublicApplicationRoot"[^>]*value=")"', "`${1}$PublicRoot`""
        $webConfig | Out-File -FilePath $webConfigPath -Encoding UTF8 -Force
    }
}

function Test-EnvironmentHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    # Rock runs EF and plugin migrations on first request, so the first hit after
    # a deploy can take minutes. Poll until it answers rather than declaring the
    # deploy broken because the site is still warming up.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = 'no attempt made'
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 60
            if ([int]$response.StatusCode -lt 400) {
                Write-Host "Health check passed: $Url returned $($response.StatusCode)."
                return $true
            }
            $lastError = "HTTP $($response.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 10
    }

    Write-Warning "Health check did not pass within $TimeoutSeconds seconds. Last error: $lastError"
    return $false
}

$MutexName = "Global\RockEnvironment-$EnvironmentName"
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$HasLock = $false

try {
    $HasLock = $Mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if (!$HasLock) {
        throw "Timed out waiting for deployment lock $MutexName."
    }

    Ensure-Directory -Path $EnvironmentRoot
    Ensure-Directory -Path $EnvironmentPath

    Write-Host "=== Rock environment deploy ==="
    Write-Host "  environment : $EnvironmentName"
    Write-Host "  mode        : $Mode"
    Write-Host "  sha         : $Sha"
    Write-Host "  artifact    : $ArtifactGcsPath"
    Write-Host "  host        : $HostName"
    Write-Host "  site path   : $SitePath"
    Write-Host "  iis site    : $SiteName (app pool $AppPoolName)"

    if ($Mode -eq 'InPlace' -and -not $Apply) {
        Write-Host ""
        Write-Host "DRY RUN -- no changes will be made. Re-run with -Apply to deploy."
        Write-Host "Would back up $SitePath to $(Join-Path (Join-Path $BackupRoot $EnvironmentName) '<timestamp>')."
        Write-Host "Would stop app pool '$AppPoolName', copy the artifact over $SitePath, then restart it."
        Write-Host "Would preserve directories: $($PreservedDirectories -join ', ')"
        Write-Host "Would preserve files: $($PreservedFiles -join ', ')"
        Write-Host "Would health check https://$HostName/ for up to $HealthCheckTimeoutSeconds seconds."
        return
    }

    if (Test-Path $ArtifactPath) { Remove-Item $ArtifactPath -Force }
    Copy-GcsObjectToFile -GcsUri $ArtifactGcsPath -DestinationPath $ArtifactPath

    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
    Ensure-Directory -Path $ExtractPath
    Expand-Archive -Path $ArtifactPath -DestinationPath $ExtractPath -Force
    Remove-PluginBuildArtifacts -Path $ExtractPath

    Stop-EnvironmentAppPool -Name $AppPoolName

    if ($Mode -eq 'DedicatedSite') {
        # A dedicated site owns its whole directory, so replace it wholesale and
        # let the shared-asset overlay backfill server-only files afterwards.
        #
        # $PreservedFiles has to be carried across that replace by hand. The
        # InPlace branch below hands the list to robocopy as /XF exclusions, but
        # there is no copy to exclude anything from here -- the directory is
        # deleted outright. Skipping this is how a deploy that supplies no
        # connection string destroys the site: the wipe takes
        # web.ConnectionStrings.config with it, Write-RuntimeConfiguration
        # declines to write a replacement it was not given and reports that it is
        # "leaving the existing" file in place, and web.config is left pointing a
        # configSource at a file that no longer exists. Every request then 500s
        # before Rock starts, including the error page.
        $preservedStash = @{}
        foreach ($file in $PreservedFiles) {
            $existing = Join-Path $SitePath $file
            if (Test-Path $existing) {
                $preservedStash[$file] = Get-Content -Raw -Path $existing
            }
        }

        if (Test-Path $SitePath) { Remove-Item $SitePath -Recurse -Force }
        Move-Item -Path $ExtractPath -Destination $SitePath

        foreach ($file in $preservedStash.Keys) {
            $restoreTo = Join-Path $SitePath $file
            # Only fill a gap. The artifact shipping its own copy means the branch
            # is authoritative for that file, exactly as in the InPlace path.
            if (!(Test-Path $restoreTo)) {
                Ensure-Directory -Path (Split-Path -Parent $restoreTo)
                $preservedStash[$file] | Out-File -FilePath $restoreTo -Encoding UTF8 -Force -NoNewline
                Write-Host "Preserved $file across the site replace."
            }
        }

        $sharedAssetSource = ''
        if (![string]::IsNullOrWhiteSpace($SharedAssetSourcePath)) {
            $sharedAssetSource = [Environment]::ExpandEnvironmentVariables($SharedAssetSourcePath)
        }
        else {
            $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
            if ($null -ne $defaultSite -and ![string]::IsNullOrWhiteSpace($defaultSite.physicalPath)) {
                $sharedAssetSource = [Environment]::ExpandEnvironmentVariables($defaultSite.physicalPath)
            }
        }

        Sync-SharedSiteAssets `
            -SourceRoot $sharedAssetSource `
            -DestinationRoot $SitePath `
            -DirectoryList $SharedAssetDirectories

        Write-RuntimeConfiguration -Path $SitePath -PublicRoot "https://$HostName" -Connection $ConnectionString
        Ensure-AppPool -Name $AppPoolName
        Ensure-Website -Name $SiteName -PhysicalPath $SitePath -HostHeader $HostName -PoolName $AppPoolName -Thumbprint $CertificateThumbprint
    }
    else {
        $backupPath = Join-Path (Join-Path $BackupRoot $EnvironmentName) ((Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-$Sha")
        Ensure-Directory -Path $backupPath
        Write-Host "Backing up $SitePath to $backupPath (excluding preserved user data)."

        # Back up what the deploy can actually damage: build output and config.
        # Uploaded Content is excluded because it is not being touched and copying
        # it would multiply the site's disk usage on every deploy.
        $backupExclusions = @()
        foreach ($directory in $PreservedDirectories) {
            $backupExclusions += '/XD'
            $backupExclusions += (Join-Path $SitePath $directory)
        }
        & robocopy $SitePath $backupPath /E @backupExclusions /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
        $backupExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($backupExit -gt 7) {
            throw "Backup failed with robocopy exit code $backupExit; refusing to deploy."
        }
        Write-Host "Backup complete."

        # Copy the artifact over the live site. No /MIR and no /PURGE: files the
        # server legitimately owns must survive, and a purge here would delete
        # uploaded content and break the site permanently.
        $copyExclusions = @()
        foreach ($directory in $PreservedDirectories) {
            $copyExclusions += '/XD'
            $copyExclusions += (Join-Path $ExtractPath $directory)
        }
        foreach ($file in $PreservedFiles) {
            $copyExclusions += '/XF'
            $copyExclusions += (Join-Path $ExtractPath $file)
        }
        & robocopy $ExtractPath $SitePath /E @copyExclusions /R:3 /W:5 /NFL /NDL /NJH /NJS /NP
        $copyExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($copyExit -gt 7) {
            throw "Deploy copy failed with robocopy exit code $copyExit. The previous site files are backed up at $backupPath."
        }

        Write-RuntimeConfiguration -Path $SitePath -PublicRoot "https://$HostName" -Connection $ConnectionString
        Ensure-Directory -Path (Split-Path -Parent $ManifestPath)
    }

    $manifest = [ordered]@{
        environmentName = $EnvironmentName
        mode = $Mode
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
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $ManifestPath -Encoding UTF8 -Force

    if (Test-Path "IIS:\AppPools\$AppPoolName") { Start-WebAppPool -Name $AppPoolName -ErrorAction Continue }
    if (Test-Path "IIS:\Sites\$SiteName") { Start-Website -Name $SiteName -ErrorAction Continue }

    Write-Host "Deployed $EnvironmentName ($Sha) to https://$HostName"

    if (-not (Test-EnvironmentHealth -Url "https://$HostName/" -TimeoutSeconds $HealthCheckTimeoutSeconds)) {
        # Gather the evidence while it is still fresh, and never let a problem
        # gathering it replace the failure it was meant to explain.
        try { Save-UnhealthyDiagnostics -SiteRoot $SitePath -Url "https://$HostName/" }
        catch { Write-Warning "Could not collect diagnostics: $($_.Exception.Message)" }

        if ($Mode -eq 'InPlace') {
            throw "Deploy completed but the site did not become healthy. Roll back from $backupPath if needed."
        }
        throw "Deploy completed but https://$HostName/ did not become healthy within $HealthCheckTimeoutSeconds seconds."
    }
}
finally {
    if ($HasLock) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
}
