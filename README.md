# AutoDeploy

A fully automated PowerShell deployment system for Windows environments — IIS web applications, Windows services, and SQL database migrations (MSSQL + DB2).

---

## Features

- **11-step deploy flow** with pre-deploy backup and post-deploy health checks
- **9-step rollback flow** with automatic fallback to manual instructions if rollback fails
- **Backup integrity verification** — file count in zip is checked against source before proceeding
- **Secret resolution** — Azure Key Vault → environment variables, with `@secret:` syntax in config
- **Delta config patching** — deep-merge JSON configs and XML `.config` files after deployment
- **DB migrations** — ordered Up/Down SQL scripts per connection, MSSQL and DB2 supported
- **Dry-run mode** — simulate every step without touching files, services, or databases
- **Auto-rollback** — triggered automatically on failure from step 5 onwards

---

## Directory Structure

```
AutoDeploy/
│
├── deploy.ps1                  # Deploy orchestrator
├── rollback.ps1                # Rollback orchestrator
├── config.json                 # Root config (backup path, project configs path)
│
├── Deploy/
│   ├── helpers.ps1             # File ops, IIS, service control, health check, delta patch
│   └── logger.ps1              # Write-Log — console + file output
│
├── SecretProviders/
│   ├── secrets.ps1             # Resolve-Secret orchestrator
│   ├── azure-keyvault.ps1      # Azure Key Vault via REST (no Az module required)
│   └── environment.ps1         # Environment variable lookup
│
├── DbPersistence/
│   ├── db.ps1                  # Migration runner + connection tester
│   ├── mssql-provider.ps1      # sqlcmd.exe or System.Data.SqlClient
│   └── db2-provider.ps1        # db2.exe or System.Data.Odbc
│
├── ProjectConfigs/             # One config file per project
│   └── <project>-config.json
│
├── DeployFiles/                # Drop zone — set per project via ProjectFileDropPath
│   ├── App/
│   │   └── app.zip
│   ├── Services/
│   │   ├── service.zip
│   │   ├── install.bat         # Optional — runs on new service install
│   │   └── uninstall.bat       # Optional
│   ├── Database/
│   │   └── <ConnectionStringKey>/
│   │       ├── Up/             # 1_CreateTable.sql, 2_AddColumn.sql ...
│   │       └── Down/           # 1_AddColumn.sql, 2_CreateTable.sql ...
│   └── Files/                  # Any additional files
│
├── Logs/
│   └── <project>/<yyyy-MM-dd>/log.txt
│
└── Backup/
    └── <project>/<project>_bkp_<timestamp>.zip
```

---

## Quick Start

### 1. Configure `config.json`

```json
{
  "BackupPath": "D:\\Deployments\\Backup",
  "ProjectConfigurationsPath": "D:\\Deployments\\ProjectConfigs"
}
```

Both fields are optional — defaults to `Backup\` and `ProjectConfigs\` next to the scripts.

### 2. Create a project config

`ProjectConfigs\myapp-config.json`:

```json
{
  "ProjectName": "myapp",
  "ProjectFileDropPath": "D:\\Drop\\myapp",
  "ConnectionStrings": {
    "MssqlConnection": "@secret:MssqlConnection"
  },
  "AzureKeyVault": {
    "Url": "https://my-vault.vault.azure.net",
    "TenantId": "...",
    "ClientId": "...",
    "ClientSecret": "..."
  },
  "AppConfiguration": [
    {
      "SiteName": "MyApp",
      "SitePath": "C:\\inetpub\\wwwroot\\myapp",
      "AppPoolName": "MyAppPool",
      "ArtifactFolderName": "publish",
      "HealthCheckUrl": "http://localhost/health",
      "HealthCheckType": "GET",
      "IgnoreFiles": ["appsettings*.json", "web.config"],
      "IgnoreDirs": ["logs"],
      "Purge": false,
      "DeltaConfig": "MyApp__appsettings.delta.json"
    }
  ]
}
```

### 3. Drop your artifacts

```
D:\Drop\myapp\
  App\app.zip
  Services\service.zip       (if applicable)
  Database\MssqlConnection\
    Up\1_CreateUsersTable.sql
    Down\1_CreateUsersTable.sql
```

### 4. Deploy

```powershell
.\deploy.ps1 myapp
```

---

## Deploy Flow

| Step | Description |
|------|-------------|
| 1 | **Validate files** — check artifacts exist, DB folder keys match config |
| 2 | **Stop application pools / services** |
| 3 | **Backup sites** — zip current files, verify zip file count matches source |
| 4 | **Unzip artifacts** — extract to temp before touching production |
| 5 | **Deploy sites** — copy files, apply delta configs ← *rollback triggers from here* |
| 6 | **Restart application pools / services** |
| 7 | **Check DB connections** — open/close test per connection string |
| 8 | **Apply DB migrations** — Up scripts in numeric order |
| 9 | **Close DB connections** |
| 10 | **Health check sites** — up to 5 retries, 60 seconds apart |
| 11 | **Summary** |

---

## Rollback Flow

| Step | Description |
|------|-------------|
| 1 | **Check status and stop** app pools / services if running |
| 2 | **Get backup** — most recent zip, or specify with `--backup` |
| 3 | **Restore files** from backup |
| 4 | **Check DB connections** |
| 5 | **Apply DB Down scripts** in numeric order |
| 6 | **Close DB connections** |
| 7 | **Restart** application pools / services |
| 8 | **Health checks** |
| 9 | **Summary** — if any step failed, prints step-by-step manual instructions |

---

## CLI Reference

### `deploy.ps1`

```powershell
.\deploy.ps1 <project-name> [flags]
```

| Flag | Description |
|------|-------------|
| `--skip-db` | Skip DB connection check and migrations |
| `--auto-rollback` | Automatically rollback on failure from step 5 onwards |
| `--db-rollback` | Include DB Down scripts when auto-rollback triggers |
| `--dryrun` | Simulate all steps — no files, restarts, or DB changes |
| `--help` | Show usage |

### `rollback.ps1`

```powershell
.\rollback.ps1 <project-name> [flags]
```

| Flag | Description |
|------|-------------|
| `--backup <filename>` | Restore a specific backup zip (default: most recent) |
| `--db-rollback` | Run DB Down scripts after restoring files |
| `--dryrun` | Simulate all steps |
| `--help` | Show usage |

### Common examples

```powershell
# Standard deploy
.\deploy.ps1 myapp

# Deploy with auto-rollback (including DB) on any failure
.\deploy.ps1 myapp --auto-rollback --db-rollback

# Deploy without running DB migrations
.\deploy.ps1 myapp --skip-db

# Simulate a full deploy without touching anything
.\deploy.ps1 myapp --dryrun

# Rollback to the most recent backup
.\rollback.ps1 myapp

# Rollback to a specific backup and run DB Down scripts
.\rollback.ps1 myapp --backup myapp_bkp_20260628_143022.zip --db-rollback

# Simulate rollback
.\rollback.ps1 myapp --dryrun
```

---

## Project Config Reference

```jsonc
{
  "ProjectName": "myapp",
  "ProjectFileDropPath": "<path to DeployFiles folder>",

  "ConnectionStrings": {
    // Literal value or @secret:<key> to resolve from Key Vault / env var
    "MssqlConnection": "@secret:MssqlConnection",
    "Db2Connection": "DATABASE=MYDB;HOSTNAME=host;PORT=50000;UID=u;PWD=p;"
  },

  "AzureKeyVault": {
    // Optional — omit if using environment variables only
    "Url": "https://my-vault.vault.azure.net",
    "TenantId": "<tenant-id>",
    "ClientId": "<client-id>",
    "ClientSecret": "<client-secret>"
  },

  "AppConfiguration": [
    {
      "SiteName": "<IIS site name>",
      "SitePath": "<path to site files>",
      "AppPoolName": "<app pool name>",
      "ArtifactFolderName": "<subfolder inside app.zip>",
      "HealthCheckUrl": "<url>",
      "HealthCheckType": "GET",        // or "POST" — optional, default GET
      "IgnoreFiles": ["appsettings*.json", "web.config"],
      "IgnoreDirs": ["logs", "assets"],
      "Purge": false,                  // delete site dir contents before copying
      "DeltaConfig": "<site>__appsettings.delta.json"
    }
  ],

  "ServiceConfiguration": [
    {
      "ServiceName": "<Windows service name>",
      "ServicePath": "<path to service files>",
      "ArtifactFolderName": "<subfolder inside service.zip>",
      "IgnoreFiles": ["appsettings*.json"],
      "IgnoreDirs": ["logs"],
      "Purge": false,
      "DeltaConfig": "<service>__appsettings.delta.json"
    }
  ]
}
```

---

## Secret Resolution

Values prefixed with `@secret:<key>` are resolved at deploy time in this order:

1. **Azure Key Vault** — if the `AzureKeyVault` block is present and complete in the project config
2. **Environment variables** — process-level, then machine-level

If neither resolves the secret, the deployment fails with a clear error.

---

## Delta Config Patching

Place delta files in the same folder as the project config. The naming convention determines which file to patch:

```
<site-or-service-name>__<target-filename>.delta.<ext>
```

**Examples:**
- `MyApp__appsettings.delta.json` → patches `appsettings.json` in the site directory
- `MyApp__web.delta.config` → patches `web.config` in the site directory

**JSON** (`.json`): Recursive deep merge — existing keys are overwritten, new keys are added, hierarchy is preserved.

**XML** (`.config`): Element merge by `key`, `name`, or `type` attribute — existing elements are updated, missing elements are appended.

---

## DB Migrations

SQL scripts live under `DeployFiles/Database/<ConnectionStringKey>/Up/` and `.../Down/`.

- Files are executed in **numeric filename order** (`1_`, `2_`, `3_` prefix)
- The folder name must match a key in `ConnectionStrings`
- Provider is auto-detected from the connection string:
  - `Server=` or `Data Source=` → MSSQL
  - `DRIVER=` or `DSN=` → DB2
- MSSQL uses `sqlcmd.exe` if available, otherwise `System.Data.SqlClient`
- DB2 uses `db2.exe` if available, otherwise `System.Data.Odbc`

---

## Logging

Each run appends to:

```
Logs/<project>/<yyyy-MM-dd>/log.txt
```

Log format: `[HH:mm:ss] [LEVEL] message`

Levels: `INFO` (cyan) · `WARN` (yellow) · `ERROR` (red) · `DRYRUN` (magenta)

---

## Requirements

- Windows PowerShell 5.1+
- Administrator privileges (IIS App Pool management, Windows Services)
- IIS: `WebAdministration` module **or** `appcmd.exe` on PATH
- MSSQL migrations: `sqlcmd.exe` on PATH **or** .NET `System.Data.SqlClient`
- DB2 migrations: `db2.exe` on PATH **or** ODBC driver installed
- Azure Key Vault: no Az module required — uses REST API with client credentials
