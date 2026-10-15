<#
    Three checks that all exist because of the same mistake, made in three places:
    believing a deploy succeeded on evidence that does not actually say so.

    Assert-DeployedCoreVersion
        robocopy reports success for a run in which individual files were skipped.
        bin\Rock.dll is the file most likely to be locked and least survivable to
        skip, and nothing downstream notices -- the old core assembly may well
        start, leaving a site that is half one Rock version and half another.

    Invoke-DeploySmokeCheck
        Test-EnvironmentHealth passing means the app domain started and routes a
        request. On 2026-09-14 that reasoning was applied to a 302 and reported
        as "site is up at 0.045s"; the 302 was a Cloudflare maintenance rule
        answered at the edge, and Rock was returning 500 to everything behind it.
        __VIEWSTATE is the cheapest proof that Rock itself rendered the response:
        every ASP.NET WebForms page emits it, and nothing that is not ASP.NET
        does.

    Get-MigrationFingerprint
        The backup covers the file system. Rock migrates the database on first
        request after a deploy, so once migrations have run, restoring files
        alone leaves old binaries against a new schema -- a worse state than the
        one being rolled back from. The rollback advice had no way to know that
        and said "roll back from $backupPath" either way.

    And one that exists because of the same mistake made the other way round:
    believing a deploy failed on evidence that does not say so.

    Test-EnvironmentHealth
        ASP.NET caches an Application_Start failure for the life of the app
        domain, so a site whose first start faulted goes on answering every probe
        with that fault after its cause has cleared. On 2026-08-10 staging was
        reported unhealthy three times over and was serving Rock normally minutes
        after each. Polling again only rereads the cached failure; recycling the
        pool is what discards it, so when it recycles is tested here against a
        clock the tests control.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:DeployScript = Get-RepositoryPath 'Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1'
    . (Import-ScriptFunction -Path $script:DeployScript -Name `
            'Write-DeployStep', 'Ensure-Directory', 'Get-MigrationFingerprint', `
            'Assert-DeployedCoreVersion', 'Invoke-DeploySmokeCheck', 'Write-DeployScriptProvenance', `
            'Save-UnhealthyDiagnostics', 'Test-EnvironmentHealth' `
        -Supplied `
            'DeployStartedUtc', 'DeployStepLogPath', 'Invoke-SiteContentProbe', 'Invoke-SiteProbe', `
            'Write-GcsObjectFromFile', 'EnvironmentName', 'Sha', 'HostName', 'Mode', `
            'AppPoolName', 'SiteName', 'ArtifactGcsPath', 'Stop-EnvironmentAppPool')

    $script:DeployStartedUtc = (Get-Date).ToUniversalTime()
    $script:DeployStepLogPath = ''
}

Describe 'Get-MigrationFingerprint' {

    BeforeEach {
        $script:SiteRoot = Join-Path $TestDrive ('mig-' + [guid]::NewGuid().ToString('n'))
        $script:LogDir = Join-Path $script:SiteRoot 'App_Data/Logs'
        Ensure-Directory -Path $script:LogDir
        $script:LogPath = Join-Path $script:LogDir 'MigrationLog.csv'
    }

    It 'returns nothing when Rock has never migrated on this site' {
        Get-MigrationFingerprint -SiteRoot $script:SiteRoot | Should -BeNullOrEmpty
    }

    It 'returns something once a migration log exists' {
        Set-Content -Path $script:LogPath -Value 'migrated' -NoNewline

        Get-MigrationFingerprint -SiteRoot $script:SiteRoot | Should -Not -BeNullOrEmpty
    }

    It 'changes when the log grows, which is what a migration looks like' {
        Set-Content -Path $script:LogPath -Value 'one' -NoNewline
        $before = Get-MigrationFingerprint -SiteRoot $script:SiteRoot

        Add-Content -Path $script:LogPath -Value 'two'
        $after = Get-MigrationFingerprint -SiteRoot $script:SiteRoot

        $after | Should -Not -Be $before
    }

    It 'stays the same across two reads of an untouched log' {
        Set-Content -Path $script:LogPath -Value 'one' -NoNewline

        Get-MigrationFingerprint -SiteRoot $script:SiteRoot |
            Should -Be (Get-MigrationFingerprint -SiteRoot $script:SiteRoot)
    }

    It 'goes from nothing to something, so a first-ever migration is detectable' {
        # The upgrade case. A site that has never migrated has no log at all, and
        # comparing $null to a fingerprint has to read as "it moved".
        $before = Get-MigrationFingerprint -SiteRoot $script:SiteRoot
        Set-Content -Path $script:LogPath -Value 'first run' -NoNewline
        $after = Get-MigrationFingerprint -SiteRoot $script:SiteRoot

        $before | Should -BeNullOrEmpty
        ($after -ne $before) | Should -BeTrue
    }

    It 'does not throw on a site root that does not exist' {
        { Get-MigrationFingerprint -SiteRoot (Join-Path $TestDrive 'nowhere') } | Should -Not -Throw
    }
}

Describe 'Assert-DeployedCoreVersion' {

    BeforeEach {
        $script:SiteRoot = Join-Path $TestDrive ('ver-site-' + [guid]::NewGuid().ToString('n'))
        $script:ArtifactRoot = Join-Path $TestDrive ('ver-art-' + [guid]::NewGuid().ToString('n'))
        Ensure-Directory -Path (Join-Path $script:SiteRoot 'bin')
        Ensure-Directory -Path (Join-Path $script:ArtifactRoot 'bin')
    }

    It 'says nothing is wrong when neither side has a Rock.dll to compare' {
        # A missing file is not a version mismatch. Whatever is wrong in that case
        # is somebody else's error to report.
        { Assert-DeployedCoreVersion -SiteRoot $script:SiteRoot -ArtifactRoot $script:ArtifactRoot } |
            Should -Not -Throw
    }

    It 'compares the file versions rather than the bytes' {
        # Asserted through the AST rather than by faking a versioned assembly,
        # which cannot be done from a test without a compiler. Content equality
        # would be the wrong check anyway: robocopy can land a byte-identical file
        # and the question is which Rock is on the site.
        $body = Get-ScriptFunctionText -Path $script:DeployScript -Name 'Assert-DeployedCoreVersion'

        $body | Should -Match 'VersionInfo\.FileVersion'
        $body | Should -Not -Match 'Get-FileHash'
    }

    It 'throws rather than warns, because a half-copied bin must not be started' {
        $body = Get-ScriptFunctionText -Path $script:DeployScript -Name 'Assert-DeployedCoreVersion'

        $body | Should -Match 'throw "The copy did not land'
    }
}

Describe 'Invoke-DeploySmokeCheck' {

    BeforeAll {
        # Invoke-SiteContentProbe is the seam. Mocking it rather than the HTTP
        # stack keeps these tests about the decision being made, which is the part
        # that got it wrong in production.
        function Invoke-SiteContentProbe {
            param($Url, $HostHeader, $TimeoutSeconds, $MaxBodyBytes)
            return $script:NextProbe
        }
    }

    It 'passes when Rock rendered the page' {
        $script:NextProbe = @{ StatusCode = 200; Body = '<input name="__VIEWSTATE" value="x" />'; Server = 'Microsoft-IIS/10.0'; Error = '' }

        Invoke-DeploySmokeCheck -HostName 'connect.passion.team' | Should -BeTrue
    }

    It 'fails a 200 with no __VIEWSTATE, which is something other than Rock answering' {
        # The maintenance-page case. A body that is not a WebForms render means a
        # static document, an IIS placeholder or a proxy replied for the site.
        $script:NextProbe = @{ StatusCode = 200; Body = '<html><body>We are down for maintenance.</body></html>'; Server = 'cloudflare'; Error = '' }

        Invoke-DeploySmokeCheck -HostName 'connect.passion.team' -WarningAction SilentlyContinue |
            Should -BeFalse
    }

    It 'fails a 500, because a site that routes but cannot render its login page is broken' {
        $script:NextProbe = @{ StatusCode = 500; Body = 'Server Error in Application'; Server = 'Microsoft-IIS/10.0'; Error = 'internal server error' }

        Invoke-DeploySmokeCheck -HostName 'connect.passion.team' -WarningAction SilentlyContinue |
            Should -BeFalse
    }

    It 'fails when nothing answered at all' {
        $script:NextProbe = @{ StatusCode = 0; Body = ''; Server = ''; Error = 'connection refused' }

        Invoke-DeploySmokeCheck -HostName 'connect.passion.team' -WarningAction SilentlyContinue |
            Should -BeFalse
    }

    It 'treats a 404 as proving nothing rather than as a failure' {
        # Where the login page lives is a routing choice a site is entitled to
        # make, and failing a production deploy that is genuinely healthy costs
        # more than this signal is worth.
        $script:NextProbe = @{ StatusCode = 404; Body = 'Not Found'; Server = 'Microsoft-IIS/10.0'; Error = '' }

        Invoke-DeploySmokeCheck -HostName 'connect.passion.team' | Should -BeTrue
    }

    It 'stays on the loopback and carries the host name as a header' {
        # The whole point of the probe is to bypass the CDN that answered for the
        # site last time. A public URL here would ask the edge the same question
        # and get the same misleading answer.
        $body = Get-ScriptFunctionText -Path $script:DeployScript -Name 'Invoke-DeploySmokeCheck'

        $body | Should -Match 'https://127\.0\.0\.1/Login'
        $body | Should -Match '-HostHeader \$HostName'
    }
}

Describe 'Write-DeployScriptProvenance' {

    BeforeEach {
        $script:ScriptDir = Join-Path $TestDrive ('prov-' + [guid]::NewGuid().ToString('n'))
        Ensure-Directory -Path $script:ScriptDir
        $script:FakeScript = Join-Path $script:ScriptDir ('Deploy-RockEnvironment' + '.ps1')
        Set-Content -Path $script:FakeScript -Value '# a deploy script' -NoNewline
        $script:StatePath = Join-Path $script:ScriptDir 'script-sync-state.json'
    }

    It 'does not throw when the script refresh has never recorded anything' {
        { Write-DeployScriptProvenance -ScriptPath $script:FakeScript } | Should -Not -Throw
    }

    It 'reads the state the agent writes' {
        @{
            lastRunUtc  = '2026-09-15T03:00:00.0000000Z'
            prefix      = 'pr-environments/bootstrap/latest/'
            objectsSeen = 8
            files       = @(@{ name = 'Deploy-RockEnvironment.ps1'; status = 'refreshed'; detail = '2116 chars' })
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StatePath

        { Write-DeployScriptProvenance -ScriptPath $script:FakeScript } | Should -Not -Throw
    }

    It 'survives a state file that is not valid JSON' {
        # It is a diagnostic. A broken one must not be able to fail a deploy that
        # has not started doing anything yet.
        Set-Content -Path $script:StatePath -Value '{ this is not json'

        { Write-DeployScriptProvenance -ScriptPath $script:FakeScript } | Should -Not -Throw
    }

    It 'survives being pointed at a path that does not exist' {
        # Assembled rather than written as a literal. test_powershell_job.py reads
        # every quoted .ps1 literal in this directory as a script that must exist
        # under Deployment/, and a deliberately absent path is not one -- rightly,
        # since that check is what catches a suite still loading a renamed script.
        $absent = Join-Path $TestDrive ('no-such-script' + '.ps1')

        { Write-DeployScriptProvenance -ScriptPath $absent } | Should -Not -Throw
    }

    It 'hashes the file, so two different scripts do not report the same version' {
        $body = Get-ScriptFunctionText -Path $script:DeployScript -Name 'Write-DeployScriptProvenance'

        $body | Should -Match 'Get-FileHash'
        $body | Should -Match 'SHA256'
    }
}

Describe 'Save-UnhealthyDiagnostics' {
    <#
        This report already did its job once and nobody found out. On 2026-09-14 it
        ran, uploaded 184,870 bytes naming DigitalSignatureComponent 72 times, and
        said so through Write-Host -- which the command queue does not capture. The
        deploy log carried no trace of it, the thrown error named only the backup
        path, and roughly 40 minutes went into rediscovering by hand what was
        already sitting in the bucket.

        It also collected the wrong logs. Rock writes RockExceptions.csv,
        RockApplication.csv and MigrationLog.csv; the filter was '*.log', which
        matched none of them and picked up a stale Rock.log from an older logging
        config instead, so the report carried year-old Twilio webhook noise and
        none of the startup failure.
    #>

    BeforeAll {
        # The three seams: where it uploads, how it probes, and what the page
        # returns. Stubbed so these tests are about what the function collects and
        # what it hands back, which is the part that was wrong.
        function Write-GcsObjectFromFile {
            param($Bucket, $ObjectName, $Path)
            $script:UploadedFrom = $Path
            $script:UploadedTo = "$Bucket/$ObjectName"
        }
        function Invoke-SiteProbe {
            param($Url, $HostHeader, $TimeoutSeconds)
            return @{ Ok = $false; StatusCode = 500; Error = 'internal server error' }
        }
        function Invoke-WebRequest {
            param($Uri, $TimeoutSec, [switch]$UseBasicParsing, $ErrorAction)
            return [pscustomobject]@{ StatusCode = 500; Content = 'Server Error in Application' }
        }
    }

    BeforeEach {
        $script:SiteRoot = Join-Path $TestDrive ('diag-' + [guid]::NewGuid().ToString('n'))
        $script:LogDir = Join-Path $script:SiteRoot 'App_Data/Logs'
        Ensure-Directory -Path $script:LogDir

        # The function reads these from the script scope, where they are the
        # deploy's own parameters. All seven, because it reads seven. Mode and
        # SiteName were missing until the import started naming what it reaches
        # for: the report's `Mode:` line was being asserted against a blank, and
        # `Test-Path IIS:\Sites\$SiteName` was asking after a site with no name.
        $script:ArtifactGcsPath = 'gs://connect-file-storage/pr-environments/artifacts/abc.zip'
        $script:EnvironmentName = 'production'
        $script:Sha = 'b883c985a2b9616b860a3cd4eb2470b6a5cac866'
        $script:HostName = 'connect.passion.team'
        $script:Mode = 'DedicatedSite'
        $script:AppPoolName = 'RockProdPool'
        $script:SiteName = 'Rock'
        $script:UploadedFrom = ''
        $script:UploadedTo = ''

        # Where it stages the report before uploading. Unset on a Linux runner,
        # and Join-Path refuses an empty Path.
        $script:PreviousTemp = $env:TEMP
        $env:TEMP = $TestDrive
    }

    AfterEach {
        $env:TEMP = $script:PreviousTemp
    }

    It 'hands back the object it uploaded, so the caller can name it' {
        $uri = Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/"

        @($uri).Count | Should -Be 1 -Because 'a leaked pipeline value here would make the thrown error name an array'
        $uri | Should -BeLike 'gs://connect-file-storage/pr-environments/diagnostics/production/*'
        $uri | Should -BeLike "*$script:Sha.txt"
    }

    It 'heads the report with the deploy it came out of' {
        # Mode and SiteName are two of the seven script-scope values this function
        # reads, and they were the two nobody set -- so the header printed `Mode:`
        # against a blank and asked IIS after a site with no name. Nothing here
        # looked at either line, which is how it stayed that way. The import now
        # names all seven, and this is the half that says what they are for.
        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        $report = Get-Content -Raw $script:UploadedFrom
        $report | Should -Match "Mode:\s+$script:Mode"
        $report | Should -Match "Site $script:SiteName"
    }

    It 'collects the csv logs Rock actually writes' {
        Set-Content -Path (Join-Path $script:LogDir 'RockExceptions.csv') -Value 'TypeLoadException,SystemEmailFieldAttribute'
        Set-Content -Path (Join-Path $script:LogDir 'RockApplication.csv') -Value 'application started'

        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        $report = Get-Content -Raw $script:UploadedFrom
        $report | Should -Match 'RockExceptions\.csv'
        $report | Should -Match 'SystemEmailFieldAttribute'
        $report | Should -Match 'RockApplication\.csv'
    }

    It 'puts the exception log ahead of whatever else is in the directory' {
        # Ordered, not merely included. The tail is capped per file and the reader
        # is looking for one thing; burying it under a year of webhook noise is
        # how the useful half went unread.
        Set-Content -Path (Join-Path $script:LogDir 'Rock.log') -Value 'twilio webhook 2024'
        Set-Content -Path (Join-Path $script:LogDir 'RockExceptions.csv') -Value 'the actual failure'

        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        $report = Get-Content -Raw $script:UploadedFrom
        $report.IndexOf('RockExceptions.csv') | Should -BeLessThan $report.IndexOf('Rock.log')
    }

    It 'still collects a plain .log, because not every box logs the same way' {
        Set-Content -Path (Join-Path $script:LogDir 'Rock.log') -Value 'something happened'

        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        (Get-Content -Raw $script:UploadedFrom) | Should -Match 'something happened'
    }

    It 'says so rather than failing when there are no logs at all' {
        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        (Get-Content -Raw $script:UploadedFrom) | Should -Match '\(no log files\)'
    }

    It 'redacts a password out of anything it picked up' {
        Set-Content -Path (Join-Path $script:LogDir 'RockExceptions.csv') -Value 'Server=db;User ID=rock;Password=hunter2;'

        Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" | Out-Null

        $report = Get-Content -Raw $script:UploadedFrom
        $report | Should -Not -Match 'hunter2'
        $report | Should -Match '<redacted>'
    }

    It 'returns nothing when it cannot tell which bucket to upload to' {
        $script:ArtifactGcsPath = 'not-a-gcs-path'

        $uri = Save-UnhealthyDiagnostics -SiteRoot $script:SiteRoot -Url "https://$script:HostName/" -WarningAction SilentlyContinue

        $uri | Should -BeNullOrEmpty
    }

    It 'reports through Write-DeployStep, which is the only output the queue keeps' {
        # Only the positive half. The matching `Should -Not -Match 'Write-Host'`
        # that used to sit here named this one function, and a sweep of the whole
        # script found fifteen reports outside it doing exactly what it forbade --
        # see StepReporterAdoptionTests in test_environment_deploy.py, which now
        # owns the negative for every function at once. What stays here is the
        # 2026-09-14 finding: this particular line is the one that named the
        # culprit assembly and said nothing where anyone would read it.
        $body = Get-ScriptFunctionText -Path $script:DeployScript -Name 'Save-UnhealthyDiagnostics'

        $body | Should -Match 'Write-DeployStep "Collected diagnostics'
    }
}

Describe 'Test-EnvironmentHealth' {
    <#
        Every decision this function makes is about time: how long to keep
        polling, when a failing site has failed long enough to recycle, and when
        the window is too nearly closed for a recycle to be worth it. So the
        clock is the stand-in that matters. Get-Date answers from $script:Now and
        Start-Sleep moves it forward instead of waiting, which lets a 400-second
        window run in milliseconds and puts every recycle at a time the test can
        state.
    #>

    BeforeAll {
        # The probe is the seam, for the reason Invoke-DeploySmokeCheck's is: these
        # tests are about what the function does with an answer, not about HTTP.
        # Each call takes the next answer, and the last one repeats, so a list of
        # one is a site that never changes.
        function Invoke-SiteProbe {
            param($Url, $HostHeader, $TimeoutSeconds)
            $script:Probes += @{ Url = $Url; HostHeader = $HostHeader }
            $answers = @($script:ProbeAnswers)
            return $answers[[Math]::Min(@($script:Probes).Count, $answers.Count) - 1]
        }

        # The two halves of a recycle, recorded in the order they happen and
        # stamped with the fake clock, because when and in what order is the
        # whole of what is being asked of them.
        function Stop-EnvironmentAppPool {
            param([Parameter(Mandatory = $true)][string]$Name)
            $script:PoolEvents += "stop:$Name"
            $script:Recycles += $script:Now
        }

        # Advanced, because the call passes -ErrorAction. The WebAdministration
        # cmdlet this stands in for does not exist off Windows.
        function Start-WebAppPool {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$Name)
            $script:PoolEvents += "start:$Name"
        }

        Mock Get-Date { $script:Now }
        Mock Start-Sleep { $script:Now = $script:Now.AddSeconds($Seconds) }

        # Write-DeployStep runs for real and writes every line to the step log as
        # well, which is what these tests read. A 400-second window is forty
        # attempts, and forty timestamped lines on the console say nothing the
        # file does not.
        Mock Write-Host { }

        $script:Healthy = @{ Ok = $true; StatusCode = 200; Error = '' }
        $script:Failing = @{ Ok = $false; StatusCode = 500; Error = 'internal server error' }
        $script:Refused = @{ Ok = $false; StatusCode = 0; Error = 'connection refused' }
        $script:PublicUrl = 'https://staging.connect.passion.team/'
    }

    BeforeEach {
        $script:Now = [datetime]'2026-10-15T00:00:00'
        $script:Start = $script:Now
        $script:Probes = @()
        $script:ProbeAnswers = @($script:Failing)
        $script:PoolEvents = @()
        $script:Recycles = @()

        $script:DeployStepLogPath = Join-Path $TestDrive ('health-' + [guid]::NewGuid().ToString('n') + '.log')

        # The function sets both of these process-wide, and every other suite in
        # this run shares the process.
        $script:PreviousCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
        $script:PreviousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    }

    AfterEach {
        $script:DeployStepLogPath = ''
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $script:PreviousCertificateCallback
        [Net.ServicePointManager]::SecurityProtocol = $script:PreviousSecurityProtocol
    }

    It 'returns $true on the first healthy answer, and records what the site returned' {
        # A pass returns before the bottom of the loop, where every failed
        # attempt reports. A pass that said nothing would leave a production
        # deploy with no record of what the site answered, which is the detail
        # the next argument about that deploy turns on.
        $script:ProbeAnswers = @($script:Healthy)

        $result = Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 60

        @($result).Count | Should -Be 1 -Because 'the deploy body tests this as one boolean, and an array of anything is truthy'
        $result | Should -BeOfType [bool]
        $result | Should -BeTrue
        @($script:Probes).Count | Should -Be 1
        (Get-Content -Raw -Path $script:DeployStepLogPath) | Should -Match 'Health check passed.*200'
    }

    It 'probes the loopback, carrying the public host name as the Host header' {
        # This VM cannot reliably reach its own public address. On 2026-08-11 the
        # probe to the public name failed for 900 seconds while the same URL
        # answered 302 from off the box, and the deploy went red on a site that
        # was serving. The loopback is the same IIS site and the same app domain.
        $script:ProbeAnswers = @($script:Healthy)

        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 60 -HostHeader 'staging.connect.passion.team' | Out-Null

        $script:Probes[0].Url | Should -BeExactly 'https://127.0.0.1/'
        $script:Probes[0].HostHeader | Should -BeExactly 'staging.connect.passion.team'
    }

    It 'probes the URL it was given when there is no host name to carry' {
        $script:ProbeAnswers = @($script:Healthy)

        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 60 | Out-Null

        $script:Probes[0].Url | Should -BeExactly $script:PublicUrl
        $script:Probes[0].HostHeader | Should -BeExactly ''
    }

    It 'keeps polling through a 500 and a refused connection until the site answers' {
        # Rock runs its migrations on the first request after a deploy, so a
        # site that is still starting fails in both of these ways before it
        # comes up. Either one is a reason to wait, not a verdict.
        $script:ProbeAnswers = @($script:Failing, $script:Refused, $script:Healthy)

        $result = Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 300

        $result | Should -BeTrue
        @($script:Probes).Count | Should -Be 3

        # Each failure says what it was, so a timeline that ends in a pass still
        # shows what the site did on the way there.
        $log = Get-Content -Raw -Path $script:DeployStepLogPath
        $log | Should -Match 'HTTP 500'
        $log | Should -Match 'connection refused'
    }

    It 'leaves a site alone that recovers before RecycleAfterSeconds' {
        # Still starting is not the same as poisoned. A recycle here would
        # restart the migrations the site was most of the way through.
        $script:ProbeAnswers = @($script:Failing, $script:Failing, $script:Failing, $script:Healthy)

        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 300 -AppPoolName 'RockStagingPool' -RecycleAfterSeconds 120 |
            Should -BeTrue

        @($script:PoolEvents).Count | Should -Be 0
    }

    It 'recycles a site that stays unhealthy, every RecycleAfterSeconds and not only once' {
        # The 2026-08-10 failure. Retrying alone rereads one cached exception
        # until the window closes; a recycle discards the app domain holding it,
        # and recycling again turns a second bad start into one lost interval
        # rather than a lost deploy.
        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 430 -AppPoolName 'RockStagingPool' -RecycleAfterSeconds 120 -WarningAction SilentlyContinue |
            Out-Null

        $recycles = @($script:Recycles)
        $recycles.Count | Should -BeGreaterOrEqual 2 -Because 'a second bad start is as likely as the first'
        ($recycles[0] - $script:Start).TotalSeconds | Should -BeGreaterOrEqual 120 -Because 'the first recycle waits out one whole interval of failure'
        for ($i = 1; $i -lt $recycles.Count; $i++) {
            ($recycles[$i] - $recycles[$i - 1]).TotalSeconds | Should -BeGreaterOrEqual 120 -Because 'each later one waits out an interval after the last'
        }
    }

    It 'stops the pool and then starts the same pool' {
        # Stopped and never started is a site that is down until somebody
        # notices, and the health check would spend the rest of its window
        # probing a pool it had switched off.
        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 200 -AppPoolName 'RockStagingPool' -RecycleAfterSeconds 120 -WarningAction SilentlyContinue |
            Out-Null

        ($script:PoolEvents -join ',') | Should -BeExactly 'stop:RockStagingPool,start:RockStagingPool'
    }

    It 'does not recycle in the last minute of the window' {
        # A pool restarted with less than a minute left is still starting when
        # the window closes, so the recycle could only ensure the last probes
        # fail. With 150 seconds and a 120-second interval, the one recycle the
        # interval allows would come 30 seconds before the end.
        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 150 -AppPoolName 'RockStagingPool' -RecycleAfterSeconds 120 -WarningAction SilentlyContinue |
            Out-Null

        @($script:PoolEvents).Count | Should -Be 0
    }

    It 'never recycles when it was given no app pool' {
        Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 430 -RecycleAfterSeconds 120 -WarningAction SilentlyContinue |
            Out-Null

        @($script:PoolEvents).Count | Should -Be 0
    }

    It 'returns $false once the window closes, and warns with the last error' {
        # $false rather than a throw: the caller collects diagnostics and words
        # the rollback advice, and only it knows whether there is a backup.
        $result = Test-EnvironmentHealth -Url $script:PublicUrl -TimeoutSeconds 30 `
            -WarningVariable warnings -WarningAction SilentlyContinue

        @($result).Count | Should -Be 1
        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
        @($script:Probes).Count | Should -Be 3 -Because 'a 30-second window polled every 10 seconds is three attempts'
        @($warnings).Count | Should -Be 1
        "$warnings" | Should -Match 'did not pass within 30 seconds'
        "$warnings" | Should -Match 'HTTP 500'
    }
}
