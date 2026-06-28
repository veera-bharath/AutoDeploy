function Invoke-MssqlScript {
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$SqlFile,
        [switch]$DryRun
    )
    if (-not (Test-Path $SqlFile)) { throw "SQL file not found: $SqlFile" }

    if ($DryRun) {
        Write-Log "DRYRUN" "Would execute MSSQL script: $(Split-Path $SqlFile -Leaf)"
        return
    }

    $sql     = Get-Content $SqlFile -Raw -Encoding UTF8
    $sqlcmd  = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue

    if ($sqlcmd) {
        $cs      = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($ConnectionString)
        $server  = $cs["Data Source"]
        $db      = $cs["Initial Catalog"]

        $tmpFile = [System.IO.Path]::GetTempFileName() + ".sql"
        $sql | Set-Content -Path $tmpFile -Encoding UTF8
        try {
            $sqlArgs = @("-S", $server, "-d", $db, "-i", $tmpFile, "-b")
            if ($cs["User ID"]) {
                $sqlArgs += @("-U", $cs["User ID"], "-P", $cs["Password"])
            } else {
                $sqlArgs += "-E"    # Windows auth
            }
            & sqlcmd.exe @sqlArgs 2>&1 | ForEach-Object { Write-Log "INFO" "    sqlcmd: $_" }
            if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
        } finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
        $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        try {
            $batches = $sql -split '\bGO\b', 0, 'Multiline,IgnoreCase' |
                       Where-Object { $_.Trim() }
            foreach ($batch in $batches) {
                $cmd                = $conn.CreateCommand()
                $cmd.CommandText    = $batch
                $cmd.CommandTimeout = 300
                $cmd.ExecuteNonQuery() | Out-Null
            }
        } finally {
            $conn.Close()
        }
    }
    Write-Log "INFO" "    Done: $(Split-Path $SqlFile -Leaf)"
}
