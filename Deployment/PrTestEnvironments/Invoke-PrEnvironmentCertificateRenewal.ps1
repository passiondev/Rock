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

    # In-place environments such as staging keep their manifest outside
    # $EnvironmentRoot on purpose, so walking that one tree missed them entirely
    # and staging was never issued a certificate. Renewal already stops W3SVC
    # service-wide for the HTTP-01 challenge, so including these sites costs no
    # downtime that the PR environments were not already causing them.
    [Parameter(Mandatory = $false)]
    [string[]]
    $AdditionalManifestRoots = @("C:\RockBackups"),

    [Parameter(Mandatory = $false)]
    [string]
    $DeployRoot = "C:\RockDeploy",

    [Parameter(Mandatory = $false)]
    [int]
    $RenewWithinDays = 30,

    [Parameter(Mandatory = $false)]
    [int]
    $PerHostTimeoutSeconds = 180,

    [Parameter(Mandatory = $false)]
    [string]
    $WinAcmeDownloadUrl = "https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.pluggable.zip"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module WebAdministration

$WinAcmeRoot = Join-Path $DeployRoot "win-acme"
$WinAcmeExe = Join-Path $WinAcmeRoot "wacs.exe"
$LogRoot = Join-Path $WinAcmeRoot "logs"

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
    $manifestPaths = @()

    if (Test-Path $EnvironmentRoot) {
        $manifestPaths += @(Get-ChildItem -Path $EnvironmentRoot -Filter env.json -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
    }

    # Only direct children here, never -Recurse: an in-place environment keeps its
    # manifest at <root>\<name>\env.json while its siblings are timestamped site
    # backups. Recursing would pull stale manifests out of those backups and bind
    # certificates from them.
    foreach ($additionalRoot in $AdditionalManifestRoots) {
        if ([string]::IsNullOrWhiteSpace($additionalRoot) -or !(Test-Path $additionalRoot)) { continue }
        $manifestPaths += @(Get-ChildItem -Path $additionalRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'env.json' } |
            Where-Object { Test-Path $_ })
    }

    return @($manifestPaths |
        ForEach-Object {
            try { Get-Content -Raw -Path $_ | ConvertFrom-Json } catch { $null }
        } |
        Where-Object { $null -ne $_ -and $_.status -eq 'deployed' -and ![string]::IsNullOrWhiteSpace($_.hostName) } |
        Group-Object -Property hostName |
        ForEach-Object { $_.Group | Select-Object -First 1 })
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

function Write-WinAcmeLog {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path $Path) {
        Get-Content -Path $Path -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    }
}

function Invoke-WinAcmeForHost {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $wacsArgs = @(
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

    Ensure-Directory -Path $LogRoot
    $safeHost = ($HostName -replace '[^A-Za-z0-9._-]', '_')
    $stdoutLog = Join-Path $LogRoot "wacs-$safeHost.out.log"
    $stderrLog = Join-Path $LogRoot "wacs-$safeHost.err.log"

    # win-acme self-hosting waits on the Let's Encrypt HTTP-01 callback, which never
    # arrives if inbound TCP 80 is blocked or DNS is wrong. Running headless under the
    # command-queue task there is no console to interrupt it, so cap each host with a
    # hard timeout and kill the process rather than let it hang the queue worker.
    Write-Host "Requesting Let's Encrypt certificate for $HostName using HTTP-01 self-hosting (timeout ${PerHostTimeoutSeconds}s)."
    $process = Start-Process -FilePath $WinAcmeExe -ArgumentList $wacsArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

    if (-not $process.WaitForExit($PerHostTimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { Write-Warning "Could not kill win-acme process for ${HostName}: $($_.Exception.Message)" }
        Write-WinAcmeLog -Path $stdoutLog
        Write-WinAcmeLog -Path $stderrLog
        throw "win-acme timed out after $PerHostTimeoutSeconds seconds for $HostName and was terminated."
    }

    # Ensure exit processing completes before reading ExitCode.
    $process.WaitForExit()
    Write-WinAcmeLog -Path $stdoutLog
    Write-WinAcmeLog -Path $stderrLog

    if ($process.ExitCode -ne 0) {
        throw "win-acme failed for $HostName with exit code $($process.ExitCode)."
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
$manifests = @(Get-DeployedPrEnvironmentManifests)
if (@($manifests).Length -eq 0) {
    # Say this loudly and name every root that was searched. A silent early
    # return here is indistinguishable from a successful renewal in the command
    # result, which is exactly how staging went months without a certificate.
    Write-Warning "RENEWAL ISSUED NOTHING: no manifest with status 'deployed' was found under any of: $($EnvironmentRoot), $($AdditionalManifestRoots -join ', '). No certificate was requested or bound."
    return
}

Write-Host "Renewal scope: $(@($manifests).Length) host(s) -- $(($manifests | ForEach-Object { $_.hostName }) -join ', ')"

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

if (@($hostsNeedingCertificate).Length -gt 0) {
    Write-Host "Stopping IIS for HTTP-01 self-hosting challenge."
    Stop-Service W3SVC -Force -ErrorAction Continue
    Start-Sleep -Seconds 5

    try {
        foreach ($hostName in ($hostsNeedingCertificate | Sort-Object -Unique)) {
            # Keep going if one host fails so a single broken environment does not
            # block renewal for the others. A host that genuinely failed is caught
            # below when its certificate is missing during the bind pass.
            try {
                Invoke-WinAcmeForHost -HostName $hostName
            }
            catch {
                Write-Warning "Certificate request failed for ${hostName}: $($_.Exception.Message)"
            }
        }
    }
    finally {
        Write-Host "Restarting IIS after certificate challenge."
        Start-Service W3SVC -ErrorAction Continue
    }
}

# The bind pass used to throw on the first host without a certificate, which made
# one dead environment fail renewal for every healthy one -- a PR environment whose
# DNS or site had gone away took the whole fleet's certificates down with it. Now
# each host is bound independently and the failures are reported together at the
# end, so the command fails only if nothing could be bound.
$bindFailures = @()
$boundCount = 0

foreach ($manifest in $manifests) {
    $hostName = [string]$manifest.hostName
    $siteName = [string]$manifest.siteName
    $appPoolName = [string]$manifest.appPoolName

    try {
        $cert = Get-NewestLetsEncryptCertificate -HostName $hostName
        if ($null -eq $cert) {
            throw "no Let's Encrypt certificate is available after renewal"
        }

        Bind-CertificateToSite -SiteName $siteName -HostName $hostName -Thumbprint $cert.Thumbprint
        if (![string]::IsNullOrWhiteSpace($appPoolName) -and (Test-Path "IIS:\AppPools\$appPoolName")) {
            Start-WebAppPool -Name $appPoolName -ErrorAction Continue
        }
        if (Test-Path "IIS:\Sites\$siteName") {
            Start-Website -Name $siteName -ErrorAction Continue
        }

        $boundCount++
        Write-Host "Bound Let's Encrypt certificate for $hostName to $siteName; expires $($cert.NotAfter)."
    }
    catch {
        $bindFailures += "${hostName}: $($_.Exception.Message)"
        Write-Warning "Could not bind a certificate for ${hostName}: $($_.Exception.Message)"
    }
}

if ($bindFailures.Count -gt 0) {
    Write-Warning "$($bindFailures.Count) of $(@($manifests).Length) environment(s) have no usable certificate:"
    foreach ($failure in $bindFailures) { Write-Warning "  $failure" }

    if ($boundCount -eq 0) {
        throw "No PR environment could be bound to a Let's Encrypt certificate. Failures: $($bindFailures -join '; ')"
    }
}

Write-Host "Certificate renewal complete: $boundCount bound, $($bindFailures.Count) failed."
