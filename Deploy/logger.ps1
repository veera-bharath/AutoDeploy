$script:LogFile = $null
$script:ProjectName = $null

function Initialize-Log {
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$LogRoot = (Join-Path $PSScriptRoot "..\Logs")
    )
    $script:ProjectName = $ProjectName
    $date = Get-Date -Format "yyyy-MM-dd"
    $logDir = Join-Path $LogRoot "$ProjectName\$date"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $script:LogFile = Join-Path $logDir "log.txt"
    Write-Log "INFO" "=== Deploy session started for project: $ProjectName ==="
}

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet("INFO","WARN","ERROR","DRYRUN")][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "INFO"   { "Cyan" }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red" }
        "DRYRUN" { "Magenta" }
    }
    Write-Host $line -ForegroundColor $color

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}
