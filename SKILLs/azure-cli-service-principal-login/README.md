# Azure CLI Service Principal Login

**An AI agent skill for authenticated Azure CLI operations using a dedicated Microsoft Entra service principal and an isolated Azure CLI profile.**

This skill lets an AI coding or operations agent investigate Azure resources without borrowing the developer's personal Azure CLI session. A PowerShell bootstrap script signs in non-interactively with the configured service principal, selects the intended subscription, and points Azure CLI at a separate configuration directory. The agent then uses ordinary `az` commands to inspect resources, troubleshoot failures, and compare live Azure state with infrastructure-as-code.

> **Access model:** The service principal's **Azure RBAC assignments** determine what the agent can actually do. For inspection tasks, the skill tells the agent to use read-only commands, but this is **not** a read-only enforcement mechanism. Assign least-privilege roles to the service principal.

## What it does

- Authenticates Azure CLI with a dedicated service principal (client ID and client secret).
- Selects a specific Azure subscription after sign-in.
- Creates or reuses an **agent-specific `AZURE_CONFIG_DIR`**, keeping authentication state separate from the developer's default Azure CLI profile.
- Works with a persistent Windows PowerShell session so later `az` commands use the same authenticated context.
- Guides the agent toward focused Azure CLI queries using `--query` (JMESPath) and structured output.
- Supports Azure resource inspection, troubleshooting, state verification, and comparison with Terraform configuration.
- Defaults to **inspection only** when the user requests a check or investigation; changes require an explicit user request and sufficient Azure permissions.

**Not included:** Service principal creation, RBAC role assignment, secret rotation, a dedicated Azure API proxy, or a technical allowlist of `az` commands. This skill is an authentication and usage workflow, not a sandbox.

## Repository structure

```text
azure-cli-service-principal-login/
├── SKILL.md
├── README.md
└── scripts/
    └── connect-agent-azure.ps1
```

| File | Purpose |
| --- | --- |
| `SKILL.md` | Instructions for the agent: when to activate the skill, how to authenticate, safe defaults, and Azure CLI practices. |
| `scripts/connect-agent-azure.ps1` | PowerShell bootstrap for service principal authentication and Azure CLI profile isolation. |
| `README.md` | Human-facing installation, configuration, usage, and security documentation. |

## How it works

```text
Developer / user
      |
      | Natural-language Azure task
      v
   AI agent  ---> SKILL.md
      |
      | Dot-sources bootstrap once per persistent PowerShell session
      v
connect-agent-azure.ps1
      |
      +--> Read AGENT_AZURE_* environment variables
      +--> Set isolated AZURE_CONFIG_DIR
      +--> az login --service-principal
      +--> az account set --subscription ...
      |
      v
Azure CLI (`az ... --query ...`)
      |
      v
Azure resources (access governed by service principal RBAC)
```

The bootstrap does **not** overwrite the normal `%USERPROFILE%\.azure` profile. It changes `AZURE_CONFIG_DIR` **for the PowerShell process in which it runs** (and subprocesses that inherit that environment). Keep the agent's terminal separate from any terminal where you intend to use your personal Azure CLI identity.

## Prerequisites

1. **Windows** with Windows PowerShell 5.1 or PowerShell 7 and an AI agent capable of invoking PowerShell commands.
2. **Azure CLI** installed and available as `az` in `PATH`.
3. A **Microsoft Entra service principal** with a valid client secret.
4. An Azure subscription the service principal can access, with **appropriately scoped Azure RBAC permissions**.
5. A **persistent PowerShell session** for the authentication bootstrap and subsequent Azure CLI commands.

Verify the Azure CLI installation:

```powershell
az version
```

For a diagnosis-only demonstration, assigning a **Reader** role at the narrowest appropriate resource, resource-group, or subscription scope is a sensible starting point. Some diagnostics require additional narrowly scoped permissions (for example, particular monitoring-data access). Avoid broad roles such as Owner or Contributor unless the intended operations genuinely require them.

## Installation

Copy the complete `azure-cli-service-principal-login` folder into a skills directory supported by your AI agent, for example:

```text
<project>/.opencode/skills/azure-cli-service-principal-login/
```

Other agents may use a different skills path. Follow that agent's instructions for skill discovery; keep `SKILL.md` and `scripts/connect-agent-azure.ps1` together, preserving their relative paths.

The agent should read `SKILL.md` when asked to work with Azure. There is no extra package to install for this skill beyond PowerShell and Azure CLI.

## Configuration

Make these four variables available to the agent's PowerShell process:

| Variable | Required | Meaning |
| --- | --- | --- |
| `AGENT_AZURE_CLIENT_ID` | Yes | Service principal's application (client) ID. |
| `AGENT_AZURE_CLIENT_SECRET` | Yes | Service principal client secret (sensitive). |
| `AGENT_AZURE_TENANT_ID` | Yes | Microsoft Entra directory (tenant) ID. |
| `AGENT_AZURE_SUBSCRIPTION_ID` | Yes | Subscription ID to select after sign-in. |
| `AGENT_AZURE_CONFIG_DIR` | No | Explicit directory for the agent's isolated Azure CLI profile. If unset, the script creates a new path under the current user's temporary directory. |

For illustration, the **non-secret** values can be set in a PowerShell session as follows:

```powershell
$env:AGENT_AZURE_CLIENT_ID       = "<application-client-id>"
$env:AGENT_AZURE_TENANT_ID       = "<tenant-id>"
$env:AGENT_AZURE_SUBSCRIPTION_ID = "<subscription-id>"
```

Supply `AGENT_AZURE_CLIENT_SECRET` through an approved secret-management or controlled environment-injection mechanism. **Do not put real secrets in the repository, `SKILL.md`, README examples, chat prompts, or terminal transcripts.** Do not share those credentials with an agent session you do not trust.

The script looks for each required variable in this order: **Process → User → Machine**. A non-empty process-level value takes precedence. It then copies the selected value into the current process environment so that Azure CLI can use the bootstrap settings consistently.

If you specify `AGENT_AZURE_CONFIG_DIR`, choose a separate directory dedicated to the agent, **not** your existing `%USERPROFILE%\.azure` profile.

## Quick start

Run the bootstrap by **dot-sourcing** it into the *same persistent PowerShell terminal* in which you will later run Azure CLI commands:

```powershell
. "<installed-skill-directory>\scripts\connect-agent-azure.ps1"
```

> The leading `. ` (dot followed by a space) is important: it keeps `AZURE_CONFIG_DIR` and other environment changes in the current PowerShell session. Running the script in a separate `powershell -File ...` process would not preserve those variables in the caller's shell.

On success, the script prints:

```text
Azure CLI Service Principal session initialized.
```

Verify the selected identity and subscription without revealing credentials:

```powershell
az account show `
  --query "{subscription:id,tenant:tenantId,principal:user.name,identityType:user.type}" `
  --output json `
  --only-show-errors
```

Then use Azure CLI directly. **Do not repeat the login before every `az` command.** If you open a new terminal, or the agent loses its isolated `AZURE_CONFIG_DIR` setting, dot-source the bootstrap again.

### Example: list resources for an investigation

```powershell
az resource list `
  --query "[].{name:name,type:type,resourceGroup:resourceGroup,location:location}" `
  --output table `
  --only-show-errors
```

### Example: inspect a specific resource

```powershell
az resource show `
  --resource-group "<resource-group>" `
  --name "<resource-name>" `
  --resource-type "<provider/type>" `
  --api-version "<supported-api-version>" `
  --query "{id:id,name:name,location:location,properties:properties.provisioningState}" `
  --output json `
  --only-show-errors
```

The resource type and API version must match the resource you are querying. Where available, use a resource-specific `az` command instead.

## Example agent requests

Once installed and configured, you can give the agent natural-language requests such as:

> **Azure health check:** “Use the Azure CLI service principal skill to inspect my subscription. Show the resource groups and identify resources in a failed provisioning state. Do not make changes.”

> **Troubleshooting:** “Investigate why this Azure Container App is unhealthy. Check its configuration and available status information. Explain the most likely root cause, without modifying the resource.”

> **Terraform comparison:** “Compare the Terraform configuration for this resource with its current Azure state. Report the meaningful differences, taking `ignore_changes` into account. Do not apply anything.”

The agent should use targeted `az ... --query ...` commands and return the evidence supporting its conclusions. The available data depends on the service principal's assigned roles.

## Safety and permissions

This skill separates the **agent's Azure identity** from the developer's personal identity, but it does not make arbitrary Azure operations safe.

- **Azure RBAC is the enforcement boundary.** A service principal with write access may perform write operations. The skill's read-only default is an instruction, not a permission control.
- **Use least privilege.** Assign only the roles and scopes needed for the task, and consider a dedicated identity for demonstrations.
- **Treat credentials and cached tokens as sensitive.** Environment variables and files under `AZURE_CONFIG_DIR` require appropriate local access controls.
- **Be aware of command-line exposure.** The current bootstrap passes the client secret to `az login` as the `--password=...` process argument. It does not intentionally print the secret, and it redacts it from its reported login errors, but process arguments can be observable to sufficiently privileged local monitoring tools. This is a limitation of the current implementation.
- **Avoid secret-bearing queries.** Prefer metadata, resource IDs, and secret references over retrieving secret values, tokens, connection strings, or authorization headers.
- **Do not use personal `az login` as a fallback.** In particular, the agent must not silently reuse a developer's Azure CLI cache.
- **Check before changing resources.** For an inspection or troubleshooting request, do not modify Azure. If changes are requested, review their scope and impact first.
- **Temporary profiles are not automatically removed.** The bootstrap generates a directory under `%TEMP%` if `AGENT_AZURE_CONFIG_DIR` is not supplied; cached Azure CLI state may remain there after the PowerShell session ends. Remove old agent-only directories through an approved cleanup procedure after verifying they are no longer in use.

For stronger authentication assurance, evaluate certificate-based service principal authentication or workload identity federation where supported by your environment. **Those methods are not implemented by the provided bootstrap script**, which currently uses a client secret.

## Troubleshooting

| Symptom | Likely cause / action |
| --- | --- |
| `Azure CLI executable 'az' was not found in PATH` | Install Azure CLI or make `az` available in the agent's PowerShell environment. |
| `Required environment variable is missing or empty` | Supply the named `AGENT_AZURE_*` variable. Check Process, User, and Machine scopes without printing the secret. |
| Service principal sign-in fails | Check client ID, tenant ID, secret validity, and any tenant policies affecting the sign-in. |
| Subscription selection fails | Confirm the subscription ID and that the service principal has access to it. |
| `AuthorizationFailed`, `Forbidden`, or a resource-level 403 | Authentication may have succeeded, but Azure RBAC at the relevant scope may be insufficient. Do not switch to your personal login to bypass it. |
| Agent unexpectedly uses the developer's identity | Check `AZURE_CONFIG_DIR` and rerun the bootstrap in the persistent terminal used for the subsequent commands. |
| Authentication worked in one command but not the next | The commands may have run in different PowerShell processes or terminals. Reuse the same session, or authenticate separately for each new session. |
| Permissions appear wrong after an RBAC change | Verify the scope and allow for permission propagation; reauthenticate if needed. |

### Inspect the current agent profile location

```powershell
$env:AZURE_CONFIG_DIR
```

The value should be the agent's dedicated directory, **not** your normal `.azure` folder.

## Terraform considerations

When the task is to compare live Azure state to Terraform, the skill instructs the agent to:

1. Read only the relevant Terraform configuration and managed properties.
2. Account for `lifecycle.ignore_changes` and provider/API representation differences.
3. Query corresponding Azure properties with narrow `az --query` expressions.
4. Distinguish meaningful drift from harmless ordering differences.
5. Identify values that exist in Azure but are absent from Terraform and could be removed or overwritten during a future apply.
6. Clearly distinguish an inferred risk from the outcome of an actual `terraform plan`.

This skill does **not** automatically configure Terraform's `ARM_*` environment variables or run `terraform apply`.

## Reference documentation

- [Sign in with an Azure CLI service principal](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-service-principal)
- [Azure CLI configuration and `AZURE_CONFIG_DIR`](https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration)
- [Azure CLI command reference](https://learn.microsoft.com/en-us/cli/azure/reference-index)
- [Azure RBAC overview](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)

---

**In short:** Give the AI agent a dedicated Azure identity, keep its CLI session separate from yours, and let Azure RBAC limit its real permissions. The agent handles investigation and analysis; engineers remain responsible for granting access and approving changes.
