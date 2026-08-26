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
    # bin is in this list for the same reason as Plugins, one layer down. The
    # plugin *source* under Plugins/ is useless without the compiled assemblies
    # that define its namespaces, and those live only in the base site's bin --
    # never in git, never in the artifact. Every BinaryFileType on this catalog
    # stores through rocks.pillars.AmazonStorageProvider.S3BlobStorage, so when
    # that assembly is missing the storage provider cannot load, BinaryFile
    # content resolves to null, and GetImage.ashx answers 404 for every image on
    # the site -- profile photos, logos, content channel images, all of it. The
    # tell that it is this and not missing data is that the 404 still carries
    # Last-Modified and ETag: GetImage.ashx sets those before the content lookup,
    # so headers-present means the row was found and only the bytes were not.
    # The matching compile error lands in ExceptionLog as
    # "The name 'rocks' does not exist in the current context".
    #
    # Sync-SharedSiteAssets runs robocopy /XC /XN /XO, which excludes Changed,
    # Newer and Older and so copies only files that are absent at the
    # destination. It therefore cannot overwrite a v19 assembly with the base
    # site's older one; it can only fill gaps. That property is what makes
    # overlaying bin safe at all, and it is why the exclusions must stay.
    [Parameter(Mandatory = $false)]
    [string]
    $SharedAssetDirectories = $(if ([string]::IsNullOrWhiteSpace($env:PR_TEST_SHARED_ASSET_DIRECTORIES)) { 'Themes,Content,Assets,Styles,Plugins,bin' } else { $env:PR_TEST_SHARED_ASSET_DIRECTORIES }),

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

# Not a copy of the queue-name rule, despite the identical pattern. This name
# becomes an IIS site name, an app pool name and a directory under the deploy
# root, and the shapes coincide today. They are free to diverge, so neither
# should be changed on the strength of the other looking the same.
#
# -cnotmatch for the reason recorded in Invoke-PrEnvironmentCommandQueue.ps1:
# the default operator is case-insensitive, so a lowercase-only pattern was
# accepting 'PR-1234' and creating a directory that no later lookup would find.
if ($EnvironmentName -cnotmatch '^[a-z][a-z0-9-]{1,30}$') {
    throw "EnvironmentName must be lowercase letters, digits and hyphens, starting with a letter: '$EnvironmentName'."
}

# Directories the artifact must never overwrite or delete. Content and uploaded
# files live only on the server -- they are user data, not build output. App_Data
# holds the Rock cache and the migration lock. Logs are forensic evidence.
#
# This binds on the InPlace branch only, and the asymmetry is deliberate rather
# than an oversight. InPlace copies the artifact over a live webroot, so it hands
# this list to robocopy as /XD exclusions for both the backup and the copy and
# the directories are never touched. DedicatedSite deletes $SitePath outright and
# moves the extracted artifact into its place, so nothing named here survives a
# staging or pr-* deploy. Only $PreservedFiles is carried across that replace, by
# hand, through $preservedStash.
#
# What makes that acceptable is where the data actually lives. Every binary file
# in this install is in S3 through the pillars storage provider, so Content and
# Uploads on a dedicated site hold nothing the bucket does not also hold, and
# App_Data is a cache Rock rebuilds at startup. Logs is the one with a real cost:
# a staging deploy destroys the evidence of whatever went wrong on the previous
# one, which matters when a deploy is being run to chase a fault rather than to
# ship. Anyone who needs those logs must copy them off the box first.
$PreservedDirectories = @('Content', 'App_Data', 'Logs', 'Uploads')

# Files that are per-server configuration, not build output.
$PreservedFiles = @('web.ConnectionStrings.config')

# Directories the server owns and the branch does not, even though the artifact
# ships its own copy of them. The artifact's copy is the wrong one and must lose.
#
# Font Awesome is the case that forced this. Passion holds a Pro licence and the
# Pro webfonts sit on both boxes, but upstream Rock ships the Free fonts under
# the same filenames, so the artifact always carries a Free
# fa-solid-900.woff2 (78 KB against Pro's 137 KB) and a Free fa-regular-400.woff2
# (13 KB against Pro's 169 KB). Free covers about 1,600 glyphs where Pro covers
# more than 16,000, so every Pro-only icon on a page falls back to an empty box.
# The fonts cannot be committed instead: this repository is a public fork of
# SparkDevNetwork/Rock, and publishing licensed commercial font binaries to it
# would breach the licence and be unrecoverable once pushed.
#
# fa-light-300.woff2 is the tell that the plain overlay cannot solve this on its
# own. Free has no Light weight, so no Light file rides in the artifact, the gap
# is real, and Sync-SharedSiteAssets fills it -- Light matches production byte
# for byte today. Solid and Regular are already present at the destination when
# the overlay runs, and /XC /XN /XO means it skips anything already there. Only
# an authoritative copy can replace them.
#
# Both deployment modes need this and they need opposite mechanisms, which is why
# the list lives here rather than inside either branch:
#
#   DedicatedSite  Sync-ServerOwnedAssets copies these from the base site after
#                  the gap-filling overlay, with no /XC /XN /XO, so the box wins.
#   InPlace        the same paths become robocopy /XD exclusions, so the artifact
#                  never reaches them and production keeps what it already has.
#
# Production has never had an automated deploy -- its fa-solid-900.woff2 is dated
# 2021-08-04 and its _variables.less 2023-04-10 -- so the v19 cutover is the first
# run that could overwrite these, and without the exclusion it would.
#
# Forward slashes: Join-Path handles them on Windows, and they read as paths
# rather than as escapes.
$ServerOwnedDirectories = @('Assets/Fonts/FontAwesome')

# The same problem one level down: files the organisation owns that sit inside
# directories the artifact owns. These two are server-owned for a reason that has
# nothing to do with this pipeline -- Rock writes them itself. The Theme Styler
# block saves both with File.WriteAllText (RockWeb/Blocks/Cms/ThemeStyler.ascx.cs,
# lines 134 and 249), so they hold whatever an administrator last did in Admin
# Tools. A file the running application writes cannot also be owned by the
# artifact, or every deploy silently reverts an administrator's work. Content and
# Uploads are on the preserved list for the same reason.
#
# Measured against production on 2026-08-26: eight of these files across five
# themes differ from what the artifact ships -- Rock, Stark, LandingPage,
# CheckinElectric and DashboardStark. They carry the brand palette
# (@brand-color: #00b8e4, the link colours, @brand-critical), the Pro Font
# Awesome wiring, and hand-written CSS fixes. Only Themes/Rock/Styles/
# _variable-overrides.less matches the repository, because at some point someone
# copied that one file into the fork. The other seven exist only on the box.
#
# Both modes lost them, in opposite directions:
#
#   InPlace        robocopy /E copies whenever source and destination differ, and
#                  nothing excluded these, so the v19 cutover would have replaced
#                  all eight with upstream's empty pair.
#   DedicatedSite  the overlay runs /XC /XN /XO and skips anything the artifact
#                  already placed, so it never delivered them. That is why staging
#                  renders in stock Rock blue, and why its Stark login page -- the
#                  first screen anyone sees -- does not match production either.
#
# This also decides whether the Font Awesome exclusion above achieves anything.
# Restoring the Pro .woff2 binaries is half the job: the compiled CSS only asks
# for the Pro faces because _variable-overrides.less sets @fa-edition and calls
# .fa-font-face for the regular and light weights. Lose the override and the Pro
# fonts sit on disk unreferenced.
#
# The cost of this, stated plainly: the box is now authoritative for these eight
# files, so editing one in the repository will not change production. Change them
# through Admin Tools > CMS > Themes, which is what writes them. The repository's
# copy of Themes/Rock/Styles/_variable-overrides.less is a snapshot, not the
# delivery path.
#
# Which themes have these files is read off the box rather than listed here.
# Get-ServerOwnedThemeFilePaths only returns paths that exist, so a theme v19
# adds and the box has never seen still gets its file from the artifact -- and it
# needs to, because theme.less imports the file unconditionally and a theme
# missing it does not compile at all.
$ServerOwnedThemeFiles = @('_variable-overrides.less', '_css-overrides.less')

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
    <#
    .SYNOPSIS
        Create the app pool if it is missing, and hold it at Rock's production settings.

    .DESCRIPTION
        Creation and identity only. The settings that keep the site warm live in
        Set-WarmSiteSettings, because production reaches those and does not reach
        this: an InPlace deploy updates a site somebody else built and must not
        restate its identity.

        Deploy-PrEnvironment.ps1 carries its own Ensure-AppPool for the PR fleet
        and is deliberately left alone. It gets no warm settings either --
        idleTimeout of zero across a dozen PR pools would hold every one of them
        resident on the 32GB box that hosts them all at once, which is not the
        trade one staging pool is.

    .PARAMETER Name
        The application pool to create or reconfigure.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    if (!(Test-Path "IIS:\AppPools\$Name")) {
        New-WebAppPool -Name $Name | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.identityType -Value "ApplicationPoolIdentity"
}

function Set-WarmSiteSettings {
    <#
    .SYNOPSIS
        Stop IIS from putting the site to sleep, and have it start Rock unprompted.

    .DESCRIPTION
        Until 2026-08-26 the deploy set an app pool's runtime version and identity
        and left every other IIS default standing. Those defaults suit a shared host
        running many small sites. Rock is the opposite shape: one application that
        spends a minute and a half rebuilding its caches before it can answer, and
        then answers in a quarter of a second.

        Staging measured 16.07s for a first request and 0.25s for the next one that
        day. Nothing about the machine changed between those two numbers. IIS had
        ended the worker process after twenty idle minutes and the first visitor
        paid for a whole Rock start.

        Separate from Ensure-AppPool because production reaches this and does not
        reach that. An InPlace deploy updates a site somebody else built, so it has
        no business restating that site's identity or rebinding it -- but the pool
        can still be told not to sleep. Splitting the two is what lets the warm
        settings apply in both modes.

        Every property here is written every deploy rather than checked first. The
        settings are the deploy's to own, and a pool somebody adjusted by hand in
        the IIS console should come back to this on the next run.

    .PARAMETER AppPoolName
        The pool to hold resident. Must already exist.

    .PARAMETER SiteName
        The site to preload. Optional: pass nothing to configure the pool alone.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppPoolName,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SiteName = ''
    )

    if (!(Test-Path "IIS:\AppPools\$AppPoolName")) {
        Write-Warning "No app pool named '$AppPoolName', so it was left unconfigured. The site will start cold after every idle period."
        return
    }

    # idleTimeout defaults to 20 minutes: no requests for twenty minutes and IIS
    # ends the worker process, so the next person through the door pays a full Rock
    # start. On a staff intranet that is every morning and most lunchtimes.
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)

    # With no idle shutdown, something still has to start the pool after a reboot
    # or a recycle. AlwaysRunning has WAS start it immediately instead of leaving
    # the cost for whoever browses to the site first.
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode -Value "AlwaysRunning"

    # startupTimeLimit defaults to 90 seconds and a cold Rock start was measured at
    # 95-107s. Left at the default, IIS can end the very startup AlwaysRunning just
    # asked for, and it reports that as a process that failed to start rather than
    # as a timeout.
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.startupTimeLimit -Value ([TimeSpan]::FromMinutes(5))

    # The stock recycle is a rolling 29-hour timer counted from the last start, so
    # the daily restart walks around the clock and eventually lands in the middle of
    # a Sunday service. Zero turns the rolling timer off; the schedule below puts a
    # fixed time in its place.
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)

    # 04:00 and not 03:00, because Rock warns that a restart inside the hour
    # daylight saving repeats can run a scheduled job twice.
    #
    # Cleared first because this is a collection and not a value. New-ItemProperty
    # appends, so without the clear every deploy would add another 04:00 entry --
    # harmless to IIS, and baffling to whoever opens Advanced Settings next.
    Clear-ItemProperty "IIS:\AppPools\$AppPoolName" -Name recycling.periodicRestart.schedule
    New-ItemProperty "IIS:\AppPools\$AppPoolName" -Name recycling.periodicRestart.schedule -Value @{ value = "04:00:00" } | Out-Null

    if ([string]::IsNullOrWhiteSpace($SiteName)) {
        return
    }

    # AlwaysRunning starts the worker process. It does not start Rock. The process
    # comes up idle and the application stays cold until a request arrives, so
    # preload is the half that matters: IIS sends the site a request of its own and
    # Rock runs Application_Start with nobody waiting on it.
    #
    # Wrapped because preloadEnabled needs the Application Initialization role
    # feature, which is installed on both Rock boxes today. A rebuilt VM that came
    # up without it should serve a slow first request, not fail the deploy.
    try {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationDefaults.preloadEnabled -Value $true
    }
    catch {
        Write-Warning "Could not enable preload on $SiteName, so the site will start cold on the first request after a recycle: $($_.Exception.Message)"
    }
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

        # Counted either side of the copy because robocopy is told to say nothing
        # (/NFL /NDL /NJH /NJS), so without this the overlay is invisible in the
        # log and "did the base site actually have anything to give us" cannot be
        # answered after the fact. It is the only read-back this deploy has: the
        # VM has no reachable sshd, and nothing else reports on the box's state.
        $filesBefore = @(Get-ChildItem -Path $destinationPath -Recurse -File -ErrorAction SilentlyContinue).Count

        # /XC /XN /XO means "only files that do not exist at the destination", so
        # the branch stays authoritative for everything it actually ships. See the
        # long note in Deploy-PrEnvironment.ps1 -- this was /MIR and it silently
        # reverted every theme change a branch made.
        & robocopy $sourcePath $destinationPath /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -gt 7) {
            throw "robocopy failed for shared asset directory $directory with exit code $exitCode."
        }

        $filesAfter = @(Get-ChildItem -Path $destinationPath -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-DeployStep "Overlay $directory backfilled $($filesAfter - $filesBefore) file(s) from the base site ($filesBefore -> $filesAfter)."
    }
}

function ConvertTo-NativePath {
    <#
    .SYNOPSIS
        A site-relative path with its separators in the shape this platform uses.

    .DESCRIPTION
        The server-owned lists are written with forward slashes so one string can
        serve both Test-Path and robocopy. Join-Path only normalises the seam it
        creates, so joining 'C:\extract' to 'Themes/Rock/Styles/x.less' leaves
        'C:\extract\Themes/Rock/Styles/x.less' -- mixed, and handed to robocopy
        as an /XF or /XD argument.

        Windows resolves mixed separators when it opens a file, so the copy source
        would still be found. Exclusion matching is the part that is not worth
        assuming: a /XF that quietly fails to match copies the artifact's stock
        file over production's during the cutover, and robocopy reports success
        either way. Normalising costs one call and removes the question.

        String.Replace rather than -replace, and the reason is worth recording.
        The regex form needs the separator escaped to survive the pattern, and
        Regex::Escape on a backslash returns two characters -- which a
        replacement string takes literally, so every separator comes back
        doubled. That is a worse path than the mixed one this exists to fix. A
        plain character replace has no such trap.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,

        # Injectable, and not for flexibility -- no caller passes it. It is here
        # so the behaviour that only happens on Windows can be tested off it.
        # This script runs on Windows and nowhere else, but its tests run on the
        # developer's machine and on a Linux runner, where DirectorySeparatorChar
        # is '/' and every backslash-specific bug is invisible. The first version
        # of this function was broken on Windows and passed its tests on macOS
        # for exactly that reason.
        [Parameter(Mandatory = $false)]
        [char]$Separator = [System.IO.Path]::DirectorySeparatorChar
    )

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    # Both directions, so the result is native whichever way the input was
    # written. One of the two is always a no-op on any given platform.
    return $Path.Replace([char]'/', $Separator).Replace([char]'\', $Separator)
}

function Get-ServerOwnedThemeFilePaths {
    <#
    .SYNOPSIS
        Site-relative paths of the per-organisation theme files that exist under
        a given site root.

    .DESCRIPTION
        Discovery rather than a hard-coded list, because the answer differs by
        box and by Rock version. Only paths that exist are returned, which is
        what makes this safe to use as a robocopy exclusion: a theme the artifact
        introduces and the server has never had is not excluded, so its file
        arrives from the artifact instead of going missing.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SiteRoot,
        # AllowEmptyString as well as AllowEmptyCollection, so the blank-name
        # guard below is reachable. Without it the binder rejects a blank element
        # before the function runs and the guard is unreachable code.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$FileNames
    )

    $found = @()
    if ([string]::IsNullOrWhiteSpace($SiteRoot) -or !(Test-Path $SiteRoot)) { return $found }

    $themesRoot = Join-Path $SiteRoot 'Themes'
    if (!(Test-Path $themesRoot)) { return $found }

    foreach ($theme in (Get-ChildItem -Path $themesRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($fileName in $FileNames) {
            if ([string]::IsNullOrWhiteSpace($fileName)) { continue }
            $candidate = Join-Path (Join-Path $theme.FullName 'Styles') $fileName
            if (Test-Path $candidate) {
                # Forward slashes to match $ServerOwnedDirectories, which the
                # callers concatenate this with and pass to the same functions.
                $found += "Themes/$($theme.Name)/Styles/$fileName"
            }
        }
    }

    return $found
}

function Sync-ServerOwnedAssets {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RelativePaths
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or !(Test-Path $SourceRoot)) {
        Write-Host "Server-owned asset source not found; skipping. SourceRoot=$SourceRoot"
        return
    }
    if ((Resolve-Path $SourceRoot).Path -eq (Resolve-Path $DestinationRoot).Path) {
        Write-Host "Server-owned asset source is the destination; skipping."
        return
    }

    foreach ($relativePath in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }

        # Nested paths are allowed here, unlike the shared-asset overlay, because
        # this list names specific directories rather than top-level ones. What is
        # still refused is anything that could climb out of the site: '..' in any
        # segment, a rooted path, or a drive letter. This copy overwrites, so a
        # path that escaped would overwrite outside the site.
        if ($relativePath -match '(^|[\\/])\.\.([\\/]|$)' -or [System.IO.Path]::IsPathRooted($relativePath)) {
            throw "Server-owned path must be relative to the site root and must not contain '..': $relativePath"
        }

        $sourcePath = Join-Path $SourceRoot $relativePath
        $destinationPath = Join-Path $DestinationRoot $relativePath
        if (!(Test-Path $sourcePath)) {
            Write-DeployStep "Server-owned path $relativePath is absent from the base site; leaving the artifact's copy in place."
            continue
        }

        # A path may name a file rather than a directory -- the theme override
        # files are single files inside directories the artifact owns. robocopy
        # takes two directories and an optional file filter, so a file is copied
        # by pointing it at the parent and naming the leaf. Ensure-Directory has
        # to follow the same split, or a file path would create a directory with
        # the file's name and the copy would land inside it.
        $sourceIsFile = Test-Path -Path $sourcePath -PathType Leaf
        if ($sourceIsFile) {
            $copyFrom = Split-Path -Parent $sourcePath
            $copyTo = Split-Path -Parent $destinationPath
            $copyFilter = @(Split-Path -Leaf $sourcePath)
        }
        else {
            $copyFrom = $sourcePath
            $copyTo = $destinationPath
            $copyFilter = @()
        }

        Ensure-Directory -Path $copyTo

        # No /XC /XN /XO, which is the whole point: the shared-asset overlay ran
        # first and skipped every one of these because the artifact had already
        # put a file there. This pass replaces them. Still no /MIR and no /PURGE
        # -- the base site is authoritative for the files it has, not for the
        # absence of files it does not have, so a weight the artifact ships and
        # the box lacks survives.
        #
        # /E only when copying a directory. Recursing from a parent directory
        # with a filename filter would rake that filter across every theme under
        # it, and each path in the list is meant to move exactly one file.
        #
        # [string[]] on both, and not decoration. An if expression unrolls a
        # single-element array to the element, so `$recurse = if (...) { @('/E') }`
        # leaves a string behind -- and splatting a string splats it one character
        # at a time, handing robocopy '/' and 'E' as two arguments instead of the
        # switch. The directory copy then loses /E and stops recursing, which takes
        # the Font Awesome restore down with it.
        [string[]]$recurse = if ($sourceIsFile) { @() } else { @('/E') }
        [string[]]$arguments = @($copyFilter) + @($recurse)
        & robocopy $copyFrom $copyTo @arguments /NFL /NDL /NJH /NJS /NP
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -gt 7) {
            throw "robocopy failed for server-owned path $relativePath with exit code $exitCode."
        }

        # Byte counts rather than file counts. The files are already present either
        # way, so a count cannot show that the right ones arrived; the size can.
        # Free and Pro Font Awesome share every filename and differ only in size,
        # and a theme override file that arrived is a few hundred bytes where the
        # stock one it replaced is a few dozen.
        # Coalesced, because Measure-Object over nothing sums to $null rather than
        # to 0 and the message then interpolates it as an empty string -- the line
        # reads "restored from the base site ( bytes on disk)", which is the one
        # shape an operator scanning for trouble will read straight past.
        $measured = (Get-ChildItem -Path $destinationPath -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $totalBytes = if ($null -eq $measured) { 0 } else { $measured }

        # Zero is reported as a warning rather than as a restore. robocopy can
        # return a success code having moved nothing -- pointing it at a file as
        # though it were a directory does exactly that -- so "it did not throw" is
        # not evidence the file arrived, and this is the only line that would say
        # otherwise.
        if ($totalBytes -eq 0) {
            Write-Warning "Server-owned $relativePath copied 0 bytes. The base site has the path but nothing arrived at the destination; check this before trusting the deploy."
            Write-DeployStep "Server-owned $relativePath restored from the base site (0 bytes on disk -- see warning above)."
        }
        else {
            Write-DeployStep "Server-owned $relativePath restored from the base site ($totalBytes bytes on disk)."
        }
    }
}

function Set-ProductionCompilationSettings {
    <#
    .SYNOPSIS
        Turn ASP.NET debug mode off in a web.config, and pin the execution timeout.

    .DESCRIPTION
        Applied on the server rather than committed to RockWeb/web.config, for two
        reasons. Upstream owns that file and edits it most releases, so a fork-local
        change there conflicts at every merge and can be resolved away in silence.
        And debug="true" is the right setting for a developer running Rock out of
        Visual Studio -- it is only wrong on a server.

        Doing it here also means Rock's own in-application update process cannot
        leave it reverted: Rock Update rewrites web.config, and the next deploy puts
        this back.

        Measured on production 2026-08-26 with debug still on. ASP.NET was serving
        MicrosoftAjax.debug.js at 320KB where the release build is roughly 100KB,
        and a 414KB script bundle unminified at 45 characters per line. Bundling was
        already happening; minification is what debug="true" turns off. Worth 400 to
        500KB of a 3.26MB page. The Obsidian ES modules are unaffected either way.

        The timeout is not optional. debug="true" sets the execution timeout to
        30,000,000 seconds, so the 110 second default has never applied here.
        Turning debug off brings it back, and a cold Rock start was measured at 95
        to 107 seconds -- close enough that a slow morning would surface as a
        request timeout on a site that is working. Both settings move together or
        neither does, which is why one function does both.

        A pure string transform so it can be tested without IIS, a server, or a
        file on disk.

    .PARAMETER WebConfig
        The contents of web.config.

    .PARAMETER ExecutionTimeoutSeconds
        Seconds to allow one request. The default also covers the first request
        after a deploy, when Rock runs its EF and plugin migrations inline.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WebConfig,
        [Parameter(Mandatory = $false)][int]$ExecutionTimeoutSeconds = 600
    )

    # Rewritten rather than appended to, so a redeploy over a site this already ran
    # against produces the same file instead of a second copy of each attribute.
    if ($WebConfig -match '<compilation\b[^>]*\bdebug=') {
        $WebConfig = $WebConfig -replace '(<compilation\b[^>]*\bdebug=")[^"]*(")', '${1}false${2}'
    }
    else {
        $WebConfig = $WebConfig -replace '(<compilation\b)', '${1} debug="false"'
    }

    if ($WebConfig -match '<httpRuntime\b[^>]*\bexecutionTimeout=') {
        $WebConfig = $WebConfig -replace '(<httpRuntime\b[^>]*\bexecutionTimeout=")[^"]*(")', "`${1}$ExecutionTimeoutSeconds`${2}"
    }
    else {
        $WebConfig = $WebConfig -replace '(<httpRuntime\b)', "`${1} executionTimeout=`"$ExecutionTimeoutSeconds`""
    }

    return $WebConfig
}

function Write-RuntimeConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
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
        # PublicApplicationRoot is deliberately not set here. A replace against an
        # <attributeValue attributeKey="PublicApplicationRoot"> element used to sit on
        # this line; that element does not exist in RockWeb/web.config -- 0 occurrences
        # -- so it matched nothing on every deploy this pipeline has ever run.
        #
        # It is a Rock global attribute, read through GlobalAttributesCache and stored
        # in the database, so web.config was never where it lived. Set it with
        # Deployment/Database/Set-RockGlobalAttributeValue.ps1, or in Admin Tools >
        # General Settings > Global Attributes.
        $webConfig = Set-ProductionCompilationSettings -WebConfig $webConfig
        $webConfig | Out-File -FilePath $webConfigPath -Encoding UTF8 -Force
        Write-DeployStep "Wrote web.config with compilation debug=false and executionTimeout=600."
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
        # Mode-aware, because the two branches do opposite things with this list
        # and a plan that promised preservation on a dedicated site would be
        # telling the reviewer the reverse of what the apply run does.
        if ($Mode -eq 'DedicatedSite') {
            Write-DeployStep "Would replace $SitePath wholesale. These directories would NOT survive: $($PreservedDirectories -join ', ')"
        }
        else {
            Write-DeployStep "Would preserve directories: $($PreservedDirectories -join ', ')"
        }
        Write-DeployStep "Would preserve files: $($PreservedFiles -join ', ')"
        Write-DeployStep "Would leave server-owned paths untouched: $($ServerOwnedDirectories -join ', ')"
        $plannedOverrides = @(Get-ServerOwnedThemeFilePaths `
            -SiteRoot $(if ($Mode -eq 'DedicatedSite') { $SharedAssetSourcePath } else { $SitePath }) `
            -FileNames $ServerOwnedThemeFiles)
        Write-DeployStep "Would keep this site's own theme override files: $(if ($plannedOverrides.Count -gt 0) { $plannedOverrides -join ', ' } else { 'none found' })"
        Write-DeployStep "Would set app pool '$AppPoolName' to AlwaysRunning with no idle timeout and a fixed 04:00 recycle, and enable preload on site '$SiteName'."
        Write-DeployStep "Would set compilation debug=false and executionTimeout=600 in the deployed web.config."
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

        # Second pass, and it has to be second: the overlay above skips anything
        # the artifact already placed, which is exactly the set this pass exists
        # to replace. See $ServerOwnedDirectories for why Font Awesome cannot be
        # solved by the first pass or by committing the files.
        # Discovered against the base site rather than against the new one: the
        # question this answers is "which of these does production actually
        # have", and only paths it has can be restored from it.
        $serverOwnedPaths = @($ServerOwnedDirectories) + @(Get-ServerOwnedThemeFilePaths `
            -SiteRoot $sharedAssetSource `
            -FileNames $ServerOwnedThemeFiles)

        Sync-ServerOwnedAssets `
            -SourceRoot $sharedAssetSource `
            -DestinationRoot $SitePath `
            -RelativePaths $serverOwnedPaths

        # Again, after the overlay. The strip above ran on the extracted artifact;
        # the overlay has since backfilled Plugins from the base site and brought
        # that site's own bin/obj along with it.
        Remove-PluginBuildArtifacts -Path $SitePath

        # Whether the plugin assemblies actually arrived, stated in the timeline
        # rather than inferred from a green run. Every BinaryFileType on this
        # catalog stores through rocks.pillars.AmazonStorageProvider.S3BlobStorage
        # and Rock 19 ships no core S3 provider, so if this reports 0 then every
        # image on the site will 404 and the overlay source is the thing to go
        # look at -- not the catalog, and not the artifact. A warning and not a
        # throw: a site with no images is still worth having up to look at.
        $pluginAssemblies = @(Get-ChildItem -Path (Join-Path $SitePath 'bin') -Filter 'rocks.pillars.*.dll' -ErrorAction SilentlyContinue)
        Write-DeployStep "Plugin assemblies present in bin: $($pluginAssemblies.Count) ($($pluginAssemblies.Name -join ', '))."
        if ($pluginAssemblies.Count -eq 0) {
            Write-Warning "No rocks.pillars.* assemblies in bin. Binary file storage will not load and every image on the site will answer 404."
        }

        Write-RuntimeConfiguration -Path $SitePath -Connection $ConnectionString
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

        # Excluded from the copy but deliberately not from the backup above: if
        # this exclusion is ever wrong, the backup is what puts the fonts back.
        # Production's Pro webfonts predate this pipeline by five years and no
        # deploy has ever run against them, so this exclusion is the only thing
        # standing between the v19 cutover and every Pro-only icon on the site
        # turning into an empty box.
        foreach ($directory in $ServerOwnedDirectories) {
            $copyExclusions += '/XD'
            $copyExclusions += (ConvertTo-NativePath -Path (Join-Path $ExtractPath $directory))
        }

        # /XF and not /XD, because these are single files inside directories the
        # artifact does own and must keep writing. Discovered against $SitePath:
        # only a file production actually has is excluded, so a theme v19 adds
        # still gets its override file from the artifact rather than landing
        # without one and failing to compile.
        #
        # Excluded from the copy and deliberately not from the backup, on the
        # same reasoning as Font Awesome above. If this is ever wrong, the backup
        # is what puts the brand back.
        $themeOverrides = @(Get-ServerOwnedThemeFilePaths -SiteRoot $SitePath -FileNames $ServerOwnedThemeFiles)
        foreach ($file in $themeOverrides) {
            $copyExclusions += '/XF'
            $copyExclusions += (ConvertTo-NativePath -Path (Join-Path $ExtractPath $file))
        }
        Write-DeployStep "Keeping this site's own copies of $($themeOverrides.Count) theme override file(s): $($themeOverrides -join ', ')."

        Write-DeployStep "Copying the artifact over $SitePath."
        & robocopy $ExtractPath $SitePath /E @copyExclusions /R:3 /W:5 /NFL /NDL /NP
        $copyExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($copyExit -gt 7) {
            throw "Deploy copy failed with robocopy exit code $copyExit. The previous site files are backed up at $backupPath."
        }

        Write-DeployStep "Copy complete."
        Write-RuntimeConfiguration -Path $SitePath -Connection $ConnectionString
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

    # Both modes, and after the copy rather than before it: an InPlace deploy
    # robocopies over a site it did not create, so this is the only point in a
    # production run where the pool is the deploy's to configure.
    #
    # Logged because the production runbook's rule is that a step with no evidence
    # behind it has not been done, and these settings leave no other trace an
    # operator can read from off the box.
    Write-DeployStep "Holding $AppPoolName resident: no idle timeout, AlwaysRunning, 5 minute startup limit, recycle at 04:00. Preloading site $SiteName."
    Set-WarmSiteSettings -AppPoolName $AppPoolName -SiteName $SiteName

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
