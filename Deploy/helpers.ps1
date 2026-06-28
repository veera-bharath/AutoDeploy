. "$PSScriptRoot\logger.ps1"

# ── Zip / Unzip ───────────────────────────────────────────────────────────────

function New-Backup {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$ProjectName,
        [switch]$DryRun
    )
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $zipName   = "${ProjectName}_bkp_${timestamp}.zip"
    $zipPath   = Join-Path $BackupDir $zipName

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Force $BackupDir | Out-Null }

    $existingPaths = $Paths | Where-Object { Test-Path $_ }
    if (-not $existingPaths) {
        Write-Log "WARN" "Backup: none of the source paths exist yet — skipping backup creation"
        return $null
    }

    if ($DryRun) {
        Write-Log "DRYRUN" "Would create backup: $zipPath"
        foreach ($p in $existingPaths) { Write-Log "DRYRUN" "  source: $p" }
        return $zipPath
    }

    Write-Log "INFO" "Copying sources to staging area..."
    $tmp = Join-Path $env:TEMP "autodeploy_backup_$timestamp"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    foreach ($p in $existingPaths) {
        $dest = Join-Path $tmp (Split-Path $p -Leaf)
        Write-Log "INFO" "  $p → staging"
        Copy-Item -Path $p -Destination $dest -Recurse -Force
    }

    Write-Log "INFO" "Compressing backup → $zipPath"
    Compress-Archive -Path "$tmp\*" -DestinationPath $zipPath -Force
    Remove-Item $tmp -Recurse -Force
    return $zipPath
}

function Test-BackupIntegrity {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string[]]$SourcePaths
    )
    if (-not (Test-Path $ZipPath)) { throw "Backup zip not found for verification: $ZipPath" }

    $sourceCount = 0
    foreach ($path in $SourcePaths) {
        if (Test-Path $path) {
            $sourceCount += (Get-ChildItem -Path $path -Recurse -File -Force | Measure-Object).Count
        }
    }

    Add-Type -AssemblyName "System.IO.Compression.FileSystem"
    $zip      = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $zipCount = 0
    try {
        $zipCount = ($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | Measure-Object).Count
    } finally {
        $zip.Dispose()
    }

    return [PSCustomObject]@{
        SourceFileCount = $sourceCount
        ZipEntryCount   = $zipCount
        IsValid         = ($zipCount -eq $sourceCount)
    }
}

function Restore-Backup {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string[]]$RestorePaths,
        [switch]$DryRun
    )
    if (-not (Test-Path $ZipPath)) { throw "Backup zip not found: $ZipPath" }

    if ($DryRun) {
        Write-Log "DRYRUN" "Would restore backup: $ZipPath"
        foreach ($p in $RestorePaths) { Write-Log "DRYRUN" "  → $p" }
        return
    }

    $tmp = Join-Path $env:TEMP "autodeploy_restore_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Write-Log "INFO" "Extracting backup to staging..."
    Expand-Archive -Path $ZipPath -DestinationPath $tmp -Force

    foreach ($target in $RestorePaths) {
        $folderName = Split-Path $target -Leaf
        $source     = Join-Path $tmp $folderName
        if (Test-Path $source) {
            Write-Log "INFO" "Restoring: $folderName → $target"
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            Copy-Item -Path $source -Destination $target -Recurse -Force
        } else {
            Write-Log "WARN" "Backup does not contain '$folderName' — skipping restore for: $target"
        }
    }
    Remove-Item $tmp -Recurse -Force
    Write-Log "INFO" "Restore complete from: $(Split-Path $ZipPath -Leaf)"
}

function Expand-ZipArtifact {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$ArtifactFolderName,
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$DryRun
    )
    if (-not (Test-Path $ZipPath)) { throw "Artifact zip not found: $ZipPath" }

    if ($DryRun) {
        $sub = if ($ArtifactFolderName) { " (subfolder: $ArtifactFolderName)" } else { "" }
        Write-Log "DRYRUN" "Would expand $(Split-Path $ZipPath -Leaf) → $OutDir$sub"
        return $OutDir
    }

    if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $OutDir -Force

    if ($ArtifactFolderName) {
        $sub = Join-Path $OutDir $ArtifactFolderName
        if (-not (Test-Path $sub)) { throw "ArtifactFolderName '$ArtifactFolderName' not found inside zip" }
        return $sub
    }
    return $OutDir
}

# ── File copy with ignore lists ───────────────────────────────────────────────

function Purge-Directory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$IgnoreFiles = @(),
        [string[]]$IgnoreDirs  = @(),
        [switch]$DryRun
    )
    if (-not (Test-Path $Path)) { return }

    Get-ChildItem -Path $Path -Force | ForEach-Object {
        $item = $_
        if ($item.PSIsContainer) {
            if ($IgnoreDirs -and ($IgnoreDirs | Where-Object { $item.Name -like $_ })) { return }
            if ($DryRun) { Write-Log "DRYRUN" "Would remove dir: $($item.FullName)" ; return }
            Remove-Item $item.FullName -Recurse -Force
        } else {
            if ($IgnoreFiles -and ($IgnoreFiles | Where-Object { $item.Name -like $_ })) { return }
            if ($DryRun) { Write-Log "DRYRUN" "Would remove file: $($item.FullName)" ; return }
            Remove-Item $item.FullName -Force
        }
    }
}

function Copy-FilesWithIgnore {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest,
        [string[]]$IgnoreFiles = @(),
        [string[]]$IgnoreDirs  = @(),
        [switch]$DryRun
    )
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force $Dest | Out-Null }

    Get-ChildItem -Path $Source -Force | ForEach-Object {
        $item     = $_
        $destItem = Join-Path $Dest $item.Name

        if ($item.PSIsContainer) {
            if ($IgnoreDirs -and ($IgnoreDirs | Where-Object { $item.Name -like $_ })) {
                Write-Log "INFO" "  Skipping dir (ignored): $($item.Name)"
                return
            }
            Copy-FilesWithIgnore -Source $item.FullName -Dest $destItem `
                -IgnoreFiles $IgnoreFiles -IgnoreDirs $IgnoreDirs -DryRun:$DryRun
        } else {
            if ($IgnoreFiles -and ($IgnoreFiles | Where-Object { $item.Name -like $_ })) {
                Write-Log "INFO" "  Skipping file (ignored): $($item.Name)"
                return
            }
            if ($DryRun) { Write-Log "DRYRUN" "  Would copy: $($item.Name) → $destItem" ; return }
            Copy-Item -Path $item.FullName -Destination $destItem -Force
        }
    }
}

# ── IIS App Pool ──────────────────────────────────────────────────────────────

function Get-AppPoolStatus {
    param([Parameter(Mandatory)][string]$Name)
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $prop = Get-WebConfigurationProperty `
            -Filter "/system.applicationHost/applicationPools/add[@name='$Name']" `
            -Name state -ErrorAction Stop
        return $prop.Value
    } catch {
        # Fall back to appcmd
        $out = & appcmd list apppool "$Name" /text:state 2>$null
        if ($out) { return $out.Trim() }
        return "Unknown"
    }
}

function Stop-AppPool {
    param([Parameter(Mandatory)][string]$Name, [switch]$DryRun)
    if ($DryRun) { Write-Log "DRYRUN" "Would stop App Pool: $Name" ; return }

    $status = Get-AppPoolStatus -Name $Name
    if ($status -eq 'Stopped') {
        Write-Log "INFO" "App Pool already stopped: $Name"
        return
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Stop-WebAppPool -Name $Name -ErrorAction Stop
    } catch {
        & appcmd stop apppool /apppool.name:"$Name" 2>&1 | ForEach-Object { Write-Log "INFO" "appcmd: $_" }
    }
    Write-Log "INFO" "App Pool stopped: $Name"
}

function Start-AppPool {
    param([Parameter(Mandatory)][string]$Name, [switch]$DryRun)
    if ($DryRun) { Write-Log "DRYRUN" "Would start App Pool: $Name" ; return }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Start-WebAppPool -Name $Name -ErrorAction Stop
    } catch {
        & appcmd start apppool /apppool.name:"$Name" 2>&1 | ForEach-Object { Write-Log "INFO" "appcmd: $_" }
    }
    Write-Log "INFO" "App Pool started: $Name"
}

# ── Windows Services ──────────────────────────────────────────────────────────

function Stop-ServiceSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 30,
        [switch]$DryRun
    )
    if ($DryRun) { Write-Log "DRYRUN" "Would stop service: $Name" ; return }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc)                    { Write-Log "WARN" "Service not found: $Name" ; return }
    if ($svc.Status -eq 'Stopped')   { Write-Log "INFO" "Service already stopped: $Name" ; return }

    Stop-Service -Name $Name -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if ((Get-Service -Name $Name).Status -eq 'Stopped') {
            Write-Log "INFO" "Service stopped: $Name"
            return
        }
    }
    throw "Service '$Name' did not stop within ${TimeoutSec}s"
}

function Start-ServiceSafe {
    param([Parameter(Mandatory)][string]$Name, [switch]$DryRun)
    if ($DryRun) { Write-Log "DRYRUN" "Would start service: $Name" ; return }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log "WARN" "Service not found: $Name" ; return }

    Start-Service -Name $Name -ErrorAction Stop
    Write-Log "INFO" "Service started: $Name"
}

# ── Health Check ──────────────────────────────────────────────────────────────

function Invoke-HealthCheck {
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet("GET","POST")][string]$Method = "GET",
        [int]$Retries = 5,
        [switch]$DryRun
    )
    if ($DryRun) { Write-Log "DRYRUN" "Would health check ($Method): $Url (up to $Retries retries, 60s apart)" ; return }

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method $Method -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                Write-Log "INFO" "Health check passed [$($resp.StatusCode)]: $Url"
                return
            }
            Write-Log "WARN" "Health check attempt $i/$Retries — status $($resp.StatusCode)"
        } catch {
            Write-Log "WARN" "Health check attempt $i/$Retries — $($_.Exception.Message)"
        }
        if ($i -lt $Retries) {
            Write-Log "INFO" "Waiting 60 seconds before retry $($i + 1)/$Retries..."
            Start-Sleep -Seconds 60
        }
    }
    throw "Health check failed after $Retries attempts: $Url"
}

# ── Delta Config Patching ─────────────────────────────────────────────────────

function Apply-DeltaConfig {
    param(
        [Parameter(Mandatory)][string]$TargetFile,
        [Parameter(Mandatory)][string]$DeltaFile,
        [switch]$DryRun
    )
    if (-not (Test-Path $TargetFile)) { throw "Target config not found: $TargetFile" }
    if (-not (Test-Path $DeltaFile))  { throw "Delta config not found: $DeltaFile" }

    $ext = [System.IO.Path]::GetExtension($TargetFile).ToLower()
    switch ($ext) {
        ".json"   { Merge-JsonDelta -TargetPath $TargetFile -DeltaPath $DeltaFile -DryRun:$DryRun }
        { $_ -in ".config",".xml" } { Merge-XmlDelta -TargetPath $TargetFile -DeltaPath $DeltaFile -DryRun:$DryRun }
        default   { throw "Unsupported delta target extension '$ext': $TargetFile" }
    }
}

function Merge-JsonDelta {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$DeltaPath,
        [switch]$DryRun
    )
    $target = Get-Content $TargetPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $delta  = Get-Content $DeltaPath  -Raw -Encoding UTF8 | ConvertFrom-Json

    function Merge-Objects($base, $patch) {
        $patch.PSObject.Properties | ForEach-Object {
            $key = $_.Name ; $val = $_.Value
            if ($val -is [System.Management.Automation.PSCustomObject] -and
                $base.PSObject.Properties[$key] -and
                $base.$key -is [System.Management.Automation.PSCustomObject]) {
                Merge-Objects $base.$key $val
            } else {
                $base | Add-Member -MemberType NoteProperty -Name $key -Value $val -Force
            }
        }
    }

    Merge-Objects $target $delta

    if ($DryRun) { Write-Log "DRYRUN" "Would write merged JSON to: $TargetPath" ; return }
    $target | ConvertTo-Json -Depth 20 | Set-Content -Path $TargetPath -Encoding UTF8
    Write-Log "INFO" "Applied JSON delta: $(Split-Path $DeltaPath -Leaf) → $(Split-Path $TargetPath -Leaf)"
}

function Merge-XmlDelta {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$DeltaPath,
        [switch]$DryRun
    )
    [xml]$targetXml = Get-Content $TargetPath -Encoding UTF8
    [xml]$deltaXml  = Get-Content $DeltaPath  -Encoding UTF8

    function Merge-XmlNodes($targetParent, $deltaParent) {
        foreach ($deltaChild in $deltaParent.ChildNodes) {
            if ($deltaChild.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }

            $keyAttr = @("key","name","type") |
                       Where-Object { $deltaChild.HasAttribute($_) } |
                       Select-Object -First 1
            $match = $null
            if ($keyAttr) {
                $keyVal = $deltaChild.GetAttribute($keyAttr)
                $match  = $targetParent.ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                    $_.LocalName -eq $deltaChild.LocalName -and
                    $_.GetAttribute($keyAttr) -eq $keyVal
                } | Select-Object -First 1
            }

            if ($match) {
                foreach ($attr in $deltaChild.Attributes) { $match.SetAttribute($attr.Name, $attr.Value) }
                Merge-XmlNodes $match $deltaChild
            } else {
                $targetParent.AppendChild($targetXml.ImportNode($deltaChild, $true)) | Out-Null
            }
        }
    }

    Merge-XmlNodes $targetXml.DocumentElement $deltaXml.DocumentElement

    if ($DryRun) { Write-Log "DRYRUN" "Would write merged XML to: $TargetPath" ; return }
    $targetXml.Save($TargetPath)
    Write-Log "INFO" "Applied XML delta: $(Split-Path $DeltaPath -Leaf) → $(Split-Path $TargetPath -Leaf)"
}
