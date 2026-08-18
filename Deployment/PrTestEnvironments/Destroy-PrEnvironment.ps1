[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [int]
    $PrNumber,

    [Parameter(Mandatory = $false)]
    [string]
    $EnvironmentRoot = "C:\RockTestEnvs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

$SiteName = "rock-pr-$PrNumber"
$AppPoolName = "rock-pr-$PrNumber"
$EnvironmentPath = Join-Path $EnvironmentRoot "pr-$PrNumber"

if (Test-Path "IIS:\Sites\$SiteName") {
    Remove-Website -Name $SiteName
}

if (Test-Path "IIS:\AppPools\$AppPoolName") {
    $poolState = (Get-WebAppPoolState -Name $AppPoolName).Value
    if ($poolState -ne "Stopped") {
        Stop-WebAppPool -Name $AppPoolName

        # Stop-WebAppPool returns as soon as the stop has been *requested*. Until
        # w3wp.exe actually exits it still holds every file it mapped, and Rock's Bin
        # carries native DLLs -- grpc_csharp_ext.x64.dll, loaded by the Google Cloud
        # client libraries -- which Windows will not unlink while they are mapped into a
        # live process. Deleting the tree before then fails the destroy *after*
        # Remove-Website and Remove-WebAppPool have already run, which leaves the
        # environment half torn down: no site, no app pool, files still on disk.
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if ((Get-WebAppPoolState -Name $AppPoolName).Value -eq "Stopped") {
                break
            }
            Start-Sleep -Seconds 2
        }
    }
    Remove-WebAppPool -Name $AppPoolName
}

if (Test-Path $EnvironmentPath) {
    # The pool reporting Stopped does not prove the worker process has exited, so the
    # delete can still arrive while a handle is closing. Retry instead of failing the
    # command -- but give up eventually and rethrow, because reporting a successful
    # destroy with the directory still present means the next deploy for this PR unpacks
    # on top of whatever was left behind.
    $attempt = 0
    while ($true) {
        try {
            Remove-Item $EnvironmentPath -Recurse -Force -ErrorAction Stop
            break
        }
        catch {
            $attempt++
            if ($attempt -ge 10) {
                throw "Could not remove $EnvironmentPath after $attempt attempts; a process is still holding a file in it. Last error: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 3
        }
    }
}

Write-Host "Destroyed $SiteName if it existed."
