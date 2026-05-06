<#
.SYNOPSIS
Issues or renews Let's Encrypt certificates for deployed PR test environments.

.DESCRIPTION
Runs on the Windows IIS host through the PR environment command queue. It uses
win-acme HTTP-01 self-hosting, so the caller must temporarily allow public TCP
80 to this VM while the command runs. IIS is stopped only for the ACME challenge
window, then restarted and each renewed certificate is rebound to its PR site.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs",

    [Parameter(Mandatory = $false)]
    [string]
    $DeployRoot = "C:\RockDeploy",

    [Parameter(Mandatory = $false)]
    [int]
    $RenewWithinDays = 30,

    [Parameter(Mandatory = $false)]
    [string]
    $WinAcmeDownloadUrl = "https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module WebAdministration

$WinAcmeRoot = Join-Path $DeployRoot "win-acme"
$WinAcmeExe = Join-Path $WinAcmeRoot "wacs.exe"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-WinAcme {
    if (Test-Path $WinAcmeExe) { return }

    Ensure-Directory -Path $WinAcmeRoot
    $zipPath = Join-Path $WinAcmeRoot "win-acme.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $WinAcmeDownloadUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $WinAcmeRoot -Force
    if (!(Test-Path $WinAcmeExe)) {
        throw "win-acme executable was not found at $WinAcmeExe after extraction."
    }
}

function Get-DeployedPrEnvironmentManifests {
    if (!(Test-Path $EnvironmentRoot)) { return @() }

    return @(Get-ChildItem -Path $EnvironmentRoot -Filter env.json -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Get-Content -Raw -Path $_.FullName | ConvertFrom-Json } catch { $null }
        } |
        Where-Object { $null -ne $_ -and $_.status -eq 'deployed' -and ![string]::IsNullOrWhiteSpace($_.hostName) })
}

function Get-UsableLetsEncryptCertificate {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $minimumExpiration = (Get-Date).AddDays($RenewWithinDays)
    return Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            (($_.DnsNameList -contains $HostName) -or ($_.Subject -eq "CN=$HostName")) -and
            ($_.Issuer -match "Let's Encrypt") -and
            ($_.NotAfter -gt $minimumExpiration)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function Get-NewestLetsEncryptCertificate {
    param([Parameter(Mandatory = $true)][string]$HostName)

    return Get-ChildItem Cert:\LocalMachine\My |
        Where-Object {
            (($_.DnsNameList -contains $HostName) -or ($_.Subject -eq "CN=$HostName")) -and
            ($_.Issuer -match "Let's Encrypt")
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function Invoke-WinAcmeForHost {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $args = @(
        '--source', 'manual',
        '--host', $HostName,
        '--validation', 'selfhosting',
        '--validationmode', 'http-01',
        '--store', 'certificatestore',
        '--certificatestore', 'My',
        '--accepttos',
        '--emailaddress', 'justin.barnett@268generation.com',
        '--notaskscheduler',
        '--verbose'
    )

    Write-Host "Requesting Let's Encrypt certificate for $HostName using HTTP-01 self-hosting."
    & $WinAcmeExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "win-acme failed for $HostName with exit code $LASTEXITCODE."
    }
}

function Bind-CertificateToSite {
    param(
        [Parameter(Mandatory = $true)][string]$SiteName,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )

    $binding = Get-WebBinding -Name $SiteName -Protocol https -HostHeader $HostName -ErrorAction SilentlyContinue
    if ($null -eq $binding) {
        New-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $HostName -SslFlags 1 | Out-Null
        $binding = Get-WebBinding -Name $SiteName -Protocol https -HostHeader $HostName
    }

    $binding.AddSslCertificate($Thumbprint, 'My')
}

Ensure-WinAcme
$manifests = Get-DeployedPrEnvironmentManifests
if ($manifests.Count -eq 0) {
    Write-Host "No deployed PR environments found under $EnvironmentRoot."
    return
}

$hostsNeedingCertificate = @()
foreach ($manifest in $manifests) {
    $hostName = [string]$manifest.hostName
    $currentCert = Get-UsableLetsEncryptCertificate -HostName $hostName
    if ($null -eq $currentCert) {
        $hostsNeedingCertificate += $hostName
    }
    else {
        Write-Host "Certificate for $hostName is valid until $($currentCert.NotAfter); renewal not needed."
    }
}

if ($hostsNeedingCertificate.Count -gt 0) {
    Write-Host "Stopping IIS for HTTP-01 self-hosting challenge."
    Stop-Service W3SVC -Force -ErrorAction Continue
    Start-Sleep -Seconds 5

    try {
        foreach ($hostName in ($hostsNeedingCertificate | Sort-Object -Unique)) {
            Invoke-WinAcmeForHost -HostName $hostName
        }
    }
    finally {
        Write-Host "Restarting IIS after certificate challenge."
        Start-Service W3SVC -ErrorAction Continue
    }
}

foreach ($manifest in $manifests) {
    $hostName = [string]$manifest.hostName
    $siteName = [string]$manifest.siteName
    $appPoolName = [string]$manifest.appPoolName
    $cert = Get-NewestLetsEncryptCertificate -HostName $hostName

    if ($null -eq $cert) {
        throw "No Let's Encrypt certificate is available for $hostName after renewal."
    }

    Bind-CertificateToSite -SiteName $siteName -HostName $hostName -Thumbprint $cert.Thumbprint
    if (![string]::IsNullOrWhiteSpace($appPoolName) -and (Test-Path "IIS:\AppPools\$appPoolName")) {
        Start-WebAppPool -Name $appPoolName -ErrorAction Continue
    }
    if (Test-Path "IIS:\Sites\$siteName") {
        Start-Website -Name $siteName -ErrorAction Continue
    }

    Write-Host "Bound Let's Encrypt certificate for $hostName to $siteName; expires $($cert.NotAfter)."
}
