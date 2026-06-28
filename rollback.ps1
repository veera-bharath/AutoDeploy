[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ProjectName,
    [string]$Backup,
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
  rollback.ps1 <project-name> [flags]

FLAGS
  --backup <name>  Restore a specific backup zip (default: most recent)
  --db-rollback    Run DB Down scripts after restoring files
  --dryrun         Simulate all steps without making changes
  --help           Show this help

STEPS
  1  Check app pool / service status and stop if running
  2  Get the backup
  3  Replace everything from backup
  4  Check DB connections
  5  Apply DB Down scripts
  6  Close DB connections
  7  Restart application pools / services
  8  Health checks
  9  Summary

EXAMPLES
  .\rollback.ps1 myapp
  .\rollback.ps1 myapp --backup myapp_bkp_20260628_143022.zip --db-rollback
  .\rollback.ps1 myapp --dryrun
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
# MANUAL INSTRUCTIONS (shown if rollback encounters errors)
# ─────────────────────────────────────────────────────────────────────────────

function Show-ManualRollbackInstructions {
    param(
        [string]$BackupZip,
        [string[]]$RestorePaths,
        [string[]]$AppPools,
        [string[]]$Services,
        [hashtable]$ConnStrings,
        [string]$DatabaseDir,
        [string[]]$HealthUrls,
        [System.Collections.Generic.List[string]]$Errors
    )
    $line = "═" * 62
    Write-Host ""
    Write-Host $line -ForegroundColor Red
    Write-Host "  ROLLBACK FAILED — MANUAL STEPS REQUIRED" -ForegroundColor Red
    Write-Host $line -ForegroundColor Red

    if ($Errors -and $Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  ERRORS ENCOUNTERED:" -ForegroundColor Yellow
        foreach ($e in $Errors) { Write-Host "    - $e" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "  Please perform the following steps manually as Administrator:"
    Write-Host $line -ForegroundColor Red
    Write-Host ""

    # Step 1 — Stop pools
    Write-Host "  STEP 1 — STOP APPLICATION POOLS / SERVICES" -ForegroundColor Cyan
    foreach ($pool in $AppPools) {
        Write-Host ""
        Write-Host "    # Option A (WebAdministration module):"
        Write-Host "    Import-Module WebAdministration"
        Write-Host "    Stop-WebAppPool -Name `"$pool`""
        Write-Host ""
        Write-Host "    # Option B (appcmd):"
        Write-Host "    appcmd stop apppool /apppool.name:`"$pool`""
    }
    foreach ($svc in $Services) {
        Write-Host ""
        Write-Host "    Stop-Service -Name `"$svc`" -Force"
    }

    # Step 2 — Restore
    Write-Host ""
    Write-Host "  STEP 2 — RESTORE FILES FROM BACKUP" -ForegroundColor Cyan
    Write-Host "    Backup file: $BackupZip"
    Write-Host ""
    Write-Host "    `$restoreTemp = Join-Path `$env:TEMP 'manual_restore'"
    Write-Host "    Expand-Archive -Path `"$BackupZip`" -DestinationPath `$restoreTemp -Force"
    foreach ($target in $RestorePaths) {
        $leaf = Split-Path $target -Leaf
        Write-Host ""
        Write-Host "    # Restore: $leaf"
        Write-Host "    if (Test-Path `"$target`") { Remove-Item `"$target`" -Recurse -Force }"
        Write-Host "    Copy-Item `"`$restoreTemp\$leaf`" -Destination `"$target`" -Recurse -Force"
    }

    # Step 3 — DB Down (if applicable)
    if ($ConnStrings -and $DatabaseDir -and (Test-Path $DatabaseDir)) {
        $hasDownScripts = Test-DbScriptsExist -DatabaseDir $DatabaseDir -Direction "Down"
        if ($hasDownScripts) {
            Write-Host ""
            Write-Host "  STEP 3 — RUN DB DOWN SCRIPTS (run in the order listed)" -ForegroundColor Cyan
            $folders = Get-ChildItem -Path $DatabaseDir -Directory -ErrorAction SilentlyContinue
            foreach ($folder in $folders) {
                $csKey   = $folder.Name
                $downDir = Join-Path $folder.FullName "Down"
                if (-not (Test-Path $downDir)) { continue }
                $scripts = Get-ChildItem -Path $downDir -Filter "*.sql" -ErrorAction SilentlyContinue |
                           Sort-Object { [int]($_.Name -replace '^(\d+).*','$1') }
                if (-not $scripts) { continue }
                $provider = if ($ConnStrings.ContainsKey($csKey)) {
                    try { Get-DbProvider $ConnStrings[$csKey] } catch { "unknown" }
                } else { "unknown" }
                Write-Host ""
                Write-Host "    Connection : $csKey ($provider)"
                foreach ($s in $scripts) {
                    if ($provider -eq "mssql") {
                        Write-Host "    sqlcmd -E -S <server> -d <database> -i `"$($s.FullName)`" -b"
                    } else {
                        Write-Host "    db2 -tf `"$($s.FullName)`""
                    }
                }
            }
        }
    }

    # Step 4 — Restart
    $startStep = if ($ConnStrings -and $DatabaseDir -and (Test-Path -Path $DatabaseDir -ErrorAction SilentlyContinue)) { 4 } else { 3 }
    Write-Host ""
    Write-Host "  STEP $startStep — RESTART APPLICATION POOLS / SERVICES" -ForegroundColor Cyan
    foreach ($pool in $AppPools) {
        Write-Host ""
        Write-Host "    # Option A:"
        Write-Host "    Start-WebAppPool -Name `"$pool`""
        Write-Host ""
        Write-Host "    # Option B:"
        Write-Host "    appcmd start apppool /apppool.name:`"$pool`""
    }
    foreach ($svc in $Services) {
        Write-Host ""
        Write-Host "    Start-Service -Name `"$svc`""
    }

    # Step 5 — Health verify
    $hcStep = $startStep + 1
    Write-Host ""
    Write-Host "  STEP $hcStep — VERIFY HEALTH" -ForegroundColor Cyan
    foreach ($url in $HealthUrls) {
        Write-Host "    Invoke-WebRequest -Uri `"$url`" -Method GET -UseBasicParsing"
    }

    Write-Host ""
    Write-Host $line -ForegroundColor Red
    Write-Host "  After completing manual steps, verify the application is working." -ForegroundColor Yellow
    Write-Host $line -ForegroundColor Red
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Show-RollbackSummary {
    param(
        [string]$Project,
        [string]$Status,
        [datetime]$StartTime,
        [hashtable]$StepResults,
        [string]$BackupZip,
        [string[]]$HealthResults,
        [System.Collections.Generic.List[string]]$AllErrors
    )
    $duration = (Get-Date) - $StartTime
    $durStr   = "{0:D2}:{1:D2}:{2:D2}" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
    $color    = if ($Status -eq "SUCCESS") { "Green" } else { "Red" }
    $line     = "═" * 60

    Write-Host ""
    Write-Host $line -ForegroundColor $color
    Write-Host ("  ROLLBACK SUMMARY — {0,-40}" -f $Project) -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
    Write-Host ("  Status   : {0}" -f $Status) -ForegroundColor $color
    Write-Host ("  Duration : {0}" -f $durStr)
    if ($DryRun) { Write-Host "  Mode     : DRY RUN — no changes made" -ForegroundColor Magenta }

    Write-Host ""
    Write-Host "  STEPS" -ForegroundColor Cyan
    $stepNames = @(
        "Check and stop app pools / services",
        "Get backup",
        "Restore files from backup",
        "Check DB connections",
        "Apply DB Down scripts",
        "Close DB connections",
        "Restart application pools / services",
        "Health checks",
        "Done"
    )
    for ($i = 1; $i -le 9; $i++) {
        $r   = $StepResults[$i]
        $sym = switch ($r) { "OK" {"✓"} "SKIP" {"–"} "FAIL" {"✗"} default {"?"} }
        $c   = switch ($r) { "OK" {"Green"} "SKIP" {"DarkGray"} "FAIL" {"Red"} default {"Yellow"} }
        Write-Host ("  [{0}] Step {1}  {2}" -f $sym, $i, $stepNames[$i - 1]) -ForegroundColor $c
    }

    if ($BackupZip) {
        Write-Host ""
        Write-Host "  BACKUP RESTORED" -ForegroundColor Cyan
        Write-Host "    $(Split-Path $BackupZip -Leaf)"
    }
    if ($HealthResults -and $HealthResults.Count -gt 0) {
        Write-Host ""
        Write-Host "  HEALTH CHECKS" -ForegroundColor Cyan
        foreach ($h in $HealthResults) { Write-Host "    $h" }
    }
    if ($AllErrors -and $AllErrors.Count -gt 0) {
        Write-Host ""
        Write-Host "  ERRORS" -ForegroundColor Red
        foreach ($e in $AllErrors) { Write-Host "    - $e" -ForegroundColor Red }
    }

    Write-Host $line -ForegroundColor $color
    Write-Host ""
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

$startTime   = Get-Date
$stepResults = @{ 1="?"; 2="?"; 3="?"; 4="?"; 5="?"; 6="?"; 7="?"; 8="?"; 9="?" }
$exitCode    = 0
$allErrors   = [System.Collections.Generic.List[string]]::new()

$backupZip       = $null
$connStrings     = @{}
$dbDir           = $null
$restorePaths    = [System.Collections.Generic.List[string]]::new()
$appPools        = [System.Collections.Generic.List[string]]::new()
$services        = [System.Collections.Generic.List[string]]::new()
$healthUrls      = [System.Collections.Generic.List[string]]::new()
$healthMethods   = [System.Collections.Generic.List[string]]::new()
$healthResults   = [System.Collections.Generic.List[string]]::new()
$config          = $null

try {
    # ── Init ─────────────────────────────────────────────────────────────────
    $rootConfig    = Get-RootConfig
    $configDir     = Resolve-Dir $rootConfig.ProjectConfigurationsPath "ProjectConfigs"
    $backupRootDir = Resolve-Dir $rootConfig.BackupPath "Backup"

    Initialize-Log -ProjectName $ProjectName -LogRoot (Join-Path $ScriptRoot "Logs")
    if ($DryRun) { Write-Log "DRYRUN" "════ DRY RUN MODE — no changes will be made ════" }
    Write-Log "INFO" "=== ROLLBACK STARTED — Project: $ProjectName ==="
    if ($DbRollback) { Write-Log "INFO" "DB Down scripts will be applied (--db-rollback)" }

    # Load + resolve config
    $config = Get-ProjectConfig -ConfigDir $configDir -Project $ProjectName
    $config = Resolve-ProjectSecrets -ProjectConfig $config

    if ($config.PSObject.Properties["ConnectionStrings"] -and $config.ConnectionStrings) {
        $config.ConnectionStrings.PSObject.Properties | ForEach-Object { $connStrings[$_.Name] = $_.Value }
    }

    $dropPath = $config.ProjectFileDropPath
    $dbDir    = Join-Path $dropPath "Database"

    if ($config.PSObject.Properties["AppConfiguration"]) {
        foreach ($app in $config.AppConfiguration) {
            if ($app.SitePath)     { $restorePaths.Add($app.SitePath) }
            if ($app.AppPoolName)  { $appPools.Add($app.AppPoolName) }
            if ($app.HealthCheckUrl) {
                $healthUrls.Add($app.HealthCheckUrl)
                $healthMethods.Add($(if ($app.HealthCheckType) { $app.HealthCheckType } else { "GET" }))
            }
        }
    }
    if ($config.PSObject.Properties["ServiceConfiguration"]) {
        foreach ($svc in $config.ServiceConfiguration) {
            if ($svc.ServicePath) { $restorePaths.Add($svc.ServicePath) }
            if ($svc.ServiceName) { $services.Add($svc.ServiceName) }
        }
    }

    $hasDownScripts = $DbRollback -and (Test-DbScriptsExist -DatabaseDir $dbDir -Direction "Down")

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1: CHECK STATUS AND STOP APP POOLS / SERVICES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 1 "Check app pool / service status and stop if running"
    $stoppedPools    = [System.Collections.Generic.List[string]]::new()
    $stoppedServices = [System.Collections.Generic.List[string]]::new()
    $step1Errors     = [System.Collections.Generic.List[string]]::new()

    foreach ($pool in $appPools) {
        try {
            $status = Get-AppPoolStatus -Name $pool
            Write-Log "INFO" "  App Pool '$pool' status: $status"
            if ($status -ne "Stopped") {
                Stop-AppPool -Name $pool -DryRun:$DryRun
                $stoppedPools.Add($pool)
            } else {
                Write-Log "INFO" "  App Pool '$pool' already stopped"
                $stoppedPools.Add($pool)    # still track it for restart
            }
        } catch {
            $msg = "Could not stop App Pool '$pool': $_"
            $step1Errors.Add($msg)
            $allErrors.Add($msg)
            Write-Log "WARN" "  $msg"
        }
    }
    foreach ($svc in $services) {
        try {
            $svcObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($svcObj) {
                Write-Log "INFO" "  Service '$svc' status: $($svcObj.Status)"
                if ($svcObj.Status -ne 'Stopped') {
                    Stop-ServiceSafe -Name $svc -DryRun:$DryRun
                    $stoppedServices.Add($svc)
                } else {
                    Write-Log "INFO" "  Service '$svc' already stopped"
                    $stoppedServices.Add($svc)
                }
            } else {
                Write-Log "WARN" "  Service '$svc' not found on this machine"
            }
        } catch {
            $msg = "Could not stop Service '$svc': $_"
            $step1Errors.Add($msg)
            $allErrors.Add($msg)
            Write-Log "WARN" "  $msg"
        }
    }

    if ($step1Errors.Count -eq 0) {
        $stepResults[1] = "OK"
        Write-StepOk "Stopped $($stoppedPools.Count) pool(s), $($stoppedServices.Count) service(s)"
    } else {
        $stepResults[1] = "FAIL"
        Write-StepFail "$($step1Errors.Count) error(s) — continuing rollback anyway"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 2: GET THE BACKUP
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 2 "Get backup"
    try {
        $backupDir = Join-Path $backupRootDir $ProjectName

        if ($Backup) {
            $backupZip = if ([System.IO.Path]::IsPathRooted($Backup)) { $Backup } else { Join-Path $backupDir $Backup }
            if (-not (Test-Path $backupZip)) { throw "Specified backup not found: $backupZip" }
        } else {
            $latest = Get-ChildItem -Path $backupDir -Filter "*.zip" -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1
            if (-not $latest) { throw "No backup zips found in: $backupDir" }
            $backupZip = $latest.FullName
        }

        $zipInfo = if (-not $DryRun) { Get-Item $backupZip } else { $null }
        Write-Log "INFO" "  Using backup: $(Split-Path $backupZip -Leaf)"
        if ($zipInfo) { Write-Log "INFO" "  Size: $([math]::Round($zipInfo.Length / 1MB, 2)) MB  Modified: $($zipInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" }

        $stepResults[2] = "OK"
        Write-StepOk "$(Split-Path $backupZip -Leaf)"
    } catch {
        $stepResults[2] = "FAIL"
        $allErrors.Add("Get backup: $_")
        Write-StepFail $_
        # Cannot continue without a backup — fall to finally for summary
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3: RESTORE FILES FROM BACKUP
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 3 "Restore files from backup"
    try {
        Restore-Backup -ZipPath $backupZip -RestorePaths $restorePaths -DryRun:$DryRun
        $stepResults[3] = "OK"
        Write-StepOk "$($restorePaths.Count) path(s) restored"
    } catch {
        $stepResults[3] = "FAIL"
        $allErrors.Add("Restore backup: $_")
        Write-StepFail $_
        throw
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 4: CHECK DB CONNECTIONS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 4 "Check DB connections"
    if ($hasDownScripts) {
        try {
            Test-DbConnections -ConnectionStrings $connStrings -DatabaseDir $dbDir -DryRun:$DryRun | Out-Null
            $stepResults[4] = "OK"
            Write-StepOk "All DB connections verified"
        } catch {
            $stepResults[4] = "FAIL"
            $allErrors.Add("DB connection check: $_")
            Write-StepFail "$_ — DB Down scripts will be skipped"
            # Don't throw — continue rollback without DB scripts
        }
    } else {
        $stepResults[4] = "SKIP"
        Write-StepSkip $(if (-not $DbRollback) { "--db-rollback not set" } else { "no Down scripts found" })
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 5: APPLY DB DOWN SCRIPTS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 5 "Apply DB Down scripts"
    if ($hasDownScripts -and $stepResults[4] -eq "OK") {
        try {
            $downCount = Invoke-DbMigrations -DatabaseDir $dbDir -ConnectionStrings $connStrings -Direction Down -DryRun:$DryRun
            $stepResults[5] = "OK"
            Write-StepOk "$downCount script(s) executed"
        } catch {
            $stepResults[5] = "FAIL"
            $allErrors.Add("DB Down migrations: $_")
            Write-StepFail "$_ — continuing rollback"
            # Don't throw — files are already restored, proceed to restart
        }
    } else {
        $stepResults[5] = "SKIP"
        Write-StepSkip $(if (-not $DbRollback) { "--db-rollback not set" } elseif ($stepResults[4] -eq "FAIL") { "DB connection failed" } else { "no Down scripts found" })
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 6: CLOSE DB CONNECTIONS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 6 "Close DB connections"
    if ($hasDownScripts) {
        Close-DbConnections -ConnectionStrings $connStrings -DryRun:$DryRun
        $stepResults[6] = "OK"
        Write-StepOk "Connections closed"
    } else {
        $stepResults[6] = "SKIP"
        Write-StepSkip "DB steps not run"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 7: RESTART APPLICATION POOLS / SERVICES
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 7 "Restart application pools and services"
    $step7Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($pool in $stoppedPools) {
        try { Start-AppPool -Name $pool -DryRun:$DryRun }
        catch {
            $msg = "Start App Pool '$pool': $_"
            $step7Errors.Add($msg)
            $allErrors.Add($msg)
            Write-Log "ERROR" "  $msg"
        }
    }
    foreach ($svc in $stoppedServices) {
        try { Start-ServiceSafe -Name $svc -DryRun:$DryRun }
        catch {
            $msg = "Start Service '$svc': $_"
            $step7Errors.Add($msg)
            $allErrors.Add($msg)
            Write-Log "ERROR" "  $msg"
        }
    }

    if ($step7Errors.Count -eq 0) {
        $stepResults[7] = "OK"
        Write-StepOk "Restarted $($stoppedPools.Count) pool(s), $($stoppedServices.Count) service(s)"
    } else {
        $stepResults[7] = "FAIL"
        Write-StepFail "$($step7Errors.Count) error(s) restarting — see summary for details"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 8: HEALTH CHECKS
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 8 "Health checks"
    if ($healthUrls.Count -gt 0) {
        $step8Errors = [System.Collections.Generic.List[string]]::new()
        for ($hi = 0; $hi -lt $healthUrls.Count; $hi++) {
            $url    = $healthUrls[$hi]
            $method = $healthMethods[$hi]
            Write-Log "INFO" "  $method $url (up to 5 retries, 60s apart)"
            try {
                Invoke-HealthCheck -Url $url -Method $method -Retries 5 -DryRun:$DryRun
                $healthResults.Add("OK   — $url")
            } catch {
                $msg = "Health check '$url': $_"
                $step8Errors.Add($msg)
                $allErrors.Add($msg)
                $healthResults.Add("FAIL — $url")
                Write-Log "ERROR" "  $msg"
            }
        }
        if ($step8Errors.Count -eq 0) {
            $stepResults[8] = "OK"
            Write-StepOk "$($healthUrls.Count) health check(s) passed"
        } else {
            $stepResults[8] = "FAIL"
            Write-StepFail "$($step8Errors.Count) health check(s) failed"
        }
    } else {
        $stepResults[8] = "SKIP"
        Write-StepSkip "No HealthCheckUrl configured"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 9: DONE
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step 9 "Done"
    $overallOk = ($allErrors.Count -eq 0)
    if ($overallOk) {
        $stepResults[9] = "OK"
        Write-StepOk "Rollback completed successfully"
    } else {
        $exitCode = 1
        $stepResults[9] = "FAIL"
        Write-StepFail "Rollback completed with $($allErrors.Count) error(s) — see summary and manual instructions"
    }

} catch {
    $exitCode = 1
    $errMsg   = $_.ToString()
    if (-not $allErrors.Contains($errMsg)) { $allErrors.Add($errMsg) }
    Write-Log "ERROR" "Rollback aborted: $errMsg"
    for ($i = 1; $i -le 9; $i++) { if ($stepResults[$i] -eq "?") { $stepResults[$i] = "SKIP" } }
    $stepResults[9] = "FAIL"
}

Show-RollbackSummary `
    -Project       $ProjectName `
    -Status        $(if ($exitCode -eq 0) { "SUCCESS" } else { "FAILED" }) `
    -StartTime     $startTime `
    -StepResults   $stepResults `
    -BackupZip     $backupZip `
    -HealthResults $healthResults `
    -AllErrors     $allErrors

if ($exitCode -ne 0) {
    Show-ManualRollbackInstructions `
        -BackupZip    $backupZip `
        -RestorePaths $restorePaths `
        -AppPools     $appPools `
        -Services     $services `
        -ConnStrings  $connStrings `
        -DatabaseDir  $dbDir `
        -HealthUrls   $healthUrls `
        -Errors       $allErrors
}

exit $exitCode
