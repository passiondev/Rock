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
    $CertificateThumbprint = $env:PR_TEST_CERTIFICATE_THUMBPRINT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

    if (![string]::IsNullOrWhiteSpace($Thumbprint)) {
        $httpsBinding.AddSslCertificate($Thumbprint, "My")
    }
}

function Write-EnvironmentManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $Values | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8 -Force
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

    Write-Host "Deploying $SiteName from $ArtifactGcsPath to $SitePath"

    Stop-PrEnvironmentAppPool -Name $AppPoolName

    if (Test-Path $ArtifactPath) {
        Remove-Item $ArtifactPath -Force
    }

    & gsutil cp $ArtifactGcsPath $ArtifactPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download artifact from $ArtifactGcsPath."
    }

    if (Test-Path $ExtractPath) {
        Remove-Item $ExtractPath -Recurse -Force
    }
    Ensure-Directory -Path $ExtractPath
    Expand-Archive -Path $ArtifactPath -DestinationPath $ExtractPath -Force

    if (Test-Path $SitePath) {
        Remove-Item $SitePath -Recurse -Force
    }
    Move-Item -Path $ExtractPath -Destination $SitePath

    $RuntimeConfigScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Set-PrEnvironmentRuntimeConfiguration.ps1"
    & $RuntimeConfigScript -PrNumber $PrNumber -SitePath $SitePath -EnvironmentPath $EnvironmentPath -SandboxConnectionString $SandboxConnectionString
    Ensure-AppPool -Name $AppPoolName
    Ensure-Website -Name $SiteName -PhysicalPath $SitePath -HostHeader $HostName -PoolName $AppPoolName -Thumbprint $CertificateThumbprint

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
    Write-EnvironmentManifest -Path $ManifestPath -Values $manifest

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
