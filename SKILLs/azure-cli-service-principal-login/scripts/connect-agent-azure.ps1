$ErrorActionPreference = "Stop"

function Get-RequiredAgentEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "User")
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "Machine")
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable is missing or empty: $Name"
    }

    Set-Item -Path "Env:$Name" -Value $value
    return $value
}

if (-not (Get-Command -Name "az" -ErrorAction SilentlyContinue)) {
    throw "Azure CLI executable 'az' was not found in PATH."
}

$clientId = Get-RequiredAgentEnvironmentVariable -Name "AGENT_AZURE_CLIENT_ID"
$clientSecret = Get-RequiredAgentEnvironmentVariable -Name "AGENT_AZURE_CLIENT_SECRET"
$subscriptionId = Get-RequiredAgentEnvironmentVariable -Name "AGENT_AZURE_SUBSCRIPTION_ID"
$tenantId = Get-RequiredAgentEnvironmentVariable -Name "AGENT_AZURE_TENANT_ID"

if ([string]::IsNullOrWhiteSpace($env:AGENT_AZURE_CONFIG_DIR)) {
    $sessionId = [Guid]::NewGuid().ToString("N")
    $env:AGENT_AZURE_CONFIG_DIR = Join-Path $env:TEMP "agent-azure-cli-sp-$sessionId"
}

$env:AZURE_CONFIG_DIR = $env:AGENT_AZURE_CONFIG_DIR
New-Item -ItemType Directory -Force -Path $env:AZURE_CONFIG_DIR | Out-Null

$loginOutput = & az login `
    --service-principal `
    --username $clientId `
    "--password=$clientSecret" `
    --tenant $tenantId `
    --output none `
    --only-show-errors 2>&1

if ($LASTEXITCODE -ne 0) {
    $safeOutput = ($loginOutput | Out-String).Replace($clientSecret, "<redacted>")
    throw "Azure CLI Service Principal sign-in failed.`n$safeOutput"
}

$subscriptionOutput = & az account set `
    --subscription $subscriptionId `
    --only-show-errors 2>&1

if ($LASTEXITCODE -ne 0) {
    $safeOutput = ($subscriptionOutput | Out-String).Replace($clientSecret, "<redacted>")
    throw "Azure CLI subscription selection failed.`n$safeOutput"
}

Write-Output "Azure CLI Service Principal session initialized."
