[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ProjectName,
    [switch]$SkipDb,
    [switch]$AutoRollback,
    [switch]$DbRollback,
    [switch]$DryRun,
    [switch]$Help
)

$ScriptRoot = $PSScriptRoot

. "$ScriptRoot\Deploy\logger.ps1"
. "$ScriptRoot\Deploy\helpers.ps1"
. "$ScriptRoot\SecretProviders\secrets.ps1"
. "$ScriptRoot\DbPersistence\db.ps1"

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────

if ($Help -or -not $ProjectName) {
    Write-Host @"
USAGE
  deploy.ps1 <project-name> [flags]

FLAGS
  --skip-db        Skip DB connection check and migrations
  --auto-rollback  Automatically rollback on failure (from step 5 onwards)
  --db-rollback    Include DB Down scripts when auto-rollback triggers
  --dryrun         Simulate all steps without making changes
  --help           Show this help

STEPS
  1  Validate files
  2  Stop application pools / services
  3  Backup sites (+ verify backup integrity)
  4  Unzip artifact files
  5  Deploy sites                          ← rollback triggered from here on failure
  6  Restart application pools / services
  7  Check DB connections
  8  Apply DB migrations (Up scripts)
  9  Close DB connections
  10 Health check sites
  11 Summary

EXAMPLES
  .\deploy.ps1 myapp
  .\deploy.ps1 myapp --auto-rollback --db-rollback
  .\deploy.ps1 myapp --skip-db
  .\deploy.ps1 myapp --dryrun
"@
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP DISPLAY HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Step {
    param([int]$Num, [string]$Desc)
    Write-Log "INFO" ""
    Write-Log "INFO" "┌── STEP $Num : $Desc"
}
function Write-StepOk   { param([string]$Msg) Write-Log "INFO"  "└── OK     : $Msg" }
function Write-StepSkip { param([string]$Msg) Write-Log "INFO"  "└── SKIP   : $Msg" }
function Write-StepFail { param([string]$Msg) Write-Log "ERROR" "└── FAILED : $Msg" }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG LOADING
# ─────────────────────────────────────────────────────────────────────────────

function Get-RootConfig {
    $path = Join-Path $ScriptRoot "config.json"
    if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json }
    return [PSCustomObject]@{}
}

function Get-ProjectConfig {
    param([string]$ConfigDir, [string]$Project)
    $path = Join-Path $ConfigDir "$Project-config.json"
    if (-not (Test-Path $path)) { throw "Project config not found: $path" }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Resolve-Dir {
    param([string]$Configured, [string]$Default)
    if ($Configured) { return $Configured }
    return Join-Path $ScriptRoot $Default
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK (called inline on failure from step 5+)
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-AutoRollback {
    param(
        [string]$BackupZip,
        [string[]]$RestorePaths,
        [string[]]$AppPools,
        [string[]]$Services,
        [hashtable]$ConnStrings,
        [string]$DatabaseDir,
        [string[]]$HealthUrls,
        [string[]]$HealthMethods
    )

    Write-Log "WARN" ""
    Write-Log "WARN" "╔══════════════════════════════════════════════════════╗"
    Write-Log "WARN" "║             AUTO-ROLLBACK TRIGGERED                 ║"
    Write-Log "WARN" "╚══════════════════════════════════════════════════════╝"

    $rbErrors = [System.Collections.Generic.List[string]]::new()

    # Stop pools/services that may have been restarted in step 6
    foreach ($pool in $AppPools) {
        try { Stop-AppPool -Name $pool -DryRun:$DryRun }
        catch { $rbErrors.Add("Stop App Pool '$pool': $_") }
    }
    foreach ($svc in $Services) {
        try { Stop-ServiceSafe -Name $svc -DryRun:$DryRun }
        catch { $rbErrors.Add("Stop Service '$svc': $_") }
    }

    # Restore files
    if ($BackupZip -and (Test-Path $BackupZip)) {
        try { Restore-Backup -ZipPath $BackupZip -RestorePaths $RestorePaths -DryRun:$DryRun }
        catch { $rbErrors.Add("Restore backup: $_") }
    } else {
        $rbErrors.Add("No backup zip available to restore from")
    }

    # DB Down
    if ($DbRollback -and $ConnStrings -and $DatabaseDir) {
        try { Invoke-DbMigrations -DatabaseDir $DatabaseDir -ConnectionStrings $ConnStrings -Direction Down -DryRun:$DryRun | Out-Null }
        catch { $rbErrors.Add("DB Down migrations: $_") }
    }

    # Restart pools/services
    foreach ($pool in $AppPools) {
        try { Start-AppPool -Name $pool -DryRun:$DryRun }
        catch { $rbErrors.Add("Start App Pool '$pool': $_") }
    }
    foreach ($svc in $Services) {
        try { Start-ServiceSafe -Name $svc -DryRun:$DryRun }
        catch { $rbErrors.Add("Start Service '$svc': $_") }
    }

    # Health check after rollback
    for ($hi = 0; $hi -lt $HealthUrls.Count; $hi++) {
        $url    = $HealthUrls[$hi]
        $method = if ($hi -lt $HealthMethods.Count) { $HealthMethods[$hi] } else { "GET" }
        try { Invoke-HealthCheck -Url $url -Method $method -Retries 3 -DryRun:$DryRun }
        catch { $rbErrors.Add("Health check after rollback '$url': $_") }
    }

    if ($rbErrors.Count -gt 0) {
        Write-Log "ERROR" ""
        Write-Log "ERROR" "Rollback completed with errors:"
        foreach ($e in $rbErrors) { Write-Log "ERROR" "  - $e" }
        Show-ManualRollbackInstructions -BackupZip $BackupZip -RestorePaths $RestorePaths `
            -AppPools $AppPools -Services $Services -ConnStrings $ConnStrings `
            -DatabaseDir $DatabaseDir -HealthUrls $HealthUrls
    } else {
        Write-Log "INFO" "Rollback completed successfully"
    }
}

function Show-ManualRollbackInstructions {
    param(
        [string]$BackupZip,
        [string[]]$RestorePaths,
        [string[]]$AppPools,
        [string[]]$Services,
        [hashtable]$ConnStrings,
        [string]$DatabaseDir,
        [string[]]$HealthUrls
    )
    $line = "═" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Red
    Write-Host "  MANUAL ROLLBACK INSTRUCTIONS" -ForegroundColor Red
    Write-Host "  Automatic rollback encountered errors." -ForegroundColor Yellow
    Write-Host "  Please perform these steps manually as Administrator:" -ForegroundColor Yellow
    Write-Host $line -ForegroundColor Red
    Write-Host ""

    Write-Host "  1. STOP APPLICATION POOLS" -ForegroundColor Cyan
    foreach ($pool in $AppPools) {
        Write-Host "       Import-Module WebAdministration"
        Write-Host "       Stop-WebAppPool -Name `"$pool`""
        Write-Host "     -- or --"
        Write-Host "       appcmd stop apppool /apppool.name:`"$pool`""
        Write-Host ""
    }
    foreach ($svc in $Services) {
        Write-Host "       Stop-Service -Name `"$svc`" -Force"
        Write-Host ""
    }

    Write-Host "  2. RESTORE FILES FROM BACKUP" -ForegroundColor Cyan
    Write-Host "     Backup: $BackupZip"
    Write-Host "     Extract the zip and copy each folder to its destination:"
    foreach ($p in $RestorePaths) {
        $leaf = Split-Path $p -Leaf
        Write-Host "       `$tmp = `"$env:TEMP\rb_manual`""
        Write-Host "       Expand-Archive -Path `"$BackupZip`" -DestinationPath `$tmp -Force"
        Write-Host "       Copy-Item `"`$tmp\$leaf`" -Destination `"$p`" -Recurse -Force"
        Write-Host ""
    }

    if ($ConnStrings -and $DatabaseDir -and (Test-Path $DatabaseDir)) {
        Write-Host "  3. DB DOWN SCRIPTS (run in order)" -ForegroundColor Cyan
        $folders = Get-ChildItem -Path $DatabaseDir -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $folders) {
            $csKey   = $folder.Name
            $downDir = Join-Path $folder.FullName "Down"
            if (-not (Test-Path $downDir)) { continue }
            $scripts = Get-ChildItem -Path $downDir -Filter "*.sql" |
                       Sort-Object { [int]($_.Name -replace '^(\d+).*','$1') }
            if (-not $scripts) { continue }
            Write-Host "     Connection key : $csKey"
            if ($ConnStrings.ContainsKey($csKey)) {
                $provider = try { Get-DbProvider $ConnStrings[$csKey] } catch { "unknown" }
                Write-Host "     Provider       : $provider"
            }
            Write-Host "     Scripts to run (in this order):"
            foreach ($s in $scripts) {
                Write-Host "       $($s.FullName)"
            }
            Write-Host ""
        }
    }

    $poolNum = if ($ConnStrings -and $DatabaseDir) { 4 } else { 3 }
    Write-Host "  $poolNum. RESTART APPLICATION POOLS" -ForegroundColor Cyan
    foreach ($pool in $AppPools) {
        Write-Host "       Start-WebAppPool -Name `"$pool`""
        Write-Host "     -- or --"
        Write-Host "       appcmd start apppool /apppool.name:`"$pool`""
        Write-Host ""
    }
    foreach ($svc in $Services) {
        Write-Host "       Start-Service -Name `"$svc`""
        Write-Host ""
    }

    $hcNum = $poolNum + 1
    Write-Host "  $hcNum. VERIFY HEALTH" -ForegroundColor Cyan
    foreach ($url in $HealthUrls) {
        Write-Host "       Invoke-WebRequest -Uri `"$url`" -Method GET -UseBasicParsing"
        Write-Host ""
    }

    Write-Host $line -ForegroundColor Red
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Show-DeploySummary {
    param(
        [string]$Project,
        [string]$Status,
        [datetime]$StartTime,
        [hashtable]$StepResults,
        [string]$BackupZip,
        [int]$BackupFileCount,
        [string[]]$SitesDeployed,
        [string[]]$ServicesDeployed,
        [int]$DbScriptsRun,
        [string[]]$HealthResults,
        [string]$FailureReason
    )
    $duration = (Get-Date) - $StartTime
    $durStr   = "{0:D2}:{1:D2}:{2:D2}" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
    $color    = if ($Status -eq "SUCCESS") { "Green" } else { "Red" }
    $line     = "═" * 60

    Write-Host ""
    Write-Host $line -ForegroundColor $color
    Write-Host ("  DEPLOYMENT SUMMARY — {0,-38}" -f $Project) -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
    Write-Host ("  Status   : {0}" -f $Status) -ForegroundColor $color
    Write-Host ("  Started  : {0}" -f $StartTime.ToString("HH:mm:ss"))
    Write-Host ("  Finished : {0}" -f (Get-Date).ToString("HH:mm:ss"))
    Write-Host ("  Duration : {0}" -f $durStr)
    if ($DryRun) { Write-Host "  Mode     : DRY RUN — no changes made" -ForegroundColor Magenta }

    Write-Host ""
    Write-Host "  STEPS" -ForegroundColor Cyan
    $stepNames = @(
        "Validate files",
        "Stop application pools",
        "Backup sites",
        "Unzip files",
        "Deploy sites",
        "Restart application pools",
        "Check DB connections",
        "Apply DB migrations",
        "Close DB connections",
        "Health check sites",
        "Done"
    )
    for ($i = 1; $i -le 11; $i++) {
        $r   = $StepResults[$i]
        $sym = switch ($r) { "OK" {"✓"} "SKIP" {"–"} "FAIL" {"✗"} default {"?"} }
        $c   = switch ($r) { "OK" {"Green"} "SKIP" {"DarkGray"} "FAIL" {"Red"} default {"Yellow"} }
        Write-Host ("  [{0}] Step {1,2}  {2}" -f $sym, $i, $stepNames[$i - 1]) -ForegroundColor $c
    }

    if ($SitesDeployed) {
        Write-Host ""
        Write-Host "  SITES DEPLOYED" -ForegroundColor Cyan
        foreach ($s in $SitesDeployed) { Write-Host "    $s" }
    }
    if ($ServicesDeployed) {
        Write-Host ""
        Write-Host "  SERVICES DEPLOYED" -ForegroundColor Cyan
        foreach ($s in $ServicesDeployed) { Write-Host "    $s" }
    }
    if ($BackupZip) {
        Write-Host ""
        Write-Host "  BACKUP" -ForegroundColor Cyan
        Write-Host "    $(Split-Path $BackupZip -Leaf) ($BackupFileCount files)"
        Write-Host "    $(Split-Path $BackupZip -Parent)"
    }
    if ($DbScriptsRun -gt 0) {
        Write-Host ""
        Write-Host "  DB MIGRATIONS" -ForegroundColor Cyan
        Write-Host "    $DbScriptsRun Up script(s) executed"
    }
    if ($HealthResults) {
        Write-Host ""
        Write-Host "  HEALTH CHECKS" -ForegroundColor Cyan
        foreach ($h in $HealthResults) { Write-Host "    $h" }
    }
    if ($FailureReason) {
        Write-Host ""
        Write-Host "  FAILURE REASON" -ForegroundColor Red
        Write-Host "    $FailureReason" -ForegroundColor Red
    }

    Write-Host $line -ForegroundColor $color
    Write-Host ""
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

$startTime    = Get-Date
$stepResults  = @{ 1="?"; 2="?"; 3="?"; 4="?"; 5="?"; 6="?"; 7="?"; 8="?"; 9="?"; 10="?"; 11="?" }
$exitCode     = 0
$failureReason = $null

# State for rollback
$backupZip      = $null
$backupFileCount = 0
$stoppedPools   = [System.Collections.Generic.List[string]]::new()
$stoppedServices= [System.Collections.Generic.List[string]]::new()
$sitePaths      = [System.Collections.Generic.List[string]]::new()
$servicePaths   = [System.Collections.Generic.List[string]]::new()
$healthUrls     = [System.Collections.Generic.List[string]]::new()
$healthMethods  = [System.Collections.Generic.List[string]]::new()
$connStrings    = @{}
$dbDir          = $null
$configDir      = $null
$sitesDeployed  = [System.Collections.Generic.List[string]]::new()
$svcDeployed    = [System.Collections.Generic.List[string]]::new()
$dbScriptsRun   = 0
$config         = $null

try {
    # ── Init ─────────────────────────────────────────────────────────────────
    $rootConfig    = Get-RootConfig
    $configDir     = Resolve-Dir $rootConfig.ProjectConfigurationsPath "ProjectConfigs"
    $backupRootDir = Resolve-Dir $rootConfig.BackupPath "Backup"

    Initialize-Log -ProjectName $ProjectName -LogRoot (Join-Path $ScriptRoot "Logs")

    if ($DryRun) { Write-Log "DRYRUN" "════ DRY RUN MODE — no changes will be made ════" }
    Write-Log "INFO" "Project  : $ProjectName"
    Write-Log "INFO" "Flags    : SkipDb=$SkipDb  AutoRollback=$AutoRollback  DbRollback=$DbRollback  DryRun=$DryRun"

    # Load + resolve config
    $config = Get-ProjectConfig -ConfigDir $configDir -Project $ProjectName
    $config = Resolve-ProjectSecrets -ProjectConfig $config

    $dropPath = $config.ProjectFileDropPath
    if (-not $dropPath) { throw "ProjectFileDropPath not set in project config" }
    $dbDir = Join-Path $dropPath "Database"

    if ($config.PSObject.Properties["ConnectionStrings"] -and $config.ConnectionStrings) {
        $config.ConnectionStrings.PSObject.Properties | ForEach-Object { $connStrings[$_.Name] = $_.Value }
    }

    # Collect site/service paths and health check URLs
    if ($config.PSObject.Properties["AppConfiguration"]) {
        foreach ($app in $config.AppConfiguration) {
            if ($app.SitePath)   { $sitePaths.Add($app.SitePath) }
            if ($app.AppPoolName){ $stoppedPools.Add($app.AppPoolName) }   # pre-register for rollback
            if ($app.HealthCheckUrl) {
                $healthUrls.Add($app.HealthCheckUrl)
                $healthMethods.Add($(if ($app.HealthCheckType) { $app.HealthCheckType } else { "GET" }))
            }
        }
    }
    if ($config.PSObject.Properties["ServiceConfiguration"]) {
        foreach ($svc in $config.ServiceConfiguration) {
            if ($svc.ServicePath)  { $servicePaths.Add($svc.ServicePath) }
            if ($svc.ServiceName)  { $stoppedServices.Add($svc.ServiceName) }
        }
    }
    $stoppedPools    = [System.Collections.Generic.List[string]]::new()   # reset — will re-add as we actually stop
    $stoppedServices = [System.Collections.Generic.List[string]]::new()

    # Determine whether DB steps should run
    $hasDbScripts = Test-DbScriptsExist -DatabaseDir $dbDir -Direction "Up"
    $runDb        = (-not $SkipDb) -and $hasDbScripts

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1: VALIDATE FILES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 1 "Validate files"
    try {
        if (-not (Test-Path $dropPath)) { throw "ProjectFileDropPath does not exist: $dropPath" }

        $appZip = Join-Path $dropPath "App\app.zip"
        $svcZip = Join-Path $dropPath "Services\service.zip"

        $hasApp = $config.PSObject.Properties["AppConfiguration"] -and $config.AppConfiguration
        $hasSvc = $config.PSObject.Properties["ServiceConfiguration"] -and $config.ServiceConfiguration

        if ($hasApp -and -not (Test-Path $appZip)) { throw "App artifact not found: $appZip" }
        if ($hasSvc -and -not (Test-Path $svcZip)) { throw "Service artifact not found: $svcZip" }

        if (-not $DryRun) {
            if ($hasApp) {
                $appInfo = Get-Item $appZip
                Write-Log "INFO" "  app.zip found ($([math]::Round($appInfo.Length / 1MB, 2)) MB)"
            }
            if ($hasSvc) {
                $svcInfo = Get-Item $svcZip
                Write-Log "INFO" "  service.zip found ($([math]::Round($svcInfo.Length / 1MB, 2)) MB)"
            }
        }

        if ($runDb) {
            $dbFolders = Get-ChildItem -Path $dbDir -Directory -ErrorAction SilentlyContinue
            foreach ($f in $dbFolders) {
                if (-not $connStrings.ContainsKey($f.Name)) {
                    throw "DB folder '$($f.Name)' has no matching ConnectionStrings key in project config"
                }
            }
            Write-Log "INFO" "  DB scripts found — migrations will run"
        } elseif ($SkipDb) {
            Write-Log "INFO" "  DB steps will be skipped (--skip-db)"
        } else {
            Write-Log "INFO" "  No DB scripts found — DB steps will be skipped"
        }

        $stepResults[1] = "OK"
        Write-StepOk "All required files validated"
    } catch {
        $stepResults[1] = "FAIL"
        Write-StepFail $_
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 2: STOP APPLICATION POOLS / SERVICES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 2 "Stop application pools and services"
    try {
        if ($config.PSObject.Properties["AppConfiguration"]) {
            foreach ($app in $config.AppConfiguration) {
                if ($app.AppPoolName) {
                    Stop-AppPool -Name $app.AppPoolName -DryRun:$DryRun
                    $stoppedPools.Add($app.AppPoolName)
                }
            }
        }
        if ($config.PSObject.Properties["ServiceConfiguration"]) {
            foreach ($svc in $config.ServiceConfiguration) {
                if ($svc.ServiceName) {
                    Stop-ServiceSafe -Name $svc.ServiceName -DryRun:$DryRun
                    $stoppedServices.Add($svc.ServiceName)
                }
            }
        }
        $stepResults[2] = "OK"
        Write-StepOk "Stopped $($stoppedPools.Count) pool(s), $($stoppedServices.Count) service(s)"
    } catch {
        $stepResults[2] = "FAIL"
        Write-StepFail $_
        # Attempt to restart anything that was stopped before failure
        foreach ($p in $stoppedPools)    { try { Start-AppPool    -Name $p -DryRun:$DryRun } catch {} }
        foreach ($s in $stoppedServices) { try { Start-ServiceSafe -Name $s -DryRun:$DryRun } catch {} }
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3: BACKUP SITES (with integrity verification)
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 3 "Backup sites"
    try {
        $allPaths  = @($sitePaths) + @($servicePaths) | Where-Object { $_ }
        $backupDir = Join-Path $backupRootDir $ProjectName

        $backupZip = New-Backup -Paths $allPaths -BackupDir $backupDir -ProjectName $ProjectName -DryRun:$DryRun

        if (-not $DryRun) {
            if (-not $backupZip) {
                throw "Backup was not created — source paths may not exist yet. Cannot proceed without a backup."
            }
            Write-Log "INFO" "Verifying backup integrity..."
            $verify = Test-BackupIntegrity -ZipPath $backupZip -SourcePaths $allPaths
            $backupFileCount = $verify.ZipEntryCount

            if (-not $verify.IsValid) {
                throw ("Backup integrity check FAILED — source has $($verify.SourceFileCount) file(s) " +
                       "but zip contains $($verify.ZipEntryCount) entr(ies). Aborting to protect production files.")
            }
            Write-Log "INFO" "Backup verified: $($verify.ZipEntryCount) files match source"
        } else {
            $backupFileCount = 0
        }

        $stepResults[3] = "OK"
        Write-StepOk "$(Split-Path $backupZip -Leaf) ($backupFileCount files)"
    } catch {
        $stepResults[3] = "FAIL"
        Write-StepFail $_
        foreach ($p in $stoppedPools)    { try { Start-AppPool    -Name $p -DryRun:$DryRun } catch {} }
        foreach ($s in $stoppedServices) { try { Start-ServiceSafe -Name $s -DryRun:$DryRun } catch {} }
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 4: UNZIP ARTIFACT FILES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 4 "Unzip artifact files"
    $extractedAppDirs = [ordered]@{}    # AppPoolName/SiteName → extracted source dir
    $extractedSvcDirs = [ordered]@{}
    try {
        if ($hasApp) {
            foreach ($app in $config.AppConfiguration) {
                $outDir = Join-Path $env:TEMP "autodeploy_app_$($app.SiteName)_$(Get-Date -Format 'yyyyMMddHHmmss')"
                $src    = Expand-ZipArtifact -ZipPath $appZip -ArtifactFolderName $app.ArtifactFolderName -OutDir $outDir -DryRun:$DryRun
                $extractedAppDirs[$app.SiteName] = $src
                Write-Log "INFO" "  $($app.SiteName) → $(Split-Path $src -Leaf)"
            }
        }
        if ($hasSvc) {
            foreach ($svc in $config.ServiceConfiguration) {
                $outDir = Join-Path $env:TEMP "autodeploy_svc_$($svc.ServiceName)_$(Get-Date -Format 'yyyyMMddHHmmss')"
                $src    = Expand-ZipArtifact -ZipPath $svcZip -ArtifactFolderName $svc.ArtifactFolderName -OutDir $outDir -DryRun:$DryRun
                $extractedSvcDirs[$svc.ServiceName] = $src
                Write-Log "INFO" "  $($svc.ServiceName) → $(Split-Path $src -Leaf)"
            }
        }
        $stepResults[4] = "OK"
        Write-StepOk "Artifacts extracted"
    } catch {
        $stepResults[4] = "FAIL"
        Write-StepFail $_
        foreach ($p in $stoppedPools)    { try { Start-AppPool    -Name $p -DryRun:$DryRun } catch {} }
        foreach ($s in $stoppedServices) { try { Start-ServiceSafe -Name $s -DryRun:$DryRun } catch {} }
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 5: DEPLOY SITES  ← rollback from here on failure
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 5 "Deploy sites"
    try {
        if ($hasApp) {
            foreach ($app in $config.AppConfiguration) {
                Write-Log "INFO" "  Deploying: $($app.SiteName) → $($app.SitePath)"
                $srcDir = $extractedAppDirs[$app.SiteName]

                if ($app.Purge -eq $true) {
                    Write-Log "INFO" "  Purging site directory..."
                    Purge-Directory -Path $app.SitePath -IgnoreFiles $app.IgnoreFiles -IgnoreDirs $app.IgnoreDirs -DryRun:$DryRun
                }

                Copy-FilesWithIgnore -Source $srcDir -Dest $app.SitePath `
                    -IgnoreFiles $app.IgnoreFiles -IgnoreDirs $app.IgnoreDirs -DryRun:$DryRun

                if ($app.DeltaConfig) {
                    $deltaFile      = Join-Path $configDir $app.DeltaConfig
                    $targetFileName = ($app.DeltaConfig -replace '^[^_]+__', '') -replace '\.delta\.', '.'
                    $targetFile     = Join-Path $app.SitePath $targetFileName
                    Write-Log "INFO" "  Applying delta: $($app.DeltaConfig)"
                    Apply-DeltaConfig -TargetFile $targetFile -DeltaFile $deltaFile -DryRun:$DryRun
                }

                $sitesDeployed.Add("$($app.SiteName) → $($app.SitePath)")
                if (-not $DryRun -and (Test-Path $srcDir)) { Remove-Item (Split-Path $srcDir -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        if ($hasSvc) {
            foreach ($svc in $config.ServiceConfiguration) {
                Write-Log "INFO" "  Deploying service: $($svc.ServiceName) → $($svc.ServicePath)"
                $srcDir = $extractedSvcDirs[$svc.ServiceName]

                if ($svc.Purge -eq $true) {
                    Write-Log "INFO" "  Purging service directory..."
                    Purge-Directory -Path $svc.ServicePath -IgnoreFiles $svc.IgnoreFiles -IgnoreDirs $svc.IgnoreDirs -DryRun:$DryRun
                }

                Copy-FilesWithIgnore -Source $srcDir -Dest $svc.ServicePath `
                    -IgnoreFiles $svc.IgnoreFiles -IgnoreDirs $svc.IgnoreDirs -DryRun:$DryRun

                if ($svc.DeltaConfig) {
                    $deltaFile      = Join-Path $configDir $svc.DeltaConfig
                    $targetFileName = ($svc.DeltaConfig -replace '^[^_]+__', '') -replace '\.delta\.', '.'
                    $targetFile     = Join-Path $svc.ServicePath $targetFileName
                    Write-Log "INFO" "  Applying delta: $($svc.DeltaConfig)"
                    Apply-DeltaConfig -TargetFile $targetFile -DeltaFile $deltaFile -DryRun:$DryRun
                }

                $installBat = Join-Path $dropPath "Services\install.bat"
                if (Test-Path $installBat) {
                    Write-Log "INFO" "  Running install.bat..."
                    if (-not $DryRun) {
                        & cmd.exe /c `"$installBat`" 2>&1 | ForEach-Object { Write-Log "INFO" "  install.bat: $_" }
                        if ($LASTEXITCODE -ne 0) { throw "install.bat failed with exit code $LASTEXITCODE" }
                    } else {
                        Write-Log "DRYRUN" "  Would run: $installBat"
                    }
                }

                $svcDeployed.Add("$($svc.ServiceName) → $($svc.ServicePath)")
                if (-not $DryRun -and (Test-Path $srcDir)) { Remove-Item (Split-Path $srcDir -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        $stepResults[5] = "OK"
        Write-StepOk "$($sitesDeployed.Count + $svcDeployed.Count) target(s) deployed"
    } catch {
        $stepResults[5] = "FAIL"
        $failureReason  = "Step 5 (Deploy): $_"
        Write-StepFail $_
        if ($AutoRollback) {
            Invoke-AutoRollback -BackupZip $backupZip -RestorePaths (@($sitePaths) + @($servicePaths) | Where-Object { $_ }) `
                -AppPools $stoppedPools -Services $stoppedServices `
                -ConnStrings $connStrings -DatabaseDir $dbDir `
                -HealthUrls $healthUrls -HealthMethods $healthMethods
        } else {
            Write-Log "WARN" "Run: .\rollback.ps1 $ProjectName  to restore the previous state"
        }
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 6: RESTART APPLICATION POOLS / SERVICES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 6 "Restart application pools and services"
    try {
        foreach ($pool in $stoppedPools)    { Start-AppPool    -Name $pool -DryRun:$DryRun }
        foreach ($svc  in $stoppedServices) { Start-ServiceSafe -Name $svc  -DryRun:$DryRun }
        $stepResults[6] = "OK"
        Write-StepOk "Restarted $($stoppedPools.Count) pool(s), $($stoppedServices.Count) service(s)"
    } catch {
        $stepResults[6] = "FAIL"
        $failureReason  = "Step 6 (Restart): $_"
        Write-StepFail $_
        if ($AutoRollback) {
            Invoke-AutoRollback -BackupZip $backupZip -RestorePaths (@($sitePaths) + @($servicePaths) | Where-Object { $_ }) `
                -AppPools $stoppedPools -Services $stoppedServices `
                -ConnStrings $connStrings -DatabaseDir $dbDir `
                -HealthUrls $healthUrls -HealthMethods $healthMethods
        } else {
            Write-Log "WARN" "Run: .\rollback.ps1 $ProjectName  to restore the previous state"
        }
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 7: CHECK DB CONNECTIONS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 7 "Check DB connections"
    if ($runDb) {
        try {
            Test-DbConnections -ConnectionStrings $connStrings -DatabaseDir $dbDir -DryRun:$DryRun | Out-Null
            $stepResults[7] = "OK"
            Write-StepOk "All DB connections verified"
        } catch {
            $stepResults[7] = "FAIL"
            $failureReason  = "Step 7 (DB connections): $_"
            Write-StepFail $_
            if ($AutoRollback) {
                Invoke-AutoRollback -BackupZip $backupZip -RestorePaths (@($sitePaths) + @($servicePaths) | Where-Object { $_ }) `
                    -AppPools $stoppedPools -Services $stoppedServices `
                    -ConnStrings $connStrings -DatabaseDir $dbDir `
                    -HealthUrls $healthUrls -HealthMethods $healthMethods
            } else {
                Write-Log "WARN" "Run: .\rollback.ps1 $ProjectName  to restore the previous state"
            }
            throw
        }
    } else {
        $stepResults[7] = "SKIP"
        Write-StepSkip $(if ($SkipDb) { "--skip-db flag set" } else { "no DB scripts found" })
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 8: APPLY DB MIGRATIONS (Up)
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 8 "Apply DB migrations (Up)"
    if ($runDb) {
        try {
            $dbScriptsRun = Invoke-DbMigrations -DatabaseDir $dbDir -ConnectionStrings $connStrings -Direction Up -DryRun:$DryRun
            $stepResults[8] = "OK"
            Write-StepOk "$dbScriptsRun script(s) executed"
        } catch {
            $stepResults[8] = "FAIL"
            $failureReason  = "Step 8 (DB migrations): $_"
            Write-StepFail $_
            if ($AutoRollback) {
                Invoke-AutoRollback -BackupZip $backupZip -RestorePaths (@($sitePaths) + @($servicePaths) | Where-Object { $_ }) `
                    -AppPools $stoppedPools -Services $stoppedServices `
                    -ConnStrings $connStrings -DatabaseDir $dbDir `
                    -HealthUrls $healthUrls -HealthMethods $healthMethods
            } else {
                Write-Log "WARN" "Run: .\rollback.ps1 $ProjectName --db-rollback  to restore the previous state"
            }
            throw
        }
    } else {
        $stepResults[8] = "SKIP"
        Write-StepSkip $(if ($SkipDb) { "--skip-db flag set" } else { "no DB scripts found" })
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 9: CLOSE DB CONNECTIONS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 9 "Close DB connections"
    if ($runDb) {
        Close-DbConnections -ConnectionStrings $connStrings -DryRun:$DryRun
        $stepResults[9] = "OK"
        Write-StepOk "Connections closed"
    } else {
        $stepResults[9] = "SKIP"
        Write-StepSkip "DB steps not run"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 10: HEALTH CHECK SITES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 10 "Health check sites"
    $healthResults = [System.Collections.Generic.List[string]]::new()
    if ($healthUrls.Count -gt 0) {
        try {
            for ($hi = 0; $hi -lt $healthUrls.Count; $hi++) {
                $url    = $healthUrls[$hi]
                $method = $healthMethods[$hi]
                Write-Log "INFO" "  $method $url (up to 5 retries, 60s apart)"
                Invoke-HealthCheck -Url $url -Method $method -Retries 5 -DryRun:$DryRun
                $healthResults.Add("OK  — $url")
            }
            $stepResults[10] = "OK"
            Write-StepOk "$($healthUrls.Count) health check(s) passed"
        } catch {
            $stepResults[10] = "FAIL"
            $failureReason   = "Step 10 (Health check): $_"
            Write-StepFail $_
            $healthResults.Add("FAIL — $_")
            if ($AutoRollback) {
                Invoke-AutoRollback -BackupZip $backupZip -RestorePaths (@($sitePaths) + @($servicePaths) | Where-Object { $_ }) `
                    -AppPools $stoppedPools -Services $stoppedServices `
                    -ConnStrings $connStrings -DatabaseDir $dbDir `
                    -HealthUrls $healthUrls -HealthMethods $healthMethods
            } else {
                Write-Log "WARN" "Run: .\rollback.ps1 $ProjectName  to restore the previous state"
            }
            throw
        }
    } else {
        $stepResults[10] = "SKIP"
        Write-StepSkip "No HealthCheckUrl configured"
        $healthResults.Add("No health check URLs configured")
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 11: DONE
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 11 "Done"
    $stepResults[11] = "OK"
    Write-StepOk "Deployment complete"

} catch {
    $exitCode = 1
    if (-not $failureReason) { $failureReason = $_.ToString() }
    Write-Log "ERROR" ""
    Write-Log "ERROR" "Deployment failed: $failureReason"
    # Mark any remaining ? steps as not reached
    for ($i = 1; $i -le 11; $i++) { if ($stepResults[$i] -eq "?") { $stepResults[$i] = "SKIP" } }
    $stepResults[11] = if ($exitCode -ne 0) { "FAIL" } else { "OK" }
}

Show-DeploySummary `
    -Project        $ProjectName `
    -Status         $(if ($exitCode -eq 0) { "SUCCESS" } else { "FAILED" }) `
    -StartTime      $startTime `
    -StepResults    $stepResults `
    -BackupZip      $backupZip `
    -BackupFileCount $backupFileCount `
    -SitesDeployed  $sitesDeployed `
    -ServicesDeployed $svcDeployed `
    -DbScriptsRun   $dbScriptsRun `
    -HealthResults  $healthResults `
    -FailureReason  $failureReason

exit $exitCode
