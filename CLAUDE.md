# AutoDeploy — Claude Code Instructions

## Project Purpose

PowerShell deployment automation for Windows: IIS sites, Windows services, MSSQL/DB2 migrations. Entry points are `deploy.ps1` and `rollback.ps1` at the root.

## Architecture

```
deploy.ps1 / rollback.ps1      ← orchestrators, dot-source everything below
Deploy/logger.ps1              ← Write-Log, Initialize-Log
Deploy/helpers.ps1             ← all file/IIS/service/health/delta functions
SecretProviders/secrets.ps1    ← Resolve-Secret, Resolve-ProjectSecrets
SecretProviders/azure-keyvault.ps1
SecretProviders/environment.ps1
DbPersistence/db.ps1           ← Invoke-DbMigrations, Test-DbConnections, Test-DbScriptsExist
DbPersistence/mssql-provider.ps1
DbPersistence/db2-provider.ps1
ProjectConfigs/<name>-config.json   ← one per project
```

## Key Conventions

**Dot-sourcing order** — each file dot-sources only what it directly needs. `helpers.ps1` sources `logger.ps1`. `secrets.ps1` sources `azure-keyvault.ps1` and `environment.ps1`. `db.ps1` sources the two providers. The orchestrators source everything at the top.

**DryRun pattern** — every function that writes, copies, starts, or stops anything accepts `[switch]$DryRun`. When set, log with `Write-Log "DRYRUN"` and return without acting. Never skip the log line.

**Error handling** — functions throw on failure; callers catch and decide whether to rollback. Do not swallow errors silently.

**Step boundaries in orchestrators** — each step is wrapped in its own `try/catch`. Steps 1–4 of deploy abort cleanly (restarting any pools that were stopped). Steps 5–10 trigger `Invoke-AutoRollback` if `--auto-rollback` is set. Rollback steps in `rollback.ps1` are non-fatal — collect errors in `$allErrors` and continue.

**DB provider detection** — inferred from connection string content in `Get-DbProvider` (db.ps1). Do not add a provider field to config; keep the convention.

**Secret syntax** — `@secret:<key>` in any string value of `ConnectionStrings`. Resolved by `Resolve-ProjectSecrets` before any other step runs.

**Delta config naming** — `<site-or-service-name>__<target-filename>.delta.<ext>`. Double underscore separates name from filename. Files live in `ProjectConfigurationsPath` alongside the project config.

**Backup verification** — after `New-Backup`, always call `Test-BackupIntegrity` and abort if counts don't match. Do not skip this check.

**Health check retries** — 5 retries, 60 seconds flat between each. Do not make this configurable unless explicitly asked.

**Logging path** — `Logs/<project>/<yyyy-MM-dd>/log.txt`. `Initialize-Log` must be called before any `Write-Log`.

## Config Files

`config.json` — root config, `BackupPath` and `ProjectConfigurationsPath` only. Both optional.

`ProjectConfigs/<name>-config.json` — see `ProjectConfigs/sample-config.json` for the full schema. Required fields: `ProjectName`, `ProjectFileDropPath`. Everything else is optional depending on what's being deployed.

## Adding a New Feature

- New helper functions → `Deploy/helpers.ps1`
- New secret provider → new file in `SecretProviders/`, wire into `secrets.ps1`
- New DB provider → new file in `DbPersistence/`, add detection logic in `Get-DbProvider` and a `switch` case in `Invoke-DbMigrations`
- New deploy step → insert between existing steps in `deploy.ps1`, add entry to `$stepNames` array in `Show-DeploySummary`, update `$stepResults` hashtable size

## What Not to Change Without Discussion

- The 11-step deploy / 9-step rollback structure
- Backup-before-deploy requirement (step 3 must always precede step 5)
- The `@secret:` resolution order (KV → env)
- Rollback trigger threshold (steps 5+ only in deploy)
- 60-second health check wait interval
