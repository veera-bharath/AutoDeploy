function Get-AzureSecret {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$VaultUrl,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://vault.azure.net/.default"
    }

    try {
        $tokenResp = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    } catch {
        throw "Azure Key Vault auth failed for tenant '$TenantId': $_"
    }

    $accessToken = $tokenResp.access_token
    $secretUrl   = "$($VaultUrl.TrimEnd('/'))/secrets/$Key`?api-version=7.4"
    $headers     = @{ Authorization = "Bearer $accessToken" }

    try {
        $secretResp = Invoke-RestMethod -Uri $secretUrl -Method GET -Headers $headers -ErrorAction Stop
        return $secretResp.value
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw "Azure Key Vault secret retrieval failed for key '$Key': $_"
    }
}
