function Get-EnvSecret {
    param([Parameter(Mandatory)][string]$Key)

    $value = [System.Environment]::GetEnvironmentVariable($Key)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [System.Environment]::GetEnvironmentVariable($Key, [System.EnvironmentVariableTarget]::Machine)
    }
    return $value
}
