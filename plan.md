# AutoDeploy PowerShell System — Implementation Plan

## Context

Build a fully automated, flag-driven PowerShell deployment system for Windows environments (IIS apps + Windows services + SQL migrations). The system resolves secrets from Azure Key Vault or environment variables, supports delta config patching, takes file backups before deploying, and provides dry-run and rollback capabilities.

---

## Architecture Overview

```
deploy.ps1 <project> [flags]    ← orchestrator
rollback.ps1 <project> [flags]  ← restore from backup + DB Down

Deploy/
  helpers.ps1    ← file ops, IIS, service control, health check, zip, delta patch
  logger.ps1     ← Write-Log (console + file); starts log session per run

SecretProviders/
  secrets.ps1          ← Resolve-Secret: checks project-config literal → AzureKV → env
  azure-keyvault.ps1   ← Get-AzureSecret (REST + client-credentials token)
  environment.ps1      ← Get-EnvSecret

DbPersistence/
  db.ps1               ← Invoke-SqlFile: detects provider from conn string → delegates
  mssql-provider.ps1   ← Invoke-MssqlScript (uses sqlcmd or System.Data.SqlClient)
  db2-provider.ps1     ← Invoke-Db2Script (uses db2cmd or ODBC)
```

---

## Directory Structure

```
Root
│
├── deploy.ps1
├── rollback.ps1
├── config.json
├── plan.md
│
├── Deploy/
│   ├── helpers.ps1
│   └── logger.ps1
│
├── SecretProviders/
│   ├── secrets.ps1
│   ├── azure-keyvault.ps1
│   └── environment.ps1
│
├── DbPersistence/
│   ├── db.ps1
│   ├── mssql-provider.ps1
│   └── db2-provider.ps1
│
├── ProjectConfigs/              ← path overridable via config.json
│   ├── <project>-config.json
│   └── <site>__<file>.delta.json  ← delta patch files live here
│
├── DeployFiles/                 ← path per project via ProjectFileDropPath
│   ├── App/
│   │   └── app.zip
│   ├── Services/
│   │   ├── service.zip
│   │   ├── install.bat          (optional)
│   │   └── uninstall.bat        (optional)
│   ├── Database/
│   │   └── <ConnectionStringKey>/
│   │       ├── Up/
│   │       │   ├── 1_CreateTable.sql
│   │       │   └── 2_AddColumn.sql
│   │       └── Down/
│   │           ├── 1_AddColumn.sql
│   │           └── 2_CreateTable.sql
│   └── Files/
│       └── (any extra files)
│
├── Logs/
│   └── <project>/
│       └── <yyyy-MM-dd>/
│           └── log.txt
│
└── Backup/                      ← path overridable via config.json
    └── <project>/
        └── <project>_bkp_<timestamp>.zip
```

---

## CLI Interface

```powershell
# Deploy
.\deploy.ps1 <project-name> [--skip-db] [--auto-rollback] [--db-rollback] [--dryrun] [--help]

# Rollback
.\rollback.ps1 <project-name> [--backup <filename>] [--db-rollback] [--dryrun] [--help]
```

| Flag | Scope | Meaning |
|------|-------|---------|
| `--skip-db` | deploy | Skip all DB migrations |
| `--auto-rollback` | deploy | Auto-invoke rollback on any failure |
| `--db-rollback` | deploy, rollback | Include DB Down scripts during rollback |
| `--dryrun` | deploy, rollback | Simulate all steps; no writes or restarts |
| `--backup <name>` | rollback | Restore a specific backup zip; default = most recent |
| `--help` | both | Print usage |

---

## config.json

```json
{
  "BackupPath": "<path>",
  "ProjectConfigurationsPath": "<path>"
}
```

Both fields are optional. Defaults to `Backup/` and `ProjectConfigs/` relative to the script root.

---

## `<project>-config.json`

```json
{
  "ProjectName": "xyz",
  "ProjectFileDropPath": "<path>",
  "ConnectionStrings": {
    "MssqlConnection": "@secret:MssqlConnection or <literal-connection-string>",
    "Db2Connection": "@secret:Db2Connection or <literal-connection-string>"
  },
  "AzureKeyVault": {
    "Url": "<vault-url>",
    "ClientId": "<app-id>",
    "ClientSecret": "<secret>",
    "TenantId": "<tenant-id>"
  },
  "AppConfiguration": [
    {
      "SiteName": "<iis-site-name>",
      "SitePath": "<path-of-site-files>",
      "AppPoolName": "<app-pool-name>",
      "ArtifactFolderName": "<subfolder-inside-app-zip>",
      "HealthCheckUrl": "<url>",
      "HealthCheckType": "GET",
      "IgnoreFiles": ["appsettings*.json", "web.config"],
      "IgnoreDirs": ["logs", "assets"],
      "Purge": false,
      "DeltaConfig": "<site>__appsettings.delta.json"
    }
  ],
  "ServiceConfiguration": [
    {
      "ServiceName": "<windows-service-name>",
      "ServicePath": "<path-of-service-files>",
      "ArtifactFolderName": "<subfolder-inside-service-zip>",
      "IgnoreFiles": ["appsettings*.json"],
      "IgnoreDirs": ["logs"],
      "Purge": false,
      "DeltaConfig": "<service>__appsettings.delta.json"
    }
  ]
}
```

---

## Deploy Flow (`deploy.ps1`)

```
1. Parse args        → project name + flags; --help exits early
2. Load configs      → config.json (BackupPath, ProjectConfigurationsPath)
                       → <project>-config.json
3. Resolve secrets   → walk all @secret:<key> values via Resolve-Secret
4. Validate          → DeployFiles paths exist; required fields present
5. Backup            → zip SitePath + ServicePath dirs
                       → Backup/<project>/<project>_bkp_<yyyyMMdd_HHmmss>.zip
6. DB Up             → (unless --skip-db)
                       for each folder in DeployFiles/Database/:
                         detect provider from matching ConnectionStrings value
                         run Up/*.sql in numeric sort order
7. Stop              → Stop-AppPool for each AppConfiguration.AppPoolName
                       Stop-ServiceSafe for each ServiceConfiguration.ServiceName
8. Deploy App        → for each AppConfiguration:
                         Expand-ZipArtifact DeployFiles/App/app.zip → ArtifactFolderName
                         Purge SitePath if Purge=true (respecting IgnoreFiles/IgnoreDirs)
                         Copy-FilesWithIgnore → SitePath
                         Apply-DeltaConfig if DeltaConfig set
9. Deploy Services   → for each ServiceConfiguration:
                         Expand-ZipArtifact DeployFiles/Services/service.zip → ArtifactFolderName
                         Purge ServicePath if Purge=true
                         Copy-FilesWithIgnore → ServicePath
                         Apply-DeltaConfig if DeltaConfig set
                         Run install.bat if present (new service)
10. Copy Files       → copy DeployFiles/Files/* to targets (if folder exists)
11. Start            → Start-AppPool, Start-ServiceSafe
12. Health Check     → Invoke-HealthCheck (GET/POST, retries with backoff)
13. On failure       → if --auto-rollback: invoke rollback inline
                       always log with ERROR level
```

A `deploy-state.json` is written to a temp path after each completed major step so rollback can determine what was done.

---

## Rollback Flow (`rollback.ps1`)

```
1. Parse args
2. Load configs + resolve secrets
3. Find backup zip   → --backup <name> or most recent in Backup/<project>/
4. Stop              → Stop-AppPool, Stop-ServiceSafe
5. Restore files     → Expand backup zip back to original SitePath/ServicePath
6. DB Down           → (if --db-rollback)
                       for each DB folder: run Down/*.sql in numeric sort order
7. Start             → Start-AppPool, Start-ServiceSafe
8. Health check
9. Log result
```

---

## Secret Resolution (`secrets.ps1` → `Resolve-Secret`)

```
For each connection string / config value:
  if value does NOT start with "@secret:" → return as-is (literal)
  if value starts with "@secret:<key>":
    1. If AzureKeyVault block present in project config:
         call Get-AzureSecret "<key>"
         if found → return value
         if not found (404) or error → fall through
    2. call Get-EnvSecret "<key>"   ([Environment]::GetEnvironmentVariable)
         if found → return value
    3. throw "Secret '<key>' could not be resolved from Azure Key Vault or environment"
```

`azure-keyvault.ps1` uses OAuth2 client-credentials flow (REST, no Az module required) to get a Bearer token, then calls the Key Vault secrets REST API.

---

## DeltaConfig Patching (`helpers.ps1` → `Apply-DeltaConfig`)

Delta files live in `ProjectConfigurationsPath` alongside the project config.

**Naming convention:** `<site-or-service-name>__<target-config-filename>.delta.json`
Examples: `hrms__appsettings.delta.json`, `hrmsapi__web.delta.config`

**JSON targets (`.json`):**
Deep merge — recursively walk delta PSCustomObject keys. Existing keys are overwritten; missing keys are added. Hierarchy is fully preserved.

**XML targets (`.config`):**
Delta file is also XML. For each element in the delta, locate the matching element in the target by tag name + `key` or `name` attribute, then update its `value` attribute. Append any elements not found in the target.

---

## DB Provider Detection (`db.ps1` → `Invoke-SqlFile`)

Folder name under `DeployFiles/Database/` must match a key in `ConnectionStrings`. The resolved connection string value determines the provider:

| Pattern in connection string | Provider script |
|------------------------------|-----------------|
| `Server=` or `Data Source=` (no `DRIVER=`) | `mssql-provider.ps1` |
| `DRIVER=` or `DSN=` | `db2-provider.ps1` |

SQL files are sorted by filename (numeric prefix `1_`, `2_`, `3_`) and executed in order. Failure on any file stops the sequence.

`mssql-provider.ps1` — uses `sqlcmd.exe` if available, otherwise `System.Data.SqlClient` (.NET).
`db2-provider.ps1` — uses `db2.exe` (DB2 CLI) if available, otherwise ODBC via `System.Data.Odbc`.

---

## Logging (`logger.ps1`)

```
Log path:  Logs/<project>/<yyyy-MM-dd>/log.txt
Format:    [HH:mm:ss] [LEVEL] <message>
Levels:    INFO | WARN | ERROR | DRYRUN
```

`Write-Log` writes to both the log file (append) and console (color-coded). The log file and its parent directories are created on first write if they don't exist.

---

## `helpers.ps1` Key Functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `Copy-FilesWithIgnore` | `(Source, Dest, IgnoreFiles, IgnoreDirs, DryRun)` | Copy-Item with glob-based exclusions |
| `Expand-ZipArtifact` | `(ZipPath, ArtifactFolderName, OutDir, DryRun)` | Expand-Archive; enter named subfolder |
| `New-Backup` | `(Paths[], BackupDir, ProjectName, DryRun)` | Compress-Archive to timestamped zip |
| `Restore-Backup` | `(ZipPath, DryRun)` | Expand-Archive to original paths |
| `Invoke-HealthCheck` | `(Url, Method, Retries, DryRun)` | HTTP check; exponential backoff |
| `Stop-AppPool` | `(Name, DryRun)` | WebAdministration or appcmd.exe |
| `Start-AppPool` | `(Name, DryRun)` | WebAdministration or appcmd.exe |
| `Stop-ServiceSafe` | `(Name, TimeoutSec, DryRun)` | Stop-Service with timeout wait |
| `Start-ServiceSafe` | `(Name, DryRun)` | Start-Service |
| `Apply-DeltaConfig` | `(TargetFile, DeltaFile, DryRun)` | Route to JSON or XML merger |
| `Merge-JsonDelta` | `(TargetPath, DeltaPath, DryRun)` | Recursive PSObject deep merge |
| `Merge-XmlDelta` | `(TargetPath, DeltaPath, DryRun)` | XML element/attribute merge |
| `Purge-Directory` | `(Path, IgnoreFiles, IgnoreDirs, DryRun)` | Delete dir contents with exclusions |

All functions accept a `DryRun` switch — when set they log the action with `[DRYRUN]` and skip the actual operation.

---

## Implementation Order

| # | File | Key exports |
|---|------|-------------|
| 1 | `Deploy/logger.ps1` | `Initialize-Log`, `Write-Log` |
| 2 | `Deploy/helpers.ps1` | all helper functions above |
| 3 | `SecretProviders/environment.ps1` | `Get-EnvSecret` |
| 4 | `SecretProviders/azure-keyvault.ps1` | `Get-AzureSecret` |
| 5 | `SecretProviders/secrets.ps1` | `Resolve-Secret`, `Resolve-ProjectSecrets` |
| 6 | `DbPersistence/mssql-provider.ps1` | `Invoke-MssqlScript` |
| 7 | `DbPersistence/db2-provider.ps1` | `Invoke-Db2Script` |
| 8 | `DbPersistence/db.ps1` | `Invoke-DbMigrations` |
| 9 | `deploy.ps1` | orchestrator |
| 10 | `rollback.ps1` | restore orchestrator |
| 11 | `config.json` | sample root config |
| 12 | `ProjectConfigs/sample-config.json` | sample project config |

---

## Verification

```powershell
# Dry run — no changes made
.\deploy.ps1 myapp --dryrun

# Deploy with auto-rollback on failure (including DB rollback)
.\deploy.ps1 myapp --auto-rollback --db-rollback

# App-only deploy, skip DB migrations
.\deploy.ps1 myapp --skip-db

# Rollback to most recent backup
.\rollback.ps1 myapp

# Rollback to a specific backup + run DB Down scripts
.\rollback.ps1 myapp --backup myapp_bkp_20260628_143022.zip --db-rollback

# Dry-run rollback
.\rollback.ps1 myapp --dryrun
```

**What to verify:**
- `Logs/<project>/<date>/log.txt` — full step-by-step trace
- `Backup/<project>/` — backup zip created before deploy
- `--dryrun` — no files written, no services stopped/started, all steps logged as `[DRYRUN]`
- Health check URL returns 2xx after deploy
