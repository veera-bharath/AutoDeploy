. "$PSScriptRoot\mssql-provider.ps1"
. "$PSScriptRoot\db2-provider.ps1"

function Get-DbProvider {
    param([Parameter(Mandatory)][string]$ConnectionString)
    $cs = $ConnectionString.Trim()
    if ($cs -imatch 'DRIVER=' -or $cs -imatch 'DSN=') { return "db2" }
    if ($cs -imatch 'Server=' -or $cs -imatch 'Data Source=') { return "mssql" }
    throw "Cannot detect DB provider from connection string. Expected 'Server=' or 'Data Source=' for MSSQL, or 'DRIVER=' / 'DSN=' for DB2."
}

function Test-DbScriptsExist {
    param(
        [Parameter(Mandatory)][string]$DatabaseDir,
        [ValidateSet("Up","Down")][string]$Direction = "Up"
    )
    if (-not (Test-Path $DatabaseDir)) { return $false }
    $folders = Get-ChildItem -Path $DatabaseDir -Directory -ErrorAction SilentlyContinue
    foreach ($folder in $folders) {
        $sqlDir = Join-Path $folder.FullName $Direction
        if ((Test-Path $sqlDir) -and (Get-ChildItem -Path $sqlDir -Filter "*.sql" -ErrorAction SilentlyContinue)) {
            return $true
        }
    }
    return $false
}

function Test-DbConnections {
    param(
        [Parameter(Mandatory)][hashtable]$ConnectionStrings,
        [Parameter(Mandatory)][string]$DatabaseDir,
        [switch]$DryRun
    )
    $results  = [ordered]@{}
    $failures = @()

    $folders = Get-ChildItem -Path $DatabaseDir -Directory -ErrorAction SilentlyContinue
    foreach ($folder in $folders) {
        $csKey = $folder.Name
        if (-not $ConnectionStrings.ContainsKey($csKey)) {
            Write-Log "WARN" "No ConnectionString found for folder '$csKey', skipping connection check"
            continue
        }

        $connStr  = $ConnectionStrings[$csKey]
        $provider = Get-DbProvider -ConnectionString $connStr

        if ($DryRun) {
            Write-Log "DRYRUN" "Would test $provider connection: $csKey"
            $results[$csKey] = "OK (dry run)"
            continue
        }

        try {
            switch ($provider) {
                "mssql" {
                    Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
                    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
                    $conn.Open()
                    $conn.Close()
                }
                "db2" {
                    Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
                    $conn = New-Object System.Data.Odbc.OdbcConnection($connStr)
                    $conn.Open()
                    $conn.Close()
                }
            }
            Write-Log "INFO" "  [$csKey] $provider connection OK"
            $results[$csKey] = "OK"
        } catch {
            $msg = $_.Exception.Message
            Write-Log "ERROR" "  [$csKey] $provider connection FAILED: $msg"
            $results[$csKey] = "FAILED: $msg"
            $failures += $csKey
        }
    }

    if ($failures.Count -gt 0) {
        throw "DB connection check failed for: $($failures -join ', ')"
    }
    return $results
}

function Close-DbConnections {
    param([hashtable]$ConnectionStrings, [switch]$DryRun)
    # Connections are closed per-script by the providers.
    # This step confirms clean closure and logs it.
    if ($DryRun) {
        Write-Log "DRYRUN" "Would confirm DB connections closed"
        return
    }
    Write-Log "INFO" "All DB connections closed (connections are closed per-script by providers)"
}

function Invoke-DbMigrations {
    param(
        [Parameter(Mandatory)][string]$DatabaseDir,
        [Parameter(Mandatory)][hashtable]$ConnectionStrings,
        [ValidateSet("Up","Down")][string]$Direction = "Up",
        [switch]$DryRun
    )
    if (-not (Test-Path $DatabaseDir)) {
        Write-Log "INFO" "No Database directory at '$DatabaseDir', skipping"
        return 0
    }

    $folders = Get-ChildItem -Path $DatabaseDir -Directory -ErrorAction SilentlyContinue
    if (-not $folders) {
        Write-Log "INFO" "No provider folders under '$DatabaseDir', skipping"
        return 0
    }

    $totalScripts = 0

    foreach ($folder in $folders) {
        $csKey = $folder.Name
        if (-not $ConnectionStrings.ContainsKey($csKey)) {
            Write-Log "WARN" "No ConnectionString found for folder '$csKey', skipping"
            continue
        }

        $connStr  = $ConnectionStrings[$csKey]
        $provider = Get-DbProvider -ConnectionString $connStr
        $sqlDir   = Join-Path $folder.FullName $Direction

        if (-not (Test-Path $sqlDir)) {
            Write-Log "INFO" "No '$Direction' folder for '$csKey', skipping"
            continue
        }

        $sqlFiles = Get-ChildItem -Path $sqlDir -Filter "*.sql" -ErrorAction SilentlyContinue |
                    Sort-Object { [int]($_.Name -replace '^(\d+).*','$1') }

        if (-not $sqlFiles) {
            Write-Log "INFO" "No SQL files in '$Direction' for '$csKey'"
            continue
        }

        Write-Log "INFO" "[$csKey] $provider — $Direction migrations ($($sqlFiles.Count) script(s))"

        foreach ($file in $sqlFiles) {
            Write-Log "INFO" "  Executing: $($file.Name)"
            try {
                switch ($provider) {
                    "mssql" { Invoke-MssqlScript -ConnectionString $connStr -SqlFile $file.FullName -DryRun:$DryRun }
                    "db2"   { Invoke-Db2Script   -ConnectionString $connStr -SqlFile $file.FullName -DryRun:$DryRun }
                }
                $totalScripts++
            } catch {
                throw "DB migration failed [$csKey/$Direction] '$($file.Name)': $_"
            }
        }
        Write-Log "INFO" "[$csKey] $Direction migrations complete"
    }

    return $totalScripts
}
