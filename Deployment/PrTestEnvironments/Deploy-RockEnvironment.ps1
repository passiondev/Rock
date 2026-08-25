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

# On the sixteen parameters below, and why they are still sixteen.
#
# Card 08 of the 2026-08-21 architecture review read this block as a shallow
# interface and proposed replacing it with a Target the caller names once,
# carrying only the fields belonging to its own mode. That was not taken, and the
# reason belongs here rather than in a commit message nobody will find:
#
#   PowerShell has no discriminated union to express "these four fields, but only
#   in DedicatedSite". The one runtime caller,
#   Invoke-PrEnvironmentCommandQueue.ps1, assembles a hashtable from untyped queue
#   JSON and splats it -- so a Target type would sit between an untyped hashtable
#   on one side and a flat parameter list on the other, translating without
#   checking anything. That is a layer, not a seam.
#
# What the card was actually reaching for was the mode logic, which was thirty
# lines of top-level script that nothing could call. That is now
# Resolve-DeploymentTarget, with Pester tests that call it, and it refuses the
# mode mismatch the flat list used to swallow: DedicatedSite accepted
# TargetSitePath and TargetAppPoolName and silently dropped them, so an operator
# could dispatch a deploy naming a directory, watch it report success, and get a
# different one. The depth went behind the function. The parameter list stayed
# where every caller and every runbook already expects it.

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

    # Plugins is in this list because RockWeb/Plugins/.gitignore is `*/*`: not one
    # plugin subfolder is tracked in git, so none of them ride in the build
    # artifact. Passion's login page is a plugin block at
    # Plugins/org_passion/Security/Login.ascx, so without this backfill staging
    # serves "Error Loading Block: Login" as its landing page and nobody can sign
    # in at all. Only the DedicatedSite branch below reaches the overlay, so this
    # list has no effect on an InPlace production deploy.
    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetDirectories = $(if ([string]::IsNullOrWhiteSpace($env:PR_TEST_SHARED_ASSET_DIRECTORIES)) { 'Themes,Content,Assets,Styles,Plugins' } else { $env:PR_TEST_SHARED_ASSET_DIRECTORIES }),

    # Fifteen minutes, not five. Rock runs EF and plugin migrations on the first
    # request after a deploy, and the pr-4 environment needed three 30-second
    # timeouts before it answered at all. Five minutes fits about four probes,
    # which is not enough to tell "still migrating" from "broken". This has to stay
    # under both callers' own limits or the ceiling moves somewhere less legible:
    # the queue agent allows 1800s for deploy-environment
    # (Invoke-PrEnvironmentCommandQueue.ps1) and env-deploy-command.yml allows 60
    # minutes for the whole job.
    [Parameter(Mandatory = $false)]
    [int]
    $HealthCheckTimeoutSeconds = 900,

    # Where to write the deploy timeline so that it survives the trip back to the
    # bucket. Optional, and empty by default, so a by-hand run and an older queued
    # command both still work -- they simply get the host output and nothing else,
    # which is what every run got before this existed.
    [Parameter(Mandatory = $false)]
    [string]
    $StepLogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# When this run started, captured before anything else so every step below can be
# placed against it. Script scope rather than a parameter: a deploy has exactly one
# start, and passing it around would let a caller claim a different one.
$script:DeployStartedUtc = (Get-Date).ToUniversalTime()

# The timeline's durable destination, truncated here rather than appended to: a
# redeploy on the same box must not leave the previous run's steps sitting above
# this one's. A step log that cannot be created is downgraded to no step log at
# all, never to a failed deploy.
$script:DeployStepLogPath = $StepLogPath
if (-not [string]::IsNullOrWhiteSpace($script:DeployStepLogPath)) {
    try {
        $stepLogDirectory = Split-Path -Path $script:DeployStepLogPath -Parent
        if ($stepLogDirectory -and -not (Test-Path $stepLogDirectory)) {
            New-Item -ItemType Directory -Path $stepLogDirectory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($script:DeployStepLogPath, '')
    }
    catch {
        Write-Warning "Could not create the step log at $($script:DeployStepLogPath): $($_.Exception.Message)"
        $script:DeployStepLogPath = $null
    }
}

function Write-DeployStep {
    <#
        .SYNOPSIS
        One line of the deploy timeline: absolute UTC, elapsed, and what happened.

        .DESCRIPTION
        The agent uploads this script's output as the deploy's only durable record.
        Every deploy-staging-* object in the bucket is 435 bytes, which is the
        header and nothing else -- the script printed its parameters and then went
        quiet for the eleven minutes that mattered.

        Absolute UTC because the reader is correlating against GCS object times, a
        Cloud SQL restore point and an IIS log, none of which are in local time.
        Elapsed alongside it because "which step took nine minutes" is the question
        actually being asked, and subtracting timestamps by hand at 2am is how the
        wrong step gets blamed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    $now = (Get-Date).ToUniversalTime()
    $elapsed = $now - $script:DeployStartedUtc
    $line = "[{0}Z +{1:hh\:mm\:ss}] {2}" -f $now.ToString("s"), $elapsed, $Message
    Write-Host $line

    # And to disk, because the host line is not durable. Measured on the staging
    # rehearsal of 2026-08-25: a deploy that ran 15m24s and succeeded uploaded a
    # 916-byte log that stops at "Stopping app pool", the moment the site goes
    # offline. Every later step ran -- success requires reaching the end of the
    # script -- and was lost between the background job and the bucket. A file on
    # the box is ordinary I/O and does not depend on the job stream surviving.
    #
    # Wrapped because by the time most of these lines are written the app pool is
    # already stopped. A log that cannot be written is not a reason to abandon a
    # deploy half-way through a cutover.
    if (-not [string]::IsNullOrWhiteSpace($script:DeployStepLogPath)) {
        try {
            Add-Content -Path $script:DeployStepLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not append to the step log at $($script:DeployStepLogPath): $($_.Exception.Message)"
        }
    }
}

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

# Which site this deploy acts on. A function rather than thirty lines of
# top-level script because two of its outcomes are unrecoverable if wrong --
# overwriting the wrong live directory, and putting a production manifest where
# the certificate renewal job will find it -- and nothing could call it to check.
# Tests/PrTestEnvironments/Pester/DeploymentTarget.Tests.ps1 now can.
function Resolve-DeploymentTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DedicatedSite', 'InPlace')]
        [string]
        $Mode,

        [Parameter(Mandatory = $true)]
        [string]
        $EnvironmentName,

        # Where the deploy does its work -- the artifact download and the extract
        # -- in both modes. Only DedicatedSite also serves the site from it.
        [Parameter(Mandatory = $true)]
        [string]
        $EnvironmentPath,

        [Parameter(Mandatory = $false)]
        [string]
        $TargetSitePath,

        [Parameter(Mandatory = $false)]
        [string]
        $TargetSiteName = 'Default Web Site',

        [Parameter(Mandatory = $false)]
        [string]
        $TargetAppPoolName,

        [Parameter(Mandatory = $false)]
        [string]
        $BackupRoot = "C:\RockBackups"
    )

    if ($Mode -eq 'DedicatedSite') {
        # These used to be accepted and silently dropped. env-deploy-command.yml
        # forwards targetSitePath and targetSiteName whenever the workflow input
        # is non-empty and never checks them against the mode, so an operator
        # could ask for one directory, watch the deploy report success, and get
        # another.
        #
        # Only the two parameters with no default can be checked from in here.
        # TargetSiteName and BackupRoot always arrive populated, which makes
        # "passed" and "defaulted" indistinguishable.
        if (![string]::IsNullOrWhiteSpace($TargetSitePath)) {
            throw "TargetSitePath does not apply when Mode is DedicatedSite: a dedicated site is placed under its environment path and named after its environment. Remove it, or pass -Mode InPlace."
        }
        if (![string]::IsNullOrWhiteSpace($TargetAppPoolName)) {
            throw "TargetAppPoolName does not apply when Mode is DedicatedSite: the app pool is named after the environment. Remove it, or pass -Mode InPlace."
        }

        return @{
            SiteName     = "rock-$EnvironmentName"
            AppPoolName  = "rock-$EnvironmentName"
            SitePath     = Join-Path $EnvironmentPath "site"
            ManifestPath = Join-Path $EnvironmentPath "env.json"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TargetSitePath)) {
        throw "TargetSitePath is required when Mode is InPlace."
    }
    if (!(Test-Path $TargetSitePath)) {
        throw "TargetSitePath does not exist: $TargetSitePath"
    }

    $resolvedAppPool = if ([string]::IsNullOrWhiteSpace($TargetAppPoolName)) {
        (Get-ItemProperty "IIS:\Sites\$TargetSiteName" -Name applicationPool).Value
    } else { $TargetAppPoolName }

    return @{
        SiteName    = $TargetSiteName
        AppPoolName = $resolvedAppPool
        SitePath    = $TargetSitePath
        # Never under $EnvironmentRoot: the certificate renewal job walks that tree
        # and stops/starts every site it finds a manifest for.
        ManifestPath = Join-Path (Join-Path $BackupRoot $EnvironmentName) "env.json"
    }
}

$DeploymentTarget = Resolve-DeploymentTarget -Mode $Mode -EnvironmentName $EnvironmentName `
    -EnvironmentPath $EnvironmentPath -TargetSitePath $TargetSitePath -TargetSiteName $TargetSiteName `
    -TargetAppPoolName $TargetAppPoolName -BackupRoot $BackupRoot

$SiteName = $DeploymentTarget.SiteName
$AppPoolName = $DeploymentTarget.AppPoolName
$SitePath = $DeploymentTarget.SitePath
$ManifestPath = $DeploymentTarget.ManifestPath

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

    # Both vantage points, always, and labelled. The difference between them is the
    # whole diagnosis: loopback failing means the application is broken, loopback
    # passing while the public name fails means the application is fine and the
    # problem is DNS, the certificate binding or the route in. Recording only the
    # public one is what made an already-serving site look dead for 900 seconds.
    $lines.Add("=== Health probes ===")
    foreach ($probeCase in @(
        @{ Label = "loopback  https://127.0.0.1/ (Host: $HostName)"; Url = 'https://127.0.0.1/'; HostHeader = $HostName },
        @{ Label = "public    $Url";                                 Url = $Url;                HostHeader = '' }
    )) {
        $probe = Invoke-SiteProbe -Url $probeCase.Url -HostHeader $probeCase.HostHeader -TimeoutSeconds 30
        if ($probe.Ok) { $lines.Add("$($probeCase.Label) -> HTTP $($probe.StatusCode)") }
        elseif ($probe.StatusCode -gt 0) { $lines.Add("$($probeCase.Label) -> HTTP $($probe.StatusCode)  $($probe.Error)") }
        else { $lines.Add("$($probeCase.Label) -> FAILED  $($probe.Error)") }
    }
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
    $candidates = @(Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { ($_.DnsNameList -contains $HostHeader) -or ($_.DnsNameList -contains $domain) -or ($_.Subject -eq "CN=$domain") } |
        Where-Object { $_.NotAfter -gt (Get-Date) })

    # Rank CA-issued certificates ahead of the self-signed placeholder, and only
    # then prefer the later expiry. Sorting on NotAfter alone was a trap: the
    # placeholder below is minted for two years while a Let's Encrypt certificate
    # lasts ninety days, so the placeholder outranked every real certificate
    # forever and each deploy silently rebound the site back to it. That is why
    # certificate renewal kept reporting success and the hosts kept serving an
    # untrusted certificate. Measured 2026-08-10: pr-4 served a real Let's Encrypt
    # certificate at 16:57 UTC, was redeployed at 19:44, and was back on the
    # self-signed wildcard (expiring 2028) afterwards.
    # A self-signed certificate is its own issuer; a CA-issued one is not.
    $cert = $candidates |
        Sort-Object -Property @(
            @{ Expression = { $_.Issuer -eq $_.Subject }; Ascending = $true },
            @{ Expression = { $_.NotAfter }; Descending = $true }
        ) |
        Select-Object -First 1

    if ($null -eq $cert) {
        # A self-signed placeholder keeps the HTTPS binding valid until the
        # scheduled Let's Encrypt renewal replaces it. Kept deliberately
        # long-lived so a run of failed renewals cannot break HTTPS outright --
        # the ranking above, not a short expiry, is what lets the real
        # certificate win.
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

function Invoke-SiteProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][string]$HostHeader = '',
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60
    )

    # HttpWebRequest rather than Invoke-WebRequest for one reason: it can set the
    # Host header. .NET treats Host as restricted and Invoke-WebRequest refuses it
    # ("The 'Host' header must be modified using the appropriate property"), and
    # without it a request to 127.0.0.1 cannot match a host-named IIS binding.
    #
    # AllowAutoRedirect is off deliberately. Rock answers / with a 302 to the login
    # page and that Location is absolute -- following it would leave the loopback
    # and go straight back out to the public name this probe exists to avoid. A 302
    # already proves what is being asked: the app domain started and is routing.
    $outcome = @{ Ok = $false; StatusCode = 0; Error = '' }

    # Set here rather than only in the caller: the loopback probe is answered with
    # a certificate for the public host name, so it never matches 127.0.0.1 and
    # would fail validation on every single attempt. The diagnostics path calls
    # this too, and it has no reason to know that.
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'RockDeployHealthCheck'
        if (![string]::IsNullOrWhiteSpace($HostHeader)) { $request.Host = $HostHeader }

        $response = $request.GetResponse()
        try {
            $outcome.StatusCode = [int]$response.StatusCode
            $outcome.Ok = $outcome.StatusCode -lt 400
        }
        finally { $response.Close() }
    }
    catch [System.Net.WebException] {
        # A 4xx or 5xx arrives here as an exception carrying the response, and the
        # status on it is far more useful than the generic "remote server returned
        # an error" message wrapped around it.
        $failedResponse = $_.Exception.Response
        if ($null -ne $failedResponse) {
            try {
                $outcome.StatusCode = [int]$failedResponse.StatusCode
                $outcome.Ok = $outcome.StatusCode -lt 400
            }
            catch { }
            try { $failedResponse.Close() } catch { }
        }
        $outcome.Error = $_.Exception.Message
    }
    catch {
        $outcome.Error = $_.Exception.Message
    }

    return $outcome
}

function Test-EnvironmentHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,

        # The public host name, sent as the Host header on the loopback probe so it
        # matches this environment's IIS binding.
        [Parameter(Mandatory = $false)][string]$HostHeader = '',

        # Optional so the function still works for a caller that has no app pool to
        # recycle; when supplied it is what makes a poisoned app domain recoverable.
        [Parameter(Mandatory = $false)][string]$AppPoolName = '',
        [Parameter(Mandatory = $false)][int]$RecycleAfterSeconds = 240
    )

    # Rock runs EF and plugin migrations on first request, so the first hit after
    # a deploy can take minutes. Poll until it answers rather than declaring the
    # deploy broken because the site is still warming up.
    #
    # Retrying alone is not enough, and this cost a full evening to learn. ASP.NET
    # caches an Application_Start failure for the lifetime of the app domain: once
    # one request faults during startup, every later request is served the same
    # cached exception until the domain is recycled. A replaced site can fault its
    # first start for reasons that clear themselves -- stale compiled output under
    # Temporary ASP.NET Files being the usual one -- and then the site is fine on a
    # fresh domain while the health check sits there re-reading the cached failure
    # until the window closes. That is what happened to staging on 2026-08-10: the
    # deploy reported "did not become healthy within 300 seconds" three times over,
    # and the site was serving Rock normally minutes after each supposed failure.
    # So recycle periodically, which turns one bad domain into one lost interval.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = 'no attempt made'
    $lastRecycle = Get-Date
    $attempt = 0

    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    # PowerShell 5.1 on an older image can default to SSL3/TLS1.0, which a hardened
    # IIS refuses -- and it surfaces as "The underlying connection was closed",
    # which reads like the site is down rather than like the probe is misconfigured.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Probe the loopback, not the public name. Both are the same IIS site, the same
    # app pool and the same app domain, so the loopback answers the only question a
    # deploy can actually be blamed for -- did this build start up. What it does not
    # drag in is DNS, the external address and everything between: this VM cannot
    # reliably reach its own public IP, and on 2026-08-11 that cost 900 seconds and
    # a red build on a deploy that was already serving.
    #
    #   01:04:24  on-box GET https://staging.rock-dev.connect.passion.team/
    #             -> "The underlying connection was closed: An unexpected error
    #                occurred on a send."  (captured in the deploy's own diagnostics)
    #   01:04:24  the same URL from off-box -> HTTP 302 in 0.115s
    #
    # The site was fine for the last five minutes of a health check that never
    # passed. Reachability from the internet is a real thing to verify, but it is
    # not this probe's job and this is not the vantage point to verify it from --
    # the workflow checks the public URL from the GitHub runner, which can see it.
    $probeUrl = $Url
    $probeHostHeader = ''
    if (![string]::IsNullOrWhiteSpace($HostHeader)) {
        $probeUrl = 'https://127.0.0.1/'
        $probeHostHeader = $HostHeader
        Write-DeployStep "Health check probing $probeUrl with Host: $probeHostHeader (public URL $Url is verified from the runner, not from this box)."
    }

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $probe = Invoke-SiteProbe -Url $probeUrl -HostHeader $probeHostHeader -TimeoutSeconds 60
        if ($probe.Ok) {
            Write-DeployStep "Health check passed: $probeUrl returned $($probe.StatusCode) on attempt $attempt."
            return $true
        }
        if ($probe.StatusCode -gt 0) { $lastError = "HTTP $($probe.StatusCode)" }
        else { $lastError = $probe.Error }
        Write-DeployStep "Health check attempt ${attempt}: $lastError"

        if (![string]::IsNullOrWhiteSpace($AppPoolName) -and
            ((Get-Date) - $lastRecycle).TotalSeconds -ge $RecycleAfterSeconds -and
            (Get-Date).AddSeconds(60) -lt $deadline) {
            Write-DeployStep "Still unhealthy after $([int]((Get-Date) - $lastRecycle).TotalSeconds)s; recycling app pool $AppPoolName to discard any cached startup failure."
            try {
                Stop-EnvironmentAppPool -Name $AppPoolName
                Start-WebAppPool -Name $AppPoolName -ErrorAction Continue
            }
            catch { Write-Warning "Could not recycle ${AppPoolName}: $($_.Exception.Message)" }
            $lastRecycle = Get-Date
        }

        Start-Sleep -Seconds 10
    }

    Write-Warning "Health check did not pass within $TimeoutSeconds seconds over $attempt attempts. Last error: $lastError"
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
    Write-DeployStep "Deploy started."

    if ($Mode -eq 'InPlace' -and -not $Apply) {
        # Through Write-DeployStep rather than Write-Host, because this plan is the
        # whole point of a dry run. It is step 6 of the production runbook -- the
        # step that proves the agent is alive -- and the operator reads these lines
        # to check the backup root and the site path before ticking apply. Write-Host
        # is what the staging rehearsal proved can vanish on the way back to the
        # bucket, and a dry run whose plan went missing has proved only half of what
        # it was run for.
        Write-Host ""
        Write-DeployStep "DRY RUN -- no changes will be made. Re-run with -Apply to deploy."
        Write-DeployStep "Would back up $SitePath to $(Join-Path (Join-Path $BackupRoot $EnvironmentName) '<timestamp>')."
        Write-DeployStep "Would stop app pool '$AppPoolName', copy the artifact over $SitePath, then restart it."
        Write-DeployStep "Would preserve directories: $($PreservedDirectories -join ', ')"
        Write-DeployStep "Would preserve files: $($PreservedFiles -join ', ')"
        Write-DeployStep "Would health check https://$HostName/ for up to $HealthCheckTimeoutSeconds seconds."
        return
    }

    if (Test-Path $ArtifactPath) { Remove-Item $ArtifactPath -Force }
    Write-DeployStep "Downloading the artifact from $ArtifactGcsPath."
    Copy-GcsObjectToFile -GcsUri $ArtifactGcsPath -DestinationPath $ArtifactPath

    # The size is the cheapest check that the right thing arrived. A Rock artifact
    # is hundreds of megabytes; a truncated download or an object that turned out
    # to be an error document is obvious here and nowhere else until the site 500s.
    $artifactMegabytes = [math]::Round((Get-Item $ArtifactPath).Length / 1MB, 1)
    Write-DeployStep "Artifact downloaded ($artifactMegabytes MB)."

    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
    Ensure-Directory -Path $ExtractPath
    Expand-Archive -Path $ArtifactPath -DestinationPath $ExtractPath -Force
    Remove-PluginBuildArtifacts -Path $ExtractPath
    Write-DeployStep "Artifact extracted to $ExtractPath."

    # From here until the app pool starts again, the site is down. Both ends of
    # that window are stamped so the outage can be measured after the fact rather
    # than estimated from when somebody noticed.
    Write-DeployStep "Stopping app pool $AppPoolName. The site is offline from here."
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

        # Move-Item within a volume is a rename, so the tree keeps the ACLs it
        # inherited at $ExtractPath and never picks up inheritance from the site
        # root's parent. Nothing else here grants anything, so the app pool
        # identity lands with read access and no write access -- and Rock needs
        # write access, because it compiles the legacy LESS themes to .css on a
        # background thread at every application start.
        #
        # The failure is close to invisible, which is why this went unnoticed from
        # January to August 2026. RockTheme.Compile writes each theme's files in
        # directory order, so it dies on bootstrap.css -- the first one -- with
        # UnauthorizedAccessException, and its catch abandons that theme's whole
        # loop before ever reaching theme.css. The exception is logged to
        # ExceptionLog and nowhere else: Global.asax only surfaces compile
        # messages through Debug.WriteLine guarded by IsDevelopmentEnvironment.
        # The stale .css keeps being served with a 200, so every health check
        # passes while every theme silently rots.
        #
        # InPlace deploys robocopy into a directory that already exists and so
        # inherit its ACLs -- which is the only reason production was unaffected.
        # This branch is the one that needs the grant.
        #
        # (OI)(CI) makes the ACE inheritable, so NTFS propagates it to the
        # existing children and to whatever the preserved-file restore and the
        # shared-asset overlay write afterwards. No /T: it would walk the whole
        # site for no gain, as Expand-Archive leaves inheritance enabled.
        $appPoolIdentity = "IIS AppPool\$AppPoolName"
        & icacls $SitePath /grant "${appPoolIdentity}:(OI)(CI)(M)" /Q | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not grant $appPoolIdentity modify rights on $SitePath (icacls exit code $LASTEXITCODE). Rock cannot compile its themes without it."
        }
        Write-Host "Granted $appPoolIdentity modify rights on $SitePath."

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

        # Again, after the overlay. The strip above ran on the extracted artifact;
        # the overlay has since backfilled Plugins from the base site and brought
        # that site's own bin/obj along with it.
        Remove-PluginBuildArtifacts -Path $SitePath

        Write-RuntimeConfiguration -Path $SitePath -PublicRoot "https://$HostName" -Connection $ConnectionString
        Ensure-AppPool -Name $AppPoolName
        Ensure-Website -Name $SiteName -PhysicalPath $SitePath -HostHeader $HostName -PoolName $AppPoolName -Thumbprint $CertificateThumbprint
    }
    else {
        $backupPath = Join-Path (Join-Path $BackupRoot $EnvironmentName) ((Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-$Sha")
        Ensure-Directory -Path $backupPath
        Write-DeployStep "Backing up $SitePath to $backupPath (excluding preserved user data)."

        # Back up what the deploy can actually damage: build output and config.
        # Uploaded Content is excluded because it is not being touched and copying
        # it would multiply the site's disk usage on every deploy.
        $backupExclusions = @()
        foreach ($directory in $PreservedDirectories) {
            $backupExclusions += '/XD'
            $backupExclusions += (Join-Path $SitePath $directory)
        }
        & robocopy $SitePath $backupPath /E @backupExclusions /R:2 /W:2 /NFL /NDL /NP
        $backupExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($backupExit -gt 7) {
            throw "Backup failed with robocopy exit code $backupExit; refusing to deploy."
        }
        Write-DeployStep "Backup complete."

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
        Write-DeployStep "Copying the artifact over $SitePath."
        & robocopy $ExtractPath $SitePath /E @copyExclusions /R:3 /W:5 /NFL /NDL /NP
        $copyExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($copyExit -gt 7) {
            throw "Deploy copy failed with robocopy exit code $copyExit. The previous site files are backed up at $backupPath."
        }

        Write-DeployStep "Copy complete."
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

    Write-DeployStep "Starting app pool $AppPoolName and site $SiteName."
    if (Test-Path "IIS:\AppPools\$AppPoolName") { Start-WebAppPool -Name $AppPoolName -ErrorAction Continue }
    if (Test-Path "IIS:\Sites\$SiteName") { Start-Website -Name $SiteName -ErrorAction Continue }

    Write-DeployStep "Deployed $EnvironmentName ($Sha) to https://$HostName"

    if (-not (Test-EnvironmentHealth -Url "https://$HostName/" -TimeoutSeconds $HealthCheckTimeoutSeconds -HostHeader $HostName -AppPoolName $AppPoolName)) {
        # Gather the evidence while it is still fresh, and never let a problem
        # gathering it replace the failure it was meant to explain.
        try { Save-UnhealthyDiagnostics -SiteRoot $SitePath -Url "https://$HostName/" }
        catch { Write-Warning "Could not collect diagnostics: $($_.Exception.Message)" }

        if ($Mode -eq 'InPlace') {
            throw "Deploy completed but the site did not become healthy. Roll back from $backupPath if needed."
        }
        throw "Deploy completed but https://$HostName/ did not become healthy within $HealthCheckTimeoutSeconds seconds."
    }

    # Repeated at the end on purpose. It was printed once, before the copy, and by
    # now it is thousands of characters up a log somebody is reading because
    # something went wrong. $backupPath only exists on the InPlace branch -- a
    # dedicated site is replaced wholesale and has nothing to roll back to -- and
    # Set-StrictMode makes reading it anywhere else a terminating error.
    if ($Mode -eq 'InPlace') {
        Write-DeployStep "Done. Roll back with: robocopy $backupPath $SitePath /E"
    }
    else {
        Write-DeployStep "Done."
    }
}
finally {
    if ($HasLock) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
}
