. "$PSScriptRoot\..\SecretProviders\azure-keyvault.ps1"
. "$PSScriptRoot\..\SecretProviders\environment.ps1"

function Resolve-Secret {
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$AzureKeyVaultConfig = $null
    )

    if ($AzureKeyVaultConfig -and
        $AzureKeyVaultConfig.Url -and
        $AzureKeyVaultConfig.TenantId -and
        $AzureKeyVaultConfig.ClientId -and
        $AzureKeyVaultConfig.ClientSecret) {
        try {
            $val = Get-AzureSecret -Key $Key `
                -VaultUrl      $AzureKeyVaultConfig.Url `
                -TenantId      $AzureKeyVaultConfig.TenantId `
                -ClientId      $AzureKeyVaultConfig.ClientId `
                -ClientSecret  $AzureKeyVaultConfig.ClientSecret
            if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
        } catch {
            Write-Log "WARN" "Azure Key Vault lookup failed for '$Key', falling back to environment: $_"
        }
    }

    $val = Get-EnvSecret -Key $Key
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }

    throw "Secret '$Key' could not be resolved from Azure Key Vault or environment variables"
}

function Resolve-ProjectSecrets {
    param(
        [Parameter(Mandatory)][PSCustomObject]$ProjectConfig
    )
    $kvConfig = $null
    if ($ProjectConfig.PSObject.Properties["AzureKeyVault"] -and $ProjectConfig.AzureKeyVault) {
        $kv = $ProjectConfig.AzureKeyVault
        $kvConfig = @{
            Url          = $kv.Url
            TenantId     = $kv.TenantId
            ClientId     = $kv.ClientId
            ClientSecret = $kv.ClientSecret
        }
    }

    if ($ProjectConfig.PSObject.Properties["ConnectionStrings"] -and $ProjectConfig.ConnectionStrings) {
        $ProjectConfig.ConnectionStrings.PSObject.Properties | ForEach-Object {
            $prop = $_
            if ($prop.Value -match '^@secret:(.+)$') {
                $secretKey = $Matches[1]
                Write-Log "INFO" "Resolving secret for ConnectionStrings.$($prop.Name)"
                $resolved = Resolve-Secret -Key $secretKey -AzureKeyVaultConfig $kvConfig
                $ProjectConfig.ConnectionStrings | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $resolved -Force
            }
        }
    }

    return $ProjectConfig
}
