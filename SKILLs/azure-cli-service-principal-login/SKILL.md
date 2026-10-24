---
name: azure-cli-service-principal-login
description: "Automatically use this skill whenever the user asks to work with Azure: authenticate with the restricted Service Principal, inspect Azure resources, query state, troubleshoot, or run Azure CLI commands."
---

# Azure CLI Service Principal for Agents

## Purpose

Use Azure CLI through the dedicated restricted Service Principal for Azure inspection, troubleshooting, state comparison, and other Azure CLI work.

The Service Principal is already restricted by Azure RBAC. Do not add agent-side permission restrictions unless the user explicitly asks for them.

## Authentication

Required environment variables:

- `AGENT_AZURE_CLIENT_ID`
- `AGENT_AZURE_CLIENT_SECRET`
- `AGENT_AZURE_SUBSCRIPTION_ID`
- `AGENT_AZURE_TENANT_ID`

Before the first `az` command in an Azure work session, dot-source the provided bootstrap script **in the same persistent PowerShell terminal that will run the later `az` commands**:

```powershell
. "<skill-directory>\scripts\connect-agent-azure.ps1"
```

Resolve `<skill-directory>` from this skill's installed path. Execute the script directly; do not copy, recreate, or expand its implementation into the terminal. Do not read the script unless authentication fails or the user asks to modify/debug it.

The bootstrap script:

- validates the required `AGENT_AZURE_*` variables
- creates an isolated agent-specific `AZURE_CONFIG_DIR`
- authenticates with the Service Principal
- explicitly selects `AGENT_AZURE_SUBSCRIPTION_ID`
- never modifies the developer's normal Azure CLI profile

Run the bootstrap once per persistent Azure work terminal. If the terminal/session is replaced or `AZURE_CONFIG_DIR` is no longer the agent directory, dot-source it again before using `az`.

Never:

- use the developer's cached/default Azure CLI login
- use browser/device-code login for agent work
- run `az logout` or `az account clear` against the developer's normal profile
- print secrets, access tokens, passwords, private keys, SAS tokens, connection strings, or Authorization headers

## Azure CLI First

After authentication, use Azure CLI directly.

**Important rules:**

- Do not generate PowerShell wrappers around individual Azure CLI commands.
- Do not recreate authentication/helper functions in the terminal.
- Do not use PowerShell to parse or transform Azure CLI JSON when `az --query` can return the required shape.
- Prefer a single targeted `az` command with JMESPath `--query`.
- Prefer `--output json`, `--output tsv`, or `--output table` according to the task.
- Add `--only-show-errors` for automation-oriented commands unless warnings are relevant to the diagnosis.
- Request only the fields needed for the task; avoid retrieving complete resource JSON when a targeted query is sufficient.
- Use `jq` only when Azure CLI/JMESPath cannot express the required transformation cleanly.
- Use PowerShell only for shell/control-flow logic that cannot reasonably be expressed by Azure CLI itself.
- Keep shell commands minimal. Do not generate defensive scripting unless the task actually requires it.

Preferred pattern:

```powershell
az resource show `
    --resource-group "<resource-group>" `
    --name "<resource-name>" `
    --resource-type "<resource-type>" `
    --api-version "<api-version>" `
    --query "<JMESPath>" `
    --output json `
    --only-show-errors
```

Avoid patterns such as:

```powershell
$json = az resource show ...
$obj = $json | ConvertFrom-Json
$obj.properties.items | ForEach-Object { ... }
```

when the same result can be returned directly by `az ... --query`.

## Read-only Inspection

When the user asks to check, inspect, compare, diagnose, investigate, or verify Azure state, default to read-only operations.

Do not modify Azure resources unless the user explicitly requests a change.

When inspecting secrets or secret-backed configuration:

- query secret names and metadata only when possible
- query `secretRef` relationships rather than secret values
- never request or display secret values unless the task absolutely requires them and the user explicitly requests it

## Terraform vs Azure

When comparing Terraform configuration with live Azure state:

1. Read only the relevant Terraform resource/module/provider configuration.
2. Identify which properties Terraform actually manages, including `ignore_changes` behavior.
3. Query only the corresponding live Azure properties with targeted `az ... --query` commands.
4. Compare semantically rather than textually.
5. Do not treat ordering differences as meaningful when the provider/API models the collection as unordered.
6. Explicitly identify live elements that are absent from Terraform and could therefore be removed or changed by an apply.
7. For destructive or replacement risk, distinguish configuration drift from changes that would recreate a resource.
8. If certainty depends on the actual Terraform plan, request or run `terraform plan` only when appropriate and explicitly separate plan evidence from live-state inference.

Do not retrieve secret values for Terraform comparison.

## Authentication Troubleshooting

If authentication fails, keep diagnostics short and follow this order:

1. Confirm `az` is available.
2. Confirm all four `AGENT_AZURE_*` variables exist and are non-empty.
3. Confirm `AZURE_CONFIG_DIR` points to the isolated agent directory.
4. Retry the bootstrap script.
5. If login succeeds but an Azure command returns authorization errors, treat it as an Azure RBAC/resource-scope issue rather than a login issue.

Do not replace the Service Principal variables with `AZURE_*` or `ARM_*` variables for Azure CLI authentication. `ARM_*` variables may be mapped separately only when Terraform execution requires them.

## Source of Truth

For production-critical authentication changes, verify current Microsoft Azure CLI Service Principal authentication documentation before changing the bootstrap implementation.
