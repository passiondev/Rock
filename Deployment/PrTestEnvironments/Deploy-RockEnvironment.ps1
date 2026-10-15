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

InPlace deliberately writes its manifest somewhere else -- $BackupRoot, default
C:\RockBackups -- so certificate renewal never reaches a production site. That
holds only while renewal's defaults leave the backup root out: the production
bootstrap ships every script in this directory, renewal included, to
production's queue. ManifestContract.Tests.ps1 holds the two together.
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
# Measured against production on 2026-08-26 by hand: eight of these files across
# five themes differ from what the artifact ships -- Rock, Stark, LandingPage,
# CheckinElectric and DashboardStark. They carry the brand palette
# (@brand-color: #00b8e4, the link colours, @brand-critical), the Pro Font
# Awesome wiring, and hand-written CSS fixes. Only Themes/Rock/Styles/
# _variable-overrides.less matches the repository, because at some point someone
# copied that one file into the fork.
#
# That hand count was low, and the gap is the argument for discovering these off
# the box instead of listing them here. The first run against staging restored 46
# files across 23 themes. Most of the extra are themes the fork has no folder for
# at all -- PassionCityChurch, PassionTeam, CONNECT, Connect-V2, Agency,
# CustomDefault, KioskStark and a family of Checkin-* variants -- and they are not
# trivial: PassionCityChurch/_css-overrides.less alone is 10122 bytes. Anything
# enumerated in this file would have missed every one of them.
#
# Both modes lost them, in opposite directions:
#
#   InPlace        robocopy /E copies whenever source and destination differ, and
#                  nothing excluded these, so the v19 cutover would have replaced
#                  them with upstream's empty pair.
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

# The same problem one level further in again: web.config belongs to the artifact,
# but a handful of values inside it belong to the box. Merge-ServerOwnedWebConfigSettings
# carries these across; its help explains what each one costs if it is lost, and
# why the file itself cannot simply go on $PreservedFiles instead.
#
# Measured against production 2026-09-14: all four differ from the artifact, which
# is byte-identical to unaltered upstream and so ships Rock's stock values.
$ServerOwnedAppSettings = @('PasswordKey', 'DataEncryptionKey', 'RunJobsInIISContext', 'OrgTimeZone')

# Matched by prefix because the count is a property of the install, not of Rock.
# Rock reads OldPasswordKey, OldPasswordKey1, OldPasswordKey2... in order, so that
# rotating PasswordKey does not lock out anyone whose hash predates the rotation.
$ServerOwnedAppSettingPrefixes = @('OldPasswordKey')

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

    $resolvedAppPool = if (![string]::IsNullOrWhiteSpace($TargetAppPoolName)) {
        $TargetAppPoolName
    } else {
        # Get-ItemProperty on an IIS site hands back a ConfigurationAttribute under
        # some provider versions and a bare String under others, and the scheduled
        # task runs Windows PowerShell 5.1, where it is the String. Reading .Value
        # unconditionally is a terminating error there under Set-StrictMode.
        #
        # This is the one line in the file no staging deploy can reach: the
        # DedicatedSite branch returns above, so InPlace -- production alone --
        # is the first caller ever to run it, and it failed the first time it did
        # (2026-09-14, dry run 34911854406). The Pester mock returned the .Value
        # shape, so the suite was green throughout. Read both shapes.
        $applicationPool = Get-ItemProperty "IIS:\Sites\$TargetSiteName" -Name applicationPool
        $valueProperty = if ($null -ne $applicationPool) {
            $applicationPool.PSObject.Properties['Value']
        } else { $null }

        $poolName = if ($valueProperty) {
            [string]$valueProperty.Value
        } else {
            [string]$applicationPool
        }

        # An empty name would flow on into Stop-WebAppPool and the app pool ACL
        # grant, which would act on nothing and report success. Name the site in
        # the failure so the next reader knows which one to look at.
        if ([string]::IsNullOrWhiteSpace($poolName)) {
            throw "Could not read the application pool of IIS site '$TargetSiteName'. Pass -TargetAppPoolName explicitly, or check that the site name is right."
        }

        $poolName
    }

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

# The one place this script writes env.json, in either mode.
#
# A function rather than inline at the end of the deploy so that
# ManifestContract.Tests.ps1 can run it. Three scripts read what this writes --
# cleanup, the sandbox refresh and certificate renewal -- and none of them calls
# this one, so the only thing holding the field names and the file's location
# to what those readers expect is that suite writing a real manifest with this
# function and handing it to the real readers.
#
# Everything comes in as a parameter, $Target included, rather than being read
# from the script scope: a manifest says what the caller asked for, and a value
# picked up from scope is one the suite could not see change.
#
# No prNumber, ever. Cleanup stops and destroys any manifest carrying one under
# its root, and staging's manifest sits in that root.
function Write-DeploymentManifest {
    [CmdletBinding()]
    param(
        # What Resolve-DeploymentTarget returned: SiteName, AppPoolName, SitePath
        # and ManifestPath. Passed whole so the manifest and the deploy can never
        # disagree about which site this was.
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Target,

        [Parameter(Mandatory = $true)]
        [string]
        $EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]
        $Mode,

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
        $EnvironmentPath
    )

    $manifest = [ordered]@{
        environmentName = $EnvironmentName
        mode = $Mode
        sha = $Sha
        artifactGcsPath = $ArtifactGcsPath
        hostName = $HostName
        siteName = $Target.SiteName
        appPoolName = $Target.AppPoolName
        environmentPath = $EnvironmentPath
        sitePath = $Target.SitePath
        status = "deployed"
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $Target.ManifestPath -Encoding UTF8 -Force
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
        # Rock writes RockExceptions.csv / RockApplication.csv / MigrationLog.csv.
        # Filtering on '*.log' matched none of them and instead picked up a stale
        # Rock.log from a previous logging config, so the report carried year-old
        # webhook noise while the actual startup failure went uncollected.
        $logDir = Join-Path $SiteRoot 'App_Data\Logs'
        $preferred = @('RockExceptions.csv', 'RockApplication.csv', 'MigrationLog.csv')
        $allLogs = @(Get-ChildItem $logDir -Include '*.csv', '*.log' -File -Recurse -ErrorAction SilentlyContinue)
        # Preferred files first, in the order listed, then whatever else is most recent.
        $logFiles = @()
        foreach ($name in $preferred) {
            $logFiles += @($allLogs | Where-Object { $_.Name -eq $name })
        }
        $logFiles += @($allLogs |
            Where-Object { $preferred -notcontains $_.Name } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 3)
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
        return $null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $localPath = Join-Path $env:TEMP "rock-diagnostics-$EnvironmentName-$stamp.txt"
    $report | Out-File -FilePath $localPath -Encoding utf8 -Force
    $objectName = "pr-environments/diagnostics/$EnvironmentName/$stamp-$Sha.txt"
    Write-GcsObjectFromFile -Bucket $bucket -ObjectName $objectName -Path $localPath

    # Write-DeployStep, not Write-Host: the command queue captures only the former.
    # On 2026-09-14 this report existed, named the culprit assembly 72 times, and
    # nothing in the deploy log said so -- roughly 40 minutes went into rediscovering
    # by hand what was already sitting in the bucket.
    $diagnosticsUri = "gs://$bucket/$objectName"
    Write-DeployStep "Collected diagnostics for the unhealthy site: $diagnosticsUri"
    Write-DeployStep "Read it with: gsutil cat $diagnosticsUri"
    return $diagnosticsUri
}

function Get-MigrationFingerprint {
    <#
        .SYNOPSIS
        A cheap marker for "has Rock run database migrations since I last looked".

        .DESCRIPTION
        Rock migrates the database on first request after a deploy, and the file
        backup this script takes covers only the file system. Once migrations
        have run, restoring the backup puts old binaries against a new schema,
        which is a worse state than the failure being rolled back from -- the
        database restore point has to come out too.

        The rollback advice printed on an unhealthy deploy has no way to know
        that on its own, so it is captured before the copy and compared after:
        MigrationLog.csv is the only on-disk trace migrations leave, and its size
        and last-write time are enough to tell "it moved" from "it did not".
        Returns $null when the file does not exist, which is itself meaningful --
        a log that appears where there was none means migrations ran.
    #>
    param([Parameter(Mandatory = $true)][string]$SiteRoot)

    $path = Join-Path $SiteRoot 'App_Data\Logs\MigrationLog.csv'
    $item = Get-Item -Path $path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return ('{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.ToString('o'))
}

function Invoke-OrphanedAssemblyReconciliation {
    <#
        .SYNOPSIS
        Quarantines core Rock assemblies the live site still has and the artifact
        does not ship.

        .DESCRIPTION
        The copy onto a live site runs without /MIR and without /PURGE, on purpose:
        a purge here would delete uploaded content and the server's own files. The
        cost of that choice is that nothing is ever removed, so an assembly dropped
        between Rock versions stays in bin forever, and the next version loads it.

        That is not theoretical. On 2026-09-14 the v19 cutover left v18's
        Rock.SignNow.dll behind; it referenced a type v19 deleted, MEF composition
        threw while building EntityTypeCache, Application_Start aborted, and every
        request on the production site returned 500 for the life of the app domain.
        Removing one file fixed it. Finding out which file took most of an outage.

        Deliberately scoped to bin\Rock.*.dll and nothing else. Plugin assemblies
        (rocks.pillars.*, com.*, org.*) are absent from the artifact by design --
        they are installed onto the server and are not the pipeline's to remove --
        and the same reconciliation applied to them would delete the site's
        plugins on every deploy. 'Rock.' with the dot is the whole safety story
        between this function and that outcome, so the regex is anchored and
        anything starting 'rocks.' is refused a second time further down.

        Returns the names it quarantined. Moves, never deletes: the files land
        beside the deploy's own backup and the log prints the command to put them
        back.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactRoot,
        [Parameter(Mandatory = $true)][string]$QuarantineRoot
    )

    $siteBin = Join-Path $SiteRoot 'bin'
    $artifactBin = Join-Path $ArtifactRoot 'bin'
    if (-not (Test-Path $siteBin) -or -not (Test-Path $artifactBin)) {
        Write-DeployStep "Orphan check skipped: bin is missing from the site or the artifact."
        return @()
    }

    $isCore = { param($name) $name -match '(?i)^Rock\.' -and $name -notmatch '(?i)^rocks\.' }

    $artifactCore = @(Get-ChildItem -Path $artifactBin -Filter '*.dll' -File -ErrorAction SilentlyContinue |
        Where-Object { & $isCore $_.Name })

    # The artifact is the authority for what should exist, so an artifact that
    # does not look like Rock must not be allowed to authorise removals. Both
    # gates below fail closed: a bad extract reports and changes nothing rather
    # than emptying bin.
    if (-not ($artifactCore.Name -contains 'Rock.dll')) {
        Write-DeployStep "Orphan check skipped: the artifact's bin has no Rock.dll, so it cannot be trusted to say what is orphaned."
        return @()
    }
    if ($artifactCore.Count -lt 20) {
        Write-DeployStep "Orphan check skipped: the artifact ships only $($artifactCore.Count) core assemblies, which is too few to reconcile against."
        return @()
    }

    $shipped = @{}
    foreach ($assembly in $artifactCore) { $shipped[$assembly.Name] = $true }

    $orphans = @(Get-ChildItem -Path $siteBin -Filter '*.dll' -File -ErrorAction SilentlyContinue |
        Where-Object { (& $isCore $_.Name) -and -not $shipped.ContainsKey($_.Name) })

    if ($orphans.Count -eq 0) {
        Write-DeployStep "Orphan check: bin holds $($artifactCore.Count) core assemblies and none are unaccounted for."
        return @()
    }

    # A version bump drops a handful of assemblies. Dozens means the comparison
    # is wrong -- a half-extracted artifact, a changed bin layout -- and the
    # right response to not understanding the input is to report it, not to move
    # files on a production site.
    $ceiling = 25
    if ($orphans.Count -gt $ceiling) {
        Write-DeployStep "Orphan check found $($orphans.Count) core assemblies absent from the artifact, which is more than the $ceiling this deploy will act on. Quarantining nothing; inspect by hand: $($orphans.Name -join ', ')."
        return @()
    }

    Ensure-Directory -Path $QuarantineRoot
    $quarantined = @()
    foreach ($orphan in $orphans) {
        # Belt and braces. If the anchored match above is ever loosened, a plugin
        # assembly reaching this line must still not be moved.
        if ($orphan.Name -notmatch '(?i)^Rock\.' -or $orphan.Name -match '(?i)^rocks\.') { continue }
        try {
            $hash = (Get-FileHash -Path $orphan.FullName -Algorithm SHA256).Hash
            Move-Item -Path $orphan.FullName -Destination (Join-Path $QuarantineRoot $orphan.Name) -Force
            $quarantined += $orphan.Name
            Write-DeployStep "Quarantined orphaned core assembly $($orphan.Name) ($($orphan.Length) bytes, sha256 $($hash.Substring(0,16))...)."
        }
        catch {
            Write-DeployStep "Could not quarantine $($orphan.Name): $($_.Exception.Message). It is still in bin and may break startup."
        }
    }

    if ($quarantined.Count -gt 0) {
        Write-DeployStep "Quarantined $($quarantined.Count) orphaned core assembly/assemblies to $QuarantineRoot. Undo with: Move-Item '$QuarantineRoot\*.dll' '$siteBin'"
    }
    return $quarantined
}

function Write-OrphanedBlockReport {
    <#
        .SYNOPSIS
        Reports, without touching, block files the live site has and the artifact
        does not ship.

        .DESCRIPTION
        The same non-purging copy that strands assemblies strands .ascx files, and
        Rock's RegisterBlockTypes walks the filesystem rather than the database:
        every orphaned block is compiled at startup to read its attributes, so a
        v18 block left behind after a v19 deploy throws a compile error or a
        DuplicateSystemGuidException whether or not any page uses it. Production
        carried 92 of these on 2026-09-14 and logged 82 exceptions in one minute
        because of them.

        Report-only, unlike the assembly reconciliation above, and the difference
        is intentional. An orphaned core assembly breaks startup outright and its
        removal is unambiguously correct. An orphaned block file is noisy rather
        than fatal, and Blocks\ is somewhere a plugin may legitimately have
        installed a file this pipeline knows nothing about -- deleting on that
        guess costs more than the noise does. So the deploy names them and leaves
        the decision to a person.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactRoot
    )

    $siteBlocks = Join-Path $SiteRoot 'Blocks'
    $artifactBlocks = Join-Path $ArtifactRoot 'Blocks'
    if (-not (Test-Path $siteBlocks) -or -not (Test-Path $artifactBlocks)) { return @() }

    $shipped = @{}
    foreach ($file in (Get-ChildItem -Path $artifactBlocks -Filter '*.ascx' -File -Recurse -ErrorAction SilentlyContinue)) {
        $shipped[$file.FullName.Substring($artifactBlocks.Length).TrimStart('\', '/')] = $true
    }
    if ($shipped.Count -lt 100) { return @() }

    $orphans = @(Get-ChildItem -Path $siteBlocks -Filter '*.ascx' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $shipped.ContainsKey($_.FullName.Substring($siteBlocks.Length).TrimStart('\', '/')) } |
        ForEach-Object { $_.FullName.Substring($siteBlocks.Length).TrimStart('\', '/') } |
        Sort-Object)

    if ($orphans.Count -eq 0) {
        Write-DeployStep "Block check: all $($shipped.Count) shipped block files accounted for, no orphans under Blocks."
        return @()
    }

    Write-DeployStep "Block check: $($orphans.Count) block file(s) under Blocks are not in this artifact. They are compiled at startup and can log DuplicateSystemGuidException or compile errors. Not removed -- review and delete by hand if they are from an older version."
    foreach ($orphan in ($orphans | Select-Object -First 40)) {
        Write-DeployStep "  orphaned block: $orphan"
    }
    if ($orphans.Count -gt 40) {
        Write-DeployStep "  ... and $($orphans.Count - 40) more."
    }
    return $orphans
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
        Write-DeployStep "Shared site asset source not found; skipping overlay. SourceRoot=$SourceRoot"
        return
    }
    if ((Resolve-Path $SourceRoot).Path -eq (Resolve-Path $DestinationRoot).Path) {
        Write-DeployStep "Shared asset source is the destination; skipping overlay."
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

function Resolve-SharedAssetSource {
    <#
    .SYNOPSIS
        The site the shared-asset overlay and the server-owned restore read from.

    .DESCRIPTION
        The apply path falls back to the Default Web Site's physical path when no
        explicit source is configured, which is the normal case. This was
        extracted for a dry-run plan that read the configured value alone and so
        reported "none found" for a run that would go on to restore eight files.
        That plan was the DedicatedSite arm of a dry run that only ever runs
        InPlace, so no operator ever read it, and it has since been removed.
        Invoke-DedicatedSiteReplace is the one caller left.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConfiguredPath
    )

    if (![string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
    }

    # Guarded with Get-Command, and -ErrorAction is not enough on its own. A
    # missing cmdlet raises CommandNotFoundException before any parameter is
    # bound, so SilentlyContinue never gets the chance to suppress it -- verified,
    # not assumed. It matters because of when the one caller asks: the dedicated
    # site has already been deleted and replaced by then, so a throw here leaves
    # an environment with no shared assets and no server-owned restore. It also
    # keeps the function callable from the tests, which do not run on Windows
    # and have no IIS module.
    #
    # Absent is not an error. The caller treats an empty source as "nothing to
    # overlay from", which is the right answer both off Windows and on a box where
    # the site is configured explicitly.
    if (!(Get-Command -Name 'Get-Website' -ErrorAction SilentlyContinue)) {
        return ''
    }

    $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($null -ne $defaultSite -and ![string]::IsNullOrWhiteSpace($defaultSite.physicalPath)) {
        return [Environment]::ExpandEnvironmentVariables($defaultSite.physicalPath)
    }

    return ''
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
        Write-DeployStep "Server-owned asset source not found; skipping. SourceRoot=$SourceRoot"
        return
    }
    if ((Resolve-Path $SourceRoot).Path -eq (Resolve-Path $DestinationRoot).Path) {
        Write-DeployStep "Server-owned asset source is the destination; skipping."
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

        # The source measured the same way, because the destination count alone
        # cannot tell a failed copy from a faithful one. Comparing the two answers
        # the question the count is actually being asked -- did what the base site
        # holds arrive -- and it catches a partial copy, which a zero-check never
        # could.
        $measuredSource = (Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $sourceBytes = if ($null -eq $measuredSource) { 0 } else { $measuredSource }

        # An empty source is the normal case, not a fault. Most themes on the box
        # have never been through the Theme Styler, so Rock leaves their override
        # pair at zero bytes; the first run of this against staging restored 46
        # files and 14 of them were legitimately empty. Warning on those would put
        # 14 false alarms in front of an operator on every deploy, and the warning
        # below only works if it is rare enough to still be read. The file is
        # copied and reported either way -- an empty override is what the theme is
        # supposed to have.
        if ($sourceBytes -eq 0) {
            Write-DeployStep "Server-owned $relativePath restored from the base site (empty on the base site, so empty here)."
        }
        elseif ($totalBytes -eq 0) {
            # robocopy can return a success code having moved nothing -- pointing
            # it at a file as though it were a directory does exactly that -- so
            # "it did not throw" is not evidence the file arrived, and this is the
            # only line that would say otherwise.
            Write-Warning "Server-owned $relativePath copied 0 bytes but the base site holds $sourceBytes. Nothing arrived at the destination; check this before trusting the deploy."
            Write-DeployStep "Server-owned $relativePath restored from the base site (0 bytes on disk -- see warning above)."
        }
        elseif ($totalBytes -ne $sourceBytes) {
            Write-Warning "Server-owned $relativePath copied $totalBytes bytes against $sourceBytes on the base site. The copy is incomplete; check this before trusting the deploy."
            Write-DeployStep "Server-owned $relativePath restored from the base site ($totalBytes of $sourceBytes bytes -- see warning above)."
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

function Get-ServerOwnedWebConfigSettings {
    <#
    .SYNOPSIS
        What this server's web.config holds that a deploy has to decide about.

    .DESCRIPTION
        The read half of the merge below, split out because it has two callers
        and they were disagreeing.

        A dry run returns before the artifact is downloaded, so the plan cannot
        merge anything -- there is no incoming file yet. What it can do, and what
        an operator reads it for, is state which server-owned settings this site
        actually has for the apply run to carry. That is this function, and the
        merge is this function plus the rewriting.

        Written out twice, the two drifted, which is the failure this split
        undoes. The plan listed every control registration on the box under a line
        promising the ones the artifact lacks -- a promise only the merge can keep,
        because only it has the artifact to compare against.

        Pure, like Set-ProductionCompilationSettings and for the same reason: an
        operator's last check before a cutover should be testable without IIS, a
        server, or a file on disk.

    .PARAMETER ExistingWebConfig
        The web.config already on the server. Empty means there was none, and
        nothing is owned.

    .PARAMETER AppSettingKeys
        appSettings keys this server owns, by exact name.

    .PARAMETER AppSettingKeyPrefixes
        appSettings keys this server owns by prefix, for families whose members
        cannot be listed in advance -- see OldPasswordKey in the merge below.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingWebConfig,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$AppSettingKeys = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$AppSettingKeyPrefixes = @()
    )

    # Elements, not values. The whole <add /> travels in the merge, so an
    # attribute this code does not know about rides across with it.
    $found = @{
        AppSettings   = [ordered]@{}
        OwnedKeys     = @()
        MachineKey    = ''
        Registrations = [ordered]@{}
    }

    if ([string]::IsNullOrWhiteSpace($ExistingWebConfig)) { return $found }

    foreach ($setting in [regex]::Matches($ExistingWebConfig, '<add\s+key="([^"]+)"[^>]*>')) {
        $key = $setting.Groups[1].Value
        if (-not $found.AppSettings.Contains($key)) { $found.AppSettings[$key] = $setting.Value }
    }

    # Named keys first, then the prefix families, because that is the order an
    # operator reads them back in.
    $owned = @()
    foreach ($key in $AppSettingKeys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($found.AppSettings.Contains($key)) { $owned += $key }
    }
    foreach ($prefix in $AppSettingKeyPrefixes) {
        if ([string]::IsNullOrWhiteSpace($prefix)) { continue }
        foreach ($key in @($found.AppSettings.Keys)) {
            if ($key.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $owned += $key }
        }
    }
    $found.OwnedKeys = @($owned | Select-Object -Unique)

    $machineKey = [regex]::Match($ExistingWebConfig, '<machineKey\b[^>]*>')
    if ($machineKey.Success) { $found.MachineKey = $machineKey.Value }

    # Every registration the box has. Which of them survive is the merge's call
    # and not this one's: it depends on what the artifact registers, and the
    # artifact is not here yet when the plan asks.
    foreach ($registration in [regex]::Matches($ExistingWebConfig, '<add\s+tagPrefix="([^"]+)"[^>]*>')) {
        $tagPrefix = $registration.Groups[1].Value
        if (-not $found.Registrations.Contains($tagPrefix)) {
            $found.Registrations[$tagPrefix] = $registration.Value
        }
    }

    return $found
}

function Merge-ServerOwnedWebConfigSettings {
    <#
    .SYNOPSIS
        Carry the settings this server owns out of its existing web.config and
        into the artifact's, returning the merged file.

    .DESCRIPTION
        web.config cannot go on $PreservedFiles and cannot be copied over blindly
        either, which is why this exists rather than a one-line list entry.

        Not preserved: 19.3.4 changes 376 lines of web.config against 18.4.1, and
        nearly all of them are bindingRedirect bumps -- WebGrease to 5.2.9,
        Newtonsoft to 6.0.0, the Google API assemblies to 1.69.0.0. Keep the box's
        file and v19's own assemblies do not load.

        Not copied: measured against production on 2026-09-14, every value named
        below differs between the live box and the artifact. RockWeb/web.config is
        byte-identical to unaltered upstream, so the artifact carries Rock's stock
        distribution values; production's were set by hand on the server and have
        never matched any branch, 18.4.1 included.

        So: artifact as the base, with the server-owned values written back over
        the top. The same principle as $ServerOwnedDirectories and
        $ServerOwnedThemeFiles, one level further in -- the file belongs to the
        artifact, a handful of values inside it belong to the box.

        A pure transform, like Set-ProductionCompilationSettings, so it is
        testable without IIS, a server, or a file on disk.

        What each carried value costs if it is lost:

          PasswordKey          Rock/Security/Authentication/Database.cs hashes
                               every database password with it. A different key
                               validates no existing password, so every staff
                               login fails at once -- including the login needed
                               to go and fix it.
          DataEncryptionKey    Rock/Security/Encryption.cs. Encrypted attribute
                               values, financial gateway credentials among them,
                               stop decrypting. Nothing fails at startup; it
                               surfaces the first time a gateway is called.
          RunJobsInIISContext  Production runs Quartz inside the IIS worker
                               process and sets this True. Upstream ships False.
                               Flipping it stops every scheduled job, silently.
          OrgTimeZone          Production names the zone; upstream says Local.
                               Harmless while the VM is Eastern Standard Time,
                               which it is today, and wrong the moment that stops
                               being true.
          machineKey           Travels as a whole element: the two keys are a pair
                               and the algorithm attributes belong with them.
                               Losing it drops every signed-in session and fails
                               ViewState validation mid-postback.
          tagPrefix            Production registers tagPrefix="Passion"
                               assembly="com.passioncitychurch", and three live
                               registration pages under Plugins\passion\crm use
                               it. They are .ascx with CodeFile=, so they compile
                               on first request: drop the registration and all
                               three yellow-screen, with nothing before the first
                               visitor to say so.

        OldPasswordKey is matched by prefix rather than named. Rock reads
        OldPasswordKey, OldPasswordKey1, OldPasswordKey2 and so on in order so that
        a key rotation does not lock out anyone whose hash predates it, and how
        many exist is not knowable from here.

        Anything else the server has and the artifact does not is reported, not
        moved. A key this list does not name is either one upstream dropped on
        purpose or one nobody has justified keeping; naming it here is how it
        survives, and a silent catch-all would carry both kinds forward forever.

    .PARAMETER IncomingWebConfig
        The artifact's web.config: the base, and the winner for everything not
        named here.

    .PARAMETER ExistingWebConfig
        The web.config already on the server, read before the copy destroys it.
        Empty means there was none, and the incoming file comes back unchanged.

    .PARAMETER AppSettingKeys
        appSettings keys to carry across by exact name.

    .PARAMETER AppSettingKeyPrefixes
        appSettings keys to carry across by prefix, for families whose members
        cannot be listed in advance.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$IncomingWebConfig,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingWebConfig,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$AppSettingKeys = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$AppSettingKeyPrefixes = @()
    )

    $result = @{ WebConfig = $IncomingWebConfig; Carried = @(); Dropped = @() }
    if ([string]::IsNullOrWhiteSpace($IncomingWebConfig)) { return $result }
    if ([string]::IsNullOrWhiteSpace($ExistingWebConfig)) { return $result }

    $merged = $IncomingWebConfig
    $carried = @()

    # What the box has. Prefix families are resolved there and not here, because
    # only the server's own file knows how many OldPasswordKey entries this
    # particular install has -- and because the dry-run plan asks the same
    # question and has to get the same answer.
    $found = Get-ServerOwnedWebConfigSettings `
        -ExistingWebConfig $ExistingWebConfig `
        -AppSettingKeys $AppSettingKeys `
        -AppSettingKeyPrefixes $AppSettingKeyPrefixes

    # Every replace below goes through a MatchEvaluator and a count of 1. The
    # evaluator is what stops a '$' anywhere in a carried value being read as a
    # substitution group -- these are base64 and hex today, and the day one of
    # them is not is not the day to discover that. The count is what stops a
    # second <appSettings> somewhere in the file collecting a duplicate.
    foreach ($key in $found.OwnedKeys) {
        $fromServer = $found.AppSettings[$key]
        $elementPattern = '<add\s+key="' + [regex]::Escape($key) + '"[^>]*>'

        if ([regex]::IsMatch($merged, $elementPattern)) {
            $merged = ([regex]$elementPattern).Replace($merged, { param($m) $fromServer }, 1)
        }
        elseif ([regex]::IsMatch($merged, '<appSettings[^>]*>')) {
            # The artifact has no entry for a key the server does. Add one rather
            # than leave a setting the site depends on to ConfigurationManager
            # handing back null.
            $merged = ([regex]'<appSettings[^>]*>').Replace($merged, { param($m) ($m.Value + "`r`n    " + $fromServer) }, 1)
        }
        else { continue }
        $carried += $key
    }

    # machineKey, as a whole element. Inserted rather than skipped when the
    # artifact has none: ASP.NET would otherwise generate one per app domain and
    # every recycle would sign everybody out.
    if (![string]::IsNullOrWhiteSpace($found.MachineKey)) {
        $machineKeyPattern = '<machineKey\b[^>]*>'
        $serverMachineKey = $found.MachineKey

        if ([regex]::IsMatch($merged, $machineKeyPattern)) {
            $merged = ([regex]$machineKeyPattern).Replace($merged, { param($m) $serverMachineKey }, 1)
            $carried += 'machineKey'
        }
        elseif ([regex]::IsMatch($merged, '<system\.web[^>]*>')) {
            $merged = ([regex]'<system\.web[^>]*>').Replace($merged, { param($m) ($m.Value + "`r`n    " + $serverMachineKey) }, 1)
            $carried += 'machineKey'
        }
    }

    # Control registrations the artifact has no entry for. Matched on the prefix
    # name alone: if the artifact registers the same prefix against a different
    # assembly then the artifact wins, because that is a v19 decision and not
    # this server's.
    #
    # This is the filter the dry-run plan cannot apply, because the artifact is
    # not downloaded yet when the plan runs. The plan says so rather than
    # promising the outcome of a comparison it has not made.
    foreach ($tagPrefix in @($found.Registrations.Keys)) {
        if ([regex]::IsMatch($merged, '<add\s+tagPrefix="' + [regex]::Escape($tagPrefix) + '"')) { continue }
        if (-not [regex]::IsMatch($merged, '<controls[^>]*>')) { continue }
        $registrationText = $found.Registrations[$tagPrefix]
        $merged = ([regex]'<controls[^>]*>').Replace($merged, { param($m) ($m.Value + "`r`n        " + $registrationText) }, 1)
        $carried += "tagPrefix:$tagPrefix"
    }

    # Reported, not moved. See the .DESCRIPTION.
    $dropped = @()
    foreach ($key in @($found.AppSettings.Keys)) {
        if ($found.OwnedKeys -contains $key) { continue }
        if ([regex]::IsMatch($merged, '<add\s+key="' + [regex]::Escape($key) + '"')) { continue }
        $dropped += $key
    }

    $result.WebConfig = $merged
    $result.Carried = @($carried)
    $result.Dropped = @($dropped)
    return $result
}

function Write-RuntimeConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Connection,

        # The site's own web.config as it was before the artifact landed on top of
        # it. Both callers read it before their copy, because the copy is what
        # destroys it. Empty means there was no previous site, and the artifact's
        # file stands as shipped.
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ExistingWebConfig = ''
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
            Write-DeployStep "No connection string supplied; leaving the existing web.ConnectionStrings.config in place."
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
        # Before the compilation transform, so one write puts both out.
        if (-not [string]::IsNullOrWhiteSpace($ExistingWebConfig)) {
            $merge = Merge-ServerOwnedWebConfigSettings `
                -IncomingWebConfig $webConfig `
                -ExistingWebConfig $ExistingWebConfig `
                -AppSettingKeys $ServerOwnedAppSettings `
                -AppSettingKeyPrefixes $ServerOwnedAppSettingPrefixes
            $webConfig = $merge.WebConfig
            Write-DeployStep "Kept this server's own web.config settings: $(if ($merge.Carried.Count -gt 0) { $merge.Carried -join ', ' } else { 'none found' })."
            if ($merge.Dropped.Count -gt 0) {
                # A warning and not a throw. These are settings the artifact has no
                # opinion about, and on this install both of them -- EnableBundling
                # and RedisConnectionString -- are referenced nowhere in 19.3.4.
                # Silence is what would be wrong: the next one might matter.
                Write-Warning "web.config settings on this server that the artifact does not have and this deploy did not carry across: $($merge.Dropped -join ', '). Add them to `$ServerOwnedAppSettings if they must survive."
            }
        }

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


function Write-DeployScriptProvenance {
    <#
        .SYNOPSIS
        States which copy of this script is running and when it was last refreshed.

        .DESCRIPTION
        What the VM runs is not necessarily what is in the repository. The agent
        executes whatever copy of Deployment/PrTestEnvironments was on disk when
        the box was last bootstrapped, and the refresh that is supposed to keep
        that current -- Sync-DeploymentScripts in Invoke-PrEnvironmentCommandQueue
        -- reports only through Write-Host, before the command loop starts, where
        nothing captures it. So a fix merged to the repository can sit looking
        deployed and be inert on the box, and no artifact of a deploy says which
        of the two happened.

        One hash in the timeline settles it: compare it against
        Get-FileHash of the repository copy and the question is answered in
        seconds rather than by reading the script on the box. The sync state
        beside it comes from the file Sync-DeploymentScripts now writes, and its
        absence is itself the finding -- it means no refresh has ever recorded a
        result on this machine.
    #>
    param([Parameter(Mandatory = $false)][string]$ScriptPath = $PSCommandPath)

    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path $ScriptPath)) {
        Write-DeployStep "Running script: path unavailable, so its version cannot be stated."
        return
    }

    $name = Split-Path $ScriptPath -Leaf
    try {
        $hash = (Get-FileHash -Path $ScriptPath -Algorithm SHA256).Hash
        $written = (Get-Item $ScriptPath).LastWriteTimeUtc.ToString('o')
        Write-DeployStep "Running $name sha256 $hash (written $written). Compare with: Get-FileHash Deployment/PrTestEnvironments/$name"
    }
    catch {
        Write-DeployStep "Running ${name}: could not hash it ($($_.Exception.Message))."
        return
    }

    $statePath = Join-Path (Split-Path -Parent $ScriptPath) 'script-sync-state.json'
    if (-not (Test-Path $statePath)) {
        Write-DeployStep "No script-sync-state.json beside it: the agent's script refresh has never recorded a result on this box, so these scripts are whatever the last bootstrap installed."
        return
    }

    try {
        $state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
        $entry = $state.files | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($null -eq $entry) {
            Write-DeployStep "Script refresh last ran $($state.lastRunUtc) and did not see $name in the bootstrap prefix."
            return
        }
        Write-DeployStep "Script refresh last ran $($state.lastRunUtc); $name was '$($entry.status)'$(if ($entry.detail) { " ($($entry.detail))" })."
    }
    catch {
        Write-DeployStep "Could not read script-sync-state.json: $($_.Exception.Message)."
    }
}

function Write-PluginAssemblyReport {
    <#
        .SYNOPSIS
        States whether the server's plugin assemblies are in bin, in the timeline
        rather than left to be inferred from a green run.

        .DESCRIPTION
        Every BinaryFileType on this catalog stores through
        rocks.pillars.AmazonStorageProvider.S3BlobStorage and Rock 19 ships no
        core S3 provider, so a bin without these assemblies is a site where every
        image answers 404 -- while the health check, which only asks whether the
        app domain routes a request, passes happily.

        Both modes, for different reasons. A dedicated site builds bin from the
        artifact plus an overlay, so a zero here means the overlay source is the
        thing to go look at. An in-place deploy never copies these assemblies at
        all -- they belong to the server and the artifact has none -- so a zero
        there means the non-purging copy is no longer the only thing touching
        bin, which is a much more serious finding and exactly the class of
        surprise this pipeline keeps producing.

        A warning and not a throw: a site with no images is still worth having up
        to look at.
    #>
    param([Parameter(Mandatory = $true)][string]$SiteRoot)

    $pluginAssemblies = @(Get-ChildItem -Path (Join-Path $SiteRoot 'bin') -Filter 'rocks.pillars.*.dll' -ErrorAction SilentlyContinue)
    Write-DeployStep "Plugin assemblies present in bin: $($pluginAssemblies.Count) ($($pluginAssemblies.Name -join ', '))."
    if ($pluginAssemblies.Count -eq 0) {
        Write-Warning "No rocks.pillars.* assemblies in bin. Binary file storage will not load and every image on the site will answer 404."
    }
    return $pluginAssemblies.Count
}

function Assert-DeployedCoreVersion {
    <#
        .SYNOPSIS
        Fails the deploy if the Rock.dll now on the site is not the one in the
        artifact.

        .DESCRIPTION
        robocopy reports success for a run in which individual files were skipped,
        and a locked bin\Rock.dll is exactly the file most likely to be skipped
        and least survivable to skip: the site keeps the old core assembly and
        every other assembly around it is new. Nothing downstream detects that --
        the health check can still pass, because the old Rock may well start.

        Comparing the file version of one assembly across the two trees is enough
        to catch it, and it throws rather than warns because there is no reading
        of a version mismatch here that is acceptable to leave running.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SiteRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactRoot
    )

    $sitePath = Join-Path $SiteRoot 'bin\Rock.dll'
    $artifactPath = Join-Path $ArtifactRoot 'bin\Rock.dll'
    if (-not (Test-Path $sitePath) -or -not (Test-Path $artifactPath)) {
        Write-DeployStep "Core version check skipped: Rock.dll is missing from the site or the artifact."
        return
    }

    $siteVersion = (Get-Item $sitePath).VersionInfo.FileVersion
    $artifactVersion = (Get-Item $artifactPath).VersionInfo.FileVersion
    if ($siteVersion -ne $artifactVersion) {
        throw "The copy did not land: bin\Rock.dll on the site is $siteVersion but the artifact ships $artifactVersion. The site is now a mix of two Rock versions; restore the backup rather than starting it."
    }
    Write-DeployStep "Core version check: bin\Rock.dll is $siteVersion on both the artifact and the site."
}

function Invoke-SiteContentProbe {
    <#
        .SYNOPSIS
        Like Invoke-SiteProbe, but keeps the body and the headers.

        .DESCRIPTION
        Invoke-SiteProbe deliberately reads nothing but the status code, which is
        the right shape for a health check polled every few seconds. It is the
        wrong shape for asking "did Rock render this, or did something else
        answer for it" -- a question this pipeline has already got wrong once, by
        reading a 302 as proof the site was up when the redirect was a
        maintenance rule answered at the CDN edge and Rock was returning 500 to
        everything behind it.

        Redirects are still not followed, for the reason given on Invoke-SiteProbe:
        the Location is absolute and following it leaves the loopback.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][string]$HostHeader = '',
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)][int]$MaxBodyBytes = 262144
    )

    $outcome = @{ StatusCode = 0; Body = ''; Server = ''; Error = '' }

    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'RockDeploySmokeCheck'
        if (![string]::IsNullOrWhiteSpace($HostHeader)) { $request.Host = $HostHeader }
        $response = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        # The error response carries the body, and on a failed deploy the body is
        # the ASP.NET error page -- the single most useful thing on the box.
        $response = $_.Exception.Response
        $outcome.Error = $_.Exception.Message
    }
    catch {
        $outcome.Error = $_.Exception.Message
        return $outcome
    }

    if ($null -eq $response) { return $outcome }
    try {
        try { $outcome.StatusCode = [int]$response.StatusCode } catch { }
        try { $outcome.Server = [string]$response.Headers['Server'] } catch { }
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            # Capped rather than read to the end: a Rock page is a few hundred KB
            # and the markers being looked for are all in the first screenful, so
            # there is no reason to hold a megabyte of HTML in a deploy script.
            $buffer = New-Object char[] $MaxBodyBytes
            $read = $reader.Read($buffer, 0, $MaxBodyBytes)
            if ($read -gt 0) { $outcome.Body = (New-Object string($buffer, 0, $read)) }
        }
        finally { $reader.Dispose() }
    }
    catch { $outcome.Error = $_.Exception.Message }
    finally { try { $response.Close() } catch { } }

    return $outcome
}

function Invoke-DeploySmokeCheck {
    <#
        .SYNOPSIS
        Asks the deployed site for a page Rock has to render itself, and says what
        came back.

        .DESCRIPTION
        Test-EnvironmentHealth passing means the app domain started and routed a
        request. It does not mean Rock is serving pages: / answers 302 to the
        login page, and a 302 is produced before most of what a deploy can break
        is ever touched.

        So this asks for the login page over the loopback and looks for
        __VIEWSTATE, the hidden field every ASP.NET WebForms render emits. Present
        means Rock compiled a page, ran it and returned it. Absent, on a 200,
        means something that is not Rock answered -- a static error document, an
        IIS placeholder, a proxy.

        A warning rather than a throw, deliberately, and this is the one place in
        the script where that is a close call. A 404 here is a routing choice a
        site is entitled to make, and failing a production deploy that is
        genuinely healthy costs more than the signal is worth. A 5xx is different
        and is reported as an outright failure of the check, which the caller
        turns into diagnostics.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60
    )

    $url = "https://127.0.0.1/Login"
    $probe = Invoke-SiteContentProbe -Url $url -HostHeader $HostName -TimeoutSeconds $TimeoutSeconds

    if ($probe.StatusCode -eq 0) {
        Write-Warning "Smoke check could not reach $url with Host: $HostName ($($probe.Error))."
        return $false
    }

    if ($probe.StatusCode -ge 500) {
        Write-Warning "Smoke check: $url returned $($probe.StatusCode). The site routes requests but cannot render its login page."
        return $false
    }

    if ($probe.StatusCode -ge 400) {
        Write-DeployStep "Smoke check: $url returned $($probe.StatusCode), so it proves nothing either way. Not treating that as a failure."
        return $true
    }

    if ($probe.Body -match '__VIEWSTATE') {
        Write-DeployStep "Smoke check passed: $url returned $($probe.StatusCode) and Rock rendered the page ($($probe.Body.Length) chars, __VIEWSTATE present)."
        return $true
    }

    Write-Warning "Smoke check: $url returned $($probe.StatusCode) but the response has no __VIEWSTATE, so Rock did not render it. Something else is answering for this site."
    return $false
}
function Invoke-DedicatedSiteReplace {
    <#
    .SYNOPSIS
        Replace a site this pipeline owns outright, wholesale.

    .DESCRIPTION
        One of the two things a deploy can be. It ran as top-level script, which
        meant nothing could call it: Import-ScriptFunction lifts function
        definitions, so every Pester test in this repository stopped at the last
        function and the ordering below -- stash, wipe, move, grant, restore,
        overlay -- was covered only by Python tests matching the text of their
        own source. Those assert what the file says, not what it does, and the
        difference is the whole of what this extraction buys.

        The ordering is the dangerous part and it is why this is one function and
        not five. Between the wipe and the restore the site does not exist, and
        every read that has to happen before it must have happened before it.
        A caller cannot get that wrong here because it cannot reach inside.

        Returns the same record Invoke-InPlaceOverlay returns, so the run that
        follows does not have to know which branch produced it.

    .PARAMETER ExistingWebConfig
        The site's own web.config as text, read before this was called -- this
        deletes the file that holds it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$SitePath,
        [Parameter(Mandatory = $true)][string]$ExtractPath,
        [Parameter(Mandatory = $true)][string]$SiteName,
        [Parameter(Mandatory = $true)][string]$AppPoolName,
        [Parameter(Mandatory = $true)][string]$HostName,
        # No `= ''` on any of these. An unsupplied [string] is already the empty
        # string, so stating it buys nothing -- and for -CertificateThumbprint and
        # -SharedAssetSourcePath it would restate a script-level default this
        # function cannot honestly match. The script reads those from the
        # environment at the entry point; a branch function that went and read the
        # environment itself would be taking a decision it exists to be handed.
        # See ScriptDefaults.Tests.ps1: a function that omits a default is being
        # stricter than the script, not drifting from it.
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$CertificateThumbprint,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConnectionString,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ExistingWebConfig,
        # The collections keep theirs: an unsupplied [string[]] is $null, not @().
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$PreservedFiles = @(),
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SharedAssetSourcePath,
        [Parameter(Mandatory = $true)][string]$SharedAssetDirectories,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ServerOwnedDirectories = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ServerOwnedThemeFiles = @()
    )

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
    Write-DeployStep "Granted $appPoolIdentity modify rights on $SitePath."

    foreach ($file in $preservedStash.Keys) {
        $restoreTo = Join-Path $SitePath $file
        # Only fill a gap. The artifact shipping its own copy means the branch
        # is authoritative for that file, exactly as in the InPlace path.
        if (!(Test-Path $restoreTo)) {
            Ensure-Directory -Path (Split-Path -Parent $restoreTo)
            $preservedStash[$file] | Out-File -FilePath $restoreTo -Encoding UTF8 -Force -NoNewline
            Write-DeployStep "Preserved $file across the site replace."
        }
    }

    $sharedAssetSource = Resolve-SharedAssetSource -ConfiguredPath $SharedAssetSourcePath

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
    Write-PluginAssemblyReport -SiteRoot $SitePath | Out-Null

    Write-RuntimeConfiguration -Path $SitePath -Connection $ConnectionString -ExistingWebConfig $ExistingWebConfig
    Ensure-AppPool -Name $AppPoolName
    Ensure-Website -Name $SiteName -PhysicalPath $SitePath -HostHeader $HostName -PoolName $AppPoolName -Thumbprint $CertificateThumbprint

    # The same two fields the in-place branch hands back, so the run that follows
    # can ask what happened rather than ask which branch ran.
    return @{
        # Nothing to roll back to. This branch deleted the directory it deployed
        # into; it did not copy it aside. An empty path is how the caller knows
        # not to offer rollback advice it cannot honour.
        BackupPath                    = ''
        # And so no migration reading either: the reading exists only to qualify
        # "restore the files", and there are no files to restore.
        PreDeployMigrationFingerprint = $null
    }
}

function Get-InPlaceOverlayPlan {
    <#
    .SYNOPSIS
        What the in-place overlay will keep away from the artifact, worked out
        once for the dry run and the apply run alike.

    .DESCRIPTION
        Production's runbook has an operator read the dry run's plan and then
        tick apply. That approval is only worth something if the plan is what the
        apply run goes on to do, and for as long as this pipeline has existed the
        two were worked out separately: the dry run from the script's lists and a
        theme discovery of its own, the overlay from its parameters and another.
        They agreed because nobody had changed one without the other, and nothing
        would have said so the day somebody did. Now there is one record. The dry
        run prints it and Invoke-InPlaceOverlay hands its exclusions to robocopy
        as they are.

        All of it can be worked out before anything is downloaded, which is what
        lets a dry run report it. robocopy matches /XD and /XF against the source
        tree, so the copy's exclusions are spelled against $ExtractPath -- a path
        the script fixes up front and the download only fills in later -- and the
        theme discovery reads the live site, which nothing has touched yet.

        Read-only. It looks for files and builds strings; it creates nothing, so a
        dry run that calls it still changes nothing.

    .PARAMETER BackupRoot
        The root every environment's backups go under. The plan carries this
        environment's directory beneath it and stops there: the timestamped leaf
        is the apply run's to add, because a dry run has no moment to stamp.

    .OUTPUTS
        A hashtable. SitePath, ExtractPath and BackupDirectory say where; the
        lists the dry run reads out -- PreservedDirectories, PreservedFiles,
        ServerOwnedDirectories and the discovered ThemeOverrides -- say what; and
        BackupExclusions and CopyExclusions are the robocopy arguments built from
        them, the only part the overlay itself reads.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$SitePath,
        [Parameter(Mandatory = $true)][string]$ExtractPath,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        # The collections need their @() because an unsupplied [string[]] is
        # $null rather than empty, and the record hands them on to a dry run
        # that joins them into the lines an operator reads.
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$PreservedDirectories = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$PreservedFiles = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ServerOwnedDirectories = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$ServerOwnedThemeFiles = @()
    )

    # Back up what the deploy can actually damage: build output and config.
    # Uploaded Content is excluded because it is not being touched and copying
    # it would multiply the site's disk usage on every deploy.
    $backupExclusions = @()
    foreach ($directory in $PreservedDirectories) {
        $backupExclusions += '/XD'
        $backupExclusions += (Join-Path $SitePath $directory)
    }

    # Kept away from the copy of the artifact over the live site. There is no
    # /MIR and no /PURGE on that copy, so these are the whole of what stands
    # between the server's own files and the artifact's.
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

    return @{
        SitePath               = $SitePath
        ExtractPath            = $ExtractPath
        BackupDirectory        = (Join-Path $BackupRoot $EnvironmentName)
        PreservedDirectories   = @($PreservedDirectories)
        PreservedFiles         = @($PreservedFiles)
        ServerOwnedDirectories = @($ServerOwnedDirectories)
        ThemeOverrides         = $themeOverrides
        BackupExclusions       = $backupExclusions
        CopyExclusions         = $copyExclusions
    }
}

function Invoke-InPlaceOverlay {
    <#
    .SYNOPSIS
        Copy the artifact over a site that already exists and is not ours.

    .DESCRIPTION
        The other of the two things a deploy can be, and the one production uses.
        It ran as top-level script for the same reason and at the same cost as
        the branch above.

        What this does that the other does not is leave a way back. It copies the
        site aside first, and it reads Rock's migration log before the copy so
        that the advice it hands back can say whether restoring those files is
        enough on its own. Both facts travel in the returned record; the reading
        used to be taken in the dedicated-site branch and read here, where under
        Set-StrictMode it was a terminating error on every in-place run that got
        far enough to need it.

        No /MIR and no /PURGE anywhere in here. Files the server legitimately
        owns -- uploaded content, its own fonts, its theme overrides -- are on the
        far side of this copy and a purge would take them permanently.

        Which files those are is not decided here. This carries out the plan
        Get-InPlaceOverlayPlan made, which is the plan the dry run printed, so
        the exclusions an operator approved are the exclusions robocopy is
        handed rather than a second working-out that happened to match.

    .PARAMETER Plan
        The record Get-InPlaceOverlayPlan returned: the site, the extracted
        artifact, this environment's backup directory, and the robocopy
        exclusions for the backup and for the copy.

    .PARAMETER ExistingWebConfig
        The site's own web.config as text, read before this was called -- the copy
        writes the artifact's file over the top of it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [Parameter(Mandatory = $true)][string]$Sha,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        # No `= ''`, for the reason Invoke-DedicatedSiteReplace gives: an
        # unsupplied [string] is already the empty string.
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConnectionString,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ExistingWebConfig
    )

    # Unpacked under the names these steps have always used, so each robocopy
    # call below still reads as the command it runs and the log lines name the
    # same paths they always named.
    $SitePath = $Plan.SitePath
    $ExtractPath = $Plan.ExtractPath
    $backupExclusions = @($Plan.BackupExclusions)
    $copyExclusions = @($Plan.CopyExclusions)
    $themeOverrides = @($Plan.ThemeOverrides)

    # Read before the copy, compared after the site fails to come up. See
    # Get-MigrationFingerprint: it decides whether the rollback advice this run
    # hands back can honestly say "restore the files". It is taken here, in the
    # branch that makes the backup, because that advice is only ever offered
    # where there is a backup for it to qualify. It used to be taken in the
    # dedicated-site branch and read here, which under Set-StrictMode made the
    # unhealthy-deploy path a terminating error on every in-place run.
    $preDeployMigrationFingerprint = Get-MigrationFingerprint -SiteRoot $SitePath

    $backupPath = Join-Path $Plan.BackupDirectory ((Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-$Sha")
    Ensure-Directory -Path $backupPath
    Write-DeployStep "Backing up $SitePath to $backupPath (excluding preserved user data)."

    # Through Write-Host rather than straight out. The success stream is this
    # function's return value now, and robocopy's job summary -- bytes copied,
    # files skipped, retries -- would otherwise be handed back as if it were the
    # record. Write-Host is where every other line of this deploy already goes,
    # so the summary still reaches the log the operator reads.
    & robocopy $SitePath $backupPath /E @backupExclusions /R:2 /W:2 /NFL /NDL /NP | Write-Host
    $backupExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($backupExit -gt 7) {
        throw "Backup failed with robocopy exit code $backupExit; refusing to deploy."
    }
    Write-DeployStep "Backup complete."

    # Copy the artifact over the live site. No /MIR and no /PURGE: files the
    # server legitimately owns must survive, and a purge here would delete
    # uploaded content and break the site permanently. What is kept away from
    # the copy is the plan's $copyExclusions, unchanged -- see
    # Get-InPlaceOverlayPlan for what each list protects and why.
    Write-DeployStep "Keeping this site's own copies of $($themeOverrides.Count) theme override file(s): $($themeOverrides -join ', ')."

    Write-DeployStep "Copying the artifact over $SitePath."
    & robocopy $ExtractPath $SitePath /E @copyExclusions /R:3 /W:5 /NFL /NDL /NP | Write-Host
    $copyExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($copyExit -gt 7) {
        throw "Deploy copy failed with robocopy exit code $copyExit. The previous site files are backed up at $backupPath."
    }

    Write-DeployStep "Copy complete."

    # Here and not later: the pool is still stopped, so nothing holds a lock
    # on bin, and nothing has tried to start Rock against the stale assembly
    # yet. Both calls are wrapped because a deploy that has already copied
    # successfully must not be failed by its own housekeeping.
    try {
        Invoke-OrphanedAssemblyReconciliation -SiteRoot $SitePath -ArtifactRoot $ExtractPath -QuarantineRoot (Join-Path $backupPath 'quarantined-orphans') | Out-Null
    }
    catch { Write-DeployStep "Orphan check failed: $($_.Exception.Message). Continuing; see the diagnostics report if the site does not come up." }

    try { Write-OrphanedBlockReport -SiteRoot $SitePath -ArtifactRoot $ExtractPath | Out-Null }
    catch { Write-DeployStep "Block check failed: $($_.Exception.Message). Continuing." }

    # Not wrapped, unlike the two checks above. Those report on things that
    # are wrong and survivable; this one only fires when the copy silently
    # did not happen, and the correct response to that is to stop.
    Assert-DeployedCoreVersion -SiteRoot $SitePath -ArtifactRoot $ExtractPath

    # In-place too, and not only on a dedicated site. The artifact ships no
    # plugin assemblies, so on this path the count is a statement about what
    # the copy left alone -- which is the half nothing has ever checked.
    Write-PluginAssemblyReport -SiteRoot $SitePath | Out-Null

    Write-RuntimeConfiguration -Path $SitePath -Connection $ConnectionString -ExistingWebConfig $ExistingWebConfig
    Ensure-Directory -Path (Split-Path -Parent $ManifestPath)

    # The same two fields the dedicated-site branch hands back.
    return @{
        BackupPath                    = $backupPath
        PreDeployMigrationFingerprint = $preDeployMigrationFingerprint
    }
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

    # The header goes through Write-DeployStep like everything else, so the
    # timeline file carries it too. Get-CommandLogText recovers that file when the
    # job stream comes back short, and appends it under the capture -- which reads
    # correctly only while the capture survives to supply the header. When the
    # capture is lost outright, a recovered timeline that opened with "Deploy
    # started." named neither the environment, the sha, nor the mode, and there is
    # nothing else on the box that would say. Eight lines at +00:00:00, nine on the
    # branch that takes a backup, is the whole cost.
    Write-DeployStep "=== Rock environment deploy ==="
    Write-DeployStep "  environment : $EnvironmentName"
    Write-DeployStep "  mode        : $Mode"
    Write-DeployStep "  sha         : $Sha"
    Write-DeployStep "  artifact    : $ArtifactGcsPath"
    Write-DeployStep "  host        : $HostName"
    Write-DeployStep "  site path   : $SitePath"
    Write-DeployStep "  iis site    : $SiteName (app pool $AppPoolName)"
    # InPlace only. DedicatedSite takes no backup at all -- Invoke-DedicatedSiteReplace
    # hands back an empty BackupPath precisely so the rollback line can be skipped --
    # so a root printed there would name a directory the run never writes to.
    #
    # Here rather than only in the dry run's plan, because the run that needs it is
    # the apply run: this is where production's sole rollback copy lands, and where
    # the manifest lands with it. The queue can now move it, which is the reason a
    # header that recites the site path and not this one had stopped being complete.
    # A cutover that goes wrong is read back from this timeline, and the restore
    # command in the runbook is the one line a reader has to be able to fill in.
    if ($Mode -eq 'InPlace') {
        Write-DeployStep "  backups     : $(Join-Path $BackupRoot $EnvironmentName)"
    }
    Write-DeployStep "Deploy started."
    Write-DeployScriptProvenance

    # One plan, made here and above the dry-run fork, so the plan a dry run
    # prints and the plan an apply run carries out come from the same call
    # rather than from two that have to be kept in step by hand. The operator
    # approves the first and production gets the second.
    #
    # Making it this early moves the theme discovery from after the backup to
    # before the download. Neither the download, the pool stop, nor the
    # backup writes to the live site's Themes directory, so nothing the deploy
    # does in between can change the answer -- and if the discovery ever
    # throws, it now throws before the site is taken offline rather than after.
    if ($Mode -eq 'InPlace') {
        $overlayPlan = Get-InPlaceOverlayPlan `
            -SitePath $SitePath `
            -ExtractPath $ExtractPath `
            -EnvironmentName $EnvironmentName `
            -BackupRoot $BackupRoot `
            -PreservedDirectories $PreservedDirectories `
            -PreservedFiles $PreservedFiles `
            -ServerOwnedDirectories $ServerOwnedDirectories `
            -ServerOwnedThemeFiles $ServerOwnedThemeFiles
    }

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
        Write-DeployStep "Would back up $($overlayPlan.SitePath) to $(Join-Path $overlayPlan.BackupDirectory '<timestamp>')."
        Write-DeployStep "Would stop app pool '$AppPoolName', copy the artifact over $SitePath, then restart it."
        # Read off the overlay plan, and never off the script's lists directly.
        # These four lines are the promise the operator approves, and the plan
        # is what Invoke-InPlaceOverlay turns into robocopy exclusions, so a
        # list the copy ignores cannot appear here as if it were kept.
        #
        # InPlace only, like the whole of this block. The dedicated-site branch
        # replaces the directory wholesale and keeps none of these; a line that
        # said otherwise used to sit in an arm here that could never run.
        Write-DeployStep "Would preserve directories: $($overlayPlan.PreservedDirectories -join ', ')"
        Write-DeployStep "Would preserve files: $($overlayPlan.PreservedFiles -join ', ')"
        Write-DeployStep "Would leave server-owned paths untouched: $($overlayPlan.ServerOwnedDirectories -join ', ')"
        Write-DeployStep "Would keep this site's own theme override files: $(if ($overlayPlan.ThemeOverrides.Count -gt 0) { $overlayPlan.ThemeOverrides -join ', ' } else { 'none found' })"
        # Asked of the merge rather than worked out again here. A dry run returns
        # before the artifact is downloaded, so there is no incoming file yet to
        # merge against -- but which server-owned settings this site has is the
        # read half of that merge, and it is the half the plan is about.
        #
        # The operator reads this line to check that the values the site depends on
        # are the ones the deploy has found. A production plan that reports "none
        # found" for PasswordKey is the signal to stop. Worked out twice, the two
        # answers drifted, and the one the operator reads was the wrong one.
        $plannedWebConfigPath = Join-Path $SitePath 'web.config'
        if (Test-Path $plannedWebConfigPath) {
            $planned = Get-ServerOwnedWebConfigSettings `
                -ExistingWebConfig (Get-Content -Raw -Path $plannedWebConfigPath) `
                -AppSettingKeys $ServerOwnedAppSettings `
                -AppSettingKeyPrefixes $ServerOwnedAppSettingPrefixes

            $plannedCarry = @($planned.OwnedKeys)
            if (![string]::IsNullOrWhiteSpace($planned.MachineKey)) { $plannedCarry += 'machineKey' }
            Write-DeployStep "Would carry this site's own web.config settings across: $(if ($plannedCarry.Count -gt 0) { $plannedCarry -join ', ' } else { 'none found' })"

            # Candidates, not a promise. Each one is carried only where the
            # artifact registers no prefix of its own, and the artifact is not here
            # yet -- so this line names what will be considered, and the apply run's
            # own line names what was carried.
            $plannedPrefixes = @($planned.Registrations.Keys)
            Write-DeployStep "Would consider carrying this site's control registrations, for any the artifact does not register itself: $(if ($plannedPrefixes.Count -gt 0) { $plannedPrefixes -join ', ' } else { 'none found' })"
        }
        else {
            Write-DeployStep "Would carry this site's own web.config settings across: there is no web.config at $plannedWebConfigPath."
        }
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

    # Read before either branch runs, because both destroy it: the dedicated
    # site by deleting the directory, the in-place copy by writing the
    # artifact's file over the top. The site's own web.config carries values
    # nothing else on this box has a copy of -- see
    # Merge-ServerOwnedWebConfigSettings. It was read twice, in ten identical
    # lines, once inside each branch.
    $existingWebConfig = ''
    $existingWebConfigPath = Join-Path $SitePath 'web.config'
    if (Test-Path $existingWebConfigPath) {
        $existingWebConfig = Get-Content -Raw -Path $existingWebConfigPath
    }

    # One name per branch, and the only thing left to decide here is which one.
    # Both hand back the same record, so nothing below has to know which branch
    # ran in order to know whether a variable exists -- a question this file
    # asked three times and got wrong once.
    $deployed = if ($Mode -eq 'DedicatedSite') {
        Invoke-DedicatedSiteReplace `
            -SitePath $SitePath `
            -ExtractPath $ExtractPath `
            -SiteName $SiteName `
            -AppPoolName $AppPoolName `
            -HostName $HostName `
            -CertificateThumbprint $CertificateThumbprint `
            -ConnectionString $ConnectionString `
            -ExistingWebConfig $existingWebConfig `
            -PreservedFiles $PreservedFiles `
            -SharedAssetSourcePath $SharedAssetSourcePath `
            -SharedAssetDirectories $SharedAssetDirectories `
            -ServerOwnedDirectories $ServerOwnedDirectories `
            -ServerOwnedThemeFiles $ServerOwnedThemeFiles
    }
    else {
        # The plan made above the dry-run fork, so what this copies around is
        # what a dry run of the same inputs reported.
        Invoke-InPlaceOverlay `
            -Plan $overlayPlan `
            -Sha $Sha `
            -ManifestPath $ManifestPath `
            -ConnectionString $ConnectionString `
            -ExistingWebConfig $existingWebConfig
    }

    Write-DeploymentManifest -Target $DeploymentTarget -EnvironmentName $EnvironmentName -Mode $Mode `
        -Sha $Sha -ArtifactGcsPath $ArtifactGcsPath -HostName $HostName -EnvironmentPath $EnvironmentPath

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
        $diagnosticsUri = $null
        try { $diagnosticsUri = Save-UnhealthyDiagnostics -SiteRoot $SitePath -Url "https://$HostName/" }
        catch { Write-Warning "Could not collect diagnostics: $($_.Exception.Message)" }

        # In the thrown message and not only in the log above. The exception is
        # what the workflow surfaces and what the operator reads first; a report
        # nobody is told about is a report nobody opens.
        $diagnosticsHint = if ($diagnosticsUri) { " Diagnostics: gsutil cat $diagnosticsUri" } else { ' Diagnostics were not collected.' }

        # Asked of the record the branch handed back, not of $Mode. Only a branch
        # that copied the site aside can offer "roll back from here", and only
        # that branch takes the reading that says whether restoring those files
        # is enough on its own. Both facts arrive together or neither does.
        if (![string]::IsNullOrWhiteSpace($deployed.BackupPath)) {
            $migrationHint = ''
            $postDeployMigrationFingerprint = Get-MigrationFingerprint -SiteRoot $SitePath
            if ($postDeployMigrationFingerprint -ne $deployed.PreDeployMigrationFingerprint) {
                # The files are only half the state. Rock migrates on first
                # request, so by the time a health check fails the schema may
                # already be the new version, and putting the old binaries back
                # on their own leaves them talking to a schema they do not know.
                $migrationHint = " Database migrations ran during this deploy (MigrationLog.csv changed), so restoring files alone is NOT a rollback -- restore the pre-deploy database backup as well, or the old assemblies will run against the new schema."
            }
            throw "Deploy completed but the site did not become healthy. Roll back from $($deployed.BackupPath) if needed.$migrationHint$diagnosticsHint"
        }
        throw "Deploy completed but https://$HostName/ did not become healthy within $HealthCheckTimeoutSeconds seconds.$diagnosticsHint"
    }

    # After the health check and not instead of it. Health is "the app domain
    # started and routes"; this is "Rock renders a page". A deploy can pass the
    # first and fail the second, and the difference is invisible from a status
    # code -- see Invoke-DeploySmokeCheck.
    #
    # It does not fail the deploy. The site is up by the definition this pipeline
    # has always used, an operator is reading this log, and the useful thing to
    # hand them is the evidence, not a red run they have to re-do. So collect the
    # diagnostics the same way a health failure would and say where they are.
    if (-not (Invoke-DeploySmokeCheck -HostName $HostName)) {
        Write-DeployStep "The site is healthy but the smoke check did not pass. Collecting diagnostics; this deploy is not being failed."
        try {
            $smokeDiagnosticsUri = Save-UnhealthyDiagnostics -SiteRoot $SitePath -Url "https://$HostName/"
            if ($smokeDiagnosticsUri) { Write-DeployStep "Smoke-check diagnostics: gsutil cat $smokeDiagnosticsUri" }
        }
        catch { Write-Warning "Could not collect smoke-check diagnostics: $($_.Exception.Message)" }
    }

    # Repeated at the end on purpose. It was printed once, before the copy, and by
    # now it is thousands of characters up a log somebody is reading because
    # something went wrong. Only one of the two branches has anywhere to roll back
    # to -- a dedicated site is replaced wholesale -- and it says so by handing
    # back a backup path, which is a question that can be asked without knowing
    # which branch ran.
    if (![string]::IsNullOrWhiteSpace($deployed.BackupPath)) {
        Write-DeployStep "Done. Roll back with: robocopy $($deployed.BackupPath) $SitePath /E"
    }
    else {
        Write-DeployStep "Done."
    }
}
finally {
    if ($HasLock) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
}
