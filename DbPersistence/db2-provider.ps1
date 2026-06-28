function Invoke-Db2Script {
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$SqlFile,
        [switch]$DryRun
    )
    if (-not (Test-Path $SqlFile)) { throw "SQL file not found: $SqlFile" }

    $sql = Get-Content $SqlFile -Raw -Encoding UTF8

    if ($DryRun) {
        Write-Log "DRYRUN" "Would execute DB2 script: $SqlFile"
        return
    }

    $db2cmd = Get-Command db2.exe -ErrorAction SilentlyContinue
    if ($db2cmd) {
        # Parse minimal fields from ODBC-style connection string
        $csLower  = $ConnectionString.ToLower()
        $database = if ($csLower -match 'database=([^;]+)') { $Matches[1].Trim() } else { "" }
        $uid      = if ($csLower -match 'uid=([^;]+)')      { $Matches[1].Trim() } elseif ($csLower -match 'user\s*id=([^;]+)') { $Matches[1].Trim() } else { "" }
        $pwd      = if ($csLower -match 'pwd=([^;]+)')      { $Matches[1].Trim() } elseif ($csLower -match 'password=([^;]+)')   { $Matches[1].Trim() } else { "" }

        $tmpFile = [System.IO.Path]::GetTempFileName() + ".sql"
        $sql | Set-Content -Path $tmpFile -Encoding UTF8
        try {
            $connectCmd = "CONNECT TO $database USER $uid USING $pwd"
            & db2.exe $connectCmd 2>&1 | ForEach-Object { Write-Log "INFO" "db2: $_" }
            & db2.exe "-tf" $tmpFile 2>&1 | ForEach-Object { Write-Log "INFO" "db2: $_" }
            if ($LASTEXITCODE -ne 0) { throw "db2 exited with code $LASTEXITCODE for: $SqlFile" }
        } finally {
            & db2.exe "CONNECT RESET" 2>&1 | Out-Null
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
        $conn = New-Object System.Data.Odbc.OdbcConnection($ConnectionString)
        $conn.Open()
        try {
            $statements = $sql -split ';\s*(\r?\n|$)' | Where-Object { $_.Trim() }
            foreach ($stmt in $statements) {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText    = $stmt
                $cmd.CommandTimeout = 300
                $cmd.ExecuteNonQuery() | Out-Null
            }
        } finally {
            $conn.Close()
        }
    }
    Write-Log "INFO" "DB2 script executed: $(Split-Path $SqlFile -Leaf)"
}
