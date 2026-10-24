# K3s Remote Diagnostics

A **diagnostics-only agent skill** for investigating a remote [K3s](https://k3s.io/) cluster from a Windows workstation over SSH. An AI coding agent can inspect Kubernetes objects, Pod Events, bounded logs, K3s service health, selected host metrics, and explicitly permitted configuration files **without an unrestricted remote shell or cluster write permissions**.

The skill is intended for incident investigation and root-cause analysis. It does **not** repair the cluster, rotate credentials, restart workloads, or apply changes. Remediation is a separate action performed by an authorised engineer.

## How it works

```text
Windows 11                                      Remote K3s host
+------------------------+                      +--------------------------------+
| AI agent               |                      | sshd                          |
| SKILL.md instructions  |                      | dedicated user: codexdiag     |
|        |               |     SSH key          | forced command:               |
|     ssh.exe -----------+--------------------->|   codexdiag-dispatch           |
+------------------------+                      |     |                 |        |
                                                |  allowlisted       bounded    |
                                                |  kubectl           host reads |
                                                |     |                          |
                                                |  ServiceAccount:              |
                                                |  codex-diagnostics            |
                                                |  limited Kubernetes RBAC      |
                                                +--------------------------------+
```

There are **three distinct controls**:

1. **SSH:** the dedicated `codexdiag` login uses an SSH public key with the `restrict` option and a forced dispatcher command. It cannot open a normal interactive shell through that key.
2. **Command dispatcher:** `server/codexdiag-dispatch` recognises a limited set of diagnostic commands. It rejects Kubernetes write verbs, arbitrary shell commands, forwarding, and file access outside its hard-coded allowlist.
3. **Kubernetes RBAC:** a dedicated ServiceAccount has get/list/watch rights to specified diagnostic resources and get access to Pod logs. Kubernetes Secret objects and mutating operations are not granted. The dispatcher rejects common watch/streaming flags, while the agent instructions prohibit all streaming investigations.

These are defence-in-depth controls, **not a guarantee that all readable data is non-sensitive**. See [Security considerations](#security-considerations) before using the skill on a production cluster.

## Repository contents

| File | Purpose |
| --- | --- |
| `SKILL.md` | Instructions and investigation workflows for the agent. |
| `server/codexdiag-dispatch` | Forced SSH command and diagnostic allowlist. |
| `server/install.sh` | One-time server-side installation (run as root by an administrator). |
| `server/rbac.yaml` | Diagnostic ServiceAccount, ClusterRole, ClusterRoleBinding, and token Secret. |
| `server/audit-policy-fragment.yaml` | **Optional** Kubernetes audit policy fragment; not installed automatically. |
| `windows/ssh-config.example` | Example Windows OpenSSH alias configuration. |

The `codexdiag` identifiers are historical names used by the installation scripts; the skill itself is named `k3s-remote-diagnostics` and can be used with any Windows-based agent that can invoke `ssh.exe`.

## Prerequisites

**Windows workstation**

- Windows 11 with the OpenSSH client (`ssh.exe`, `ssh-keygen.exe`).
- An AI agent/CLI that is allowed to run local terminal commands and discover `SKILL.md`.
- An administrative way to copy the installation files and an SSH public key to the host.

**Remote host**

- A working K3s server with the binary at `/usr/local/bin/k3s` and its API reachable locally at `https://127.0.0.1:6443`.
- Root/sudo access **for installation only**; the diagnostic SSH account does not use sudo.
- Bash, OpenSSH server, `systemd`/`journalctl`, `realpath`, `base64`, `ss`, `getent`, `openssl`, and `timeout` for the corresponding diagnostics. The installer uses `apt-get` to install `acl` if it is missing (Debian/Ubuntu assumption).
- Port 22 reachable from the workstation. **No public exposure of Kubernetes API port 6443 is required.**

## Installation

### 1. Create a dedicated SSH key on Windows

From PowerShell:

```powershell
ssh-keygen.exe -t ed25519 -f "$HOME\.ssh\id_ed25519_codex_k3s" -C "k3s-diagnostics-readonly"
```

Keep the **private** key on Windows. Copy only `id_ed25519_codex_k3s.pub` to the K3s host using an existing administrator connection. Do not copy it into the agent prompt or commit it to Git.

### 2. Install the server component

Copy the `server/` directory to the remote host (for example, `/tmp/k3s-remote-diagnostics/server/`) and put the public key at `/tmp/id_ed25519_codex_k3s.pub`.

On the remote host, as an administrator:

```bash
sudo bash /tmp/k3s-remote-diagnostics/server/install.sh \
  /tmp/id_ed25519_codex_k3s.pub
```

The installer creates the `codexdiag` OS account, its forced-command SSH key, a K3s ServiceAccount and RBAC objects, a locally stored ServiceAccount-token kubeconfig, and selected host-file ACLs. It checks that the new account can list Kubernetes namespaces.

**Important:** by default the installer grants filesystem read access to paths including `/etc/rancher/k3s/config.yaml` and the K3s manifests directory. **Review and sanitise the paths and their contents before running the installer**; they can contain credentials or Kubernetes Secret manifests. See [Security considerations](#security-considerations).

The installer accepts extra file/directory arguments, but granting an ACL **does not** automatically add a path to the dispatcher's `ALLOWED_READ_ROOTS`. Additional paths require a separate, reviewed update of that allowlist. Conversely, removing an ACL alone is not a substitute for reviewing the allowlist.

### 3. Configure the SSH alias on Windows

Copy `windows/ssh-config.example` into `%USERPROFILE%\.ssh\config` (or merge the block into an existing file):

```sshconfig
Host myk3s-ro
    HostName YOUR_SERVER_IP_OR_DNS
    User codexdiag
    IdentityFile ~/.ssh/id_ed25519_codex_k3s
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 2
```

Replace `YOUR_SERVER_IP_OR_DNS` with the host's actual address. Verify the remote host key through a trusted channel on first connection; never disable host-key checking just to make a demo work.

### 4. Verify the restricted connection

From PowerShell:

```powershell
ssh.exe myk3s-ro help
ssh.exe myk3s-ro status
ssh.exe myk3s-ro kube get nodes -o wide
ssh.exe myk3s-ro kube get pods -A -o wide
```

The forced dispatcher should reject commands it does not recognise. For example, `ssh.exe myk3s-ro uname -a` should be denied rather than starting an unrestricted shell.

### 5. Install the agent skill

Copy the complete `k3s-remote-diagnostics/` directory into the skill directory supported by your agent, e.g. a repository-scoped `.agents/skills/k3s-remote-diagnostics/` for an agent that supports that layout. Other agents may use another directory; consult the agent's skill-discovery convention. Restart or reload the agent if necessary.

Example natural-language request:

> Use `k3s-remote-diagnostics` to investigate why the `web-api` Pod in namespace `demo` is stuck in `ImagePullBackOff`. Diagnose only; do not change the cluster. Show the evidence, the most likely root cause, and the recommended human remediation.

## Available commands

Run all operations through the alias and dispatcher; **never** use a direct unrestricted SSH session for agent diagnostics:

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro <action> <arguments>
```

| Action | What it does | Example arguments |
| --- | --- | --- |
| `help` | List the supported actions | (none) |
| `status` | K3s `systemctl status` snapshot | (none) |
| `resources` | Host uptime, memory and disk | (none) |
| `ports` | Listening TCP/UDP sockets | (none) |
| `kube` | Allowlisted non-mutating kubectl operations using restricted RBAC | `get pods -A -o wide` |
| `journal` | Bounded K3s journal | `30m 200` |
| `read` | Read part of a file under the host-path allowlist | `/etc/rancher/k3s/config.yaml 1 100` |
| `find` | List files below an allowed directory | `/var/lib/rancher/k3s/server/manifests 3` |
| `dns` | Resolve a hostname from the server | `example.com` |
| `tls` | Inspect TLS connection/certificate for a hostname | `example.com 443` |

The dispatcher accepts selected `kubectl` subcommands (`get`, `describe`, `logs`, `top`, `events`, and a few other read-oriented queries), but not `apply`, `delete`, `exec`, or other mutations. It also rejects identity/API-server overrides. `journal` defaults to the last 2 hours/1,000 lines and limits output to 5,000 lines. `read` is line-bounded (maximum 5,000 lines per call). Avoid dumping extensive configurations or logs, even if they are technically accessible.

## Example incident: image pull from GitLab Container Registry fails

**Symptom:** a Pod cannot start and shows `ErrImagePull` or `ImagePullBackOff`. The image is hosted in a private GitLab Container Registry.

The agent can investigate without modifying the cluster:

```powershell
ssh.exe myk3s-ro kube get pods -A -o wide
ssh.exe myk3s-ro kube describe pod POD_NAME -n NAMESPACE
ssh.exe myk3s-ro kube get events -n NAMESPACE --sort-by=.metadata.creationTimestamp
ssh.exe myk3s-ro kube get deployment DEPLOYMENT_NAME -n NAMESPACE -o wide
```

It should correlate Pod status, **Warning Events**, the image reference, and `imagePullSecrets` references. Typical evidence includes a registry `401 Unauthorized` response or an authentication failure when K3s/containerd attempts to pull the image. **An image that has never started has no application container logs**: Events and Pod status are the primary evidence in this case.

**What the agent can conclude:** the pull failed during registry authentication and the relevant image-pull credential may be missing, invalid, revoked, or expired. A `401` response **alone does not prove token expiry**. Confirming expiry generally requires an authorised credential/registry check outside this read-only skill. An administrator can then renew or replace the credential and update the appropriate Kubernetes image-pull Secret, followed by a new pull attempt.

The skill must **not** read the Secret or perform the remediation. Its useful output is a fact-based diagnosis and a precise suggested next action.

## Verify Kubernetes RBAC

Run the following as a **separate cluster administrator**, not through the diagnostics SSH alias:

```bash
SA='system:serviceaccount:kube-system:codex-diagnostics'
k3s kubectl auth can-i list pods --all-namespaces --as="$SA"
k3s kubectl auth can-i get pods --subresource=log --all-namespaces --as="$SA"
k3s kubectl auth can-i get secrets --all-namespaces --as="$SA"
k3s kubectl auth can-i create deployments --all-namespaces --as="$SA"
k3s kubectl auth can-i create pods --subresource=exec --all-namespaces --as="$SA"
k3s kubectl auth can-i get nodes --subresource=proxy --as="$SA"
```

Expected results, in order: `yes`, `yes`, `no`, `no`, `no`, `no`.

## Security considerations

- **Read-only does not mean non-sensitive.** Events, logs, workload specifications, ConfigMaps, `/etc/rancher/k3s/config.yaml`, and plaintext manifest files can reveal credentials. The dispatcher prevents querying Kubernetes Secret objects, but it **cannot guarantee** that secrets have not been copied into otherwise readable resources. Review the filesystem allowlist and ACLs before installation; redact findings before sharing them.
- **The installer uses a persistent ServiceAccount token Secret.** The generated kubeconfig stores a credential in `/home/codexdiag/.kube/config` with mode `0600`. Protect the host and SSH key, audit use, and revoke access when no longer needed. For stricter deployments, replace this with a separately designed short-lived credential workflow.
- **The RBAC policy is broad in visibility.** It permits many read operations across namespaces, and reads may expose internal architecture or operational data. Narrow the Role/ClusterRole further for your environment if feasible.
- **The dispatcher allowlist and the filesystem ACL are different controls.** Both need review. The `install.sh` script's extra path arguments only add ACLs; they do not extend dispatcher access automatically.
- **The account has no sudo.** K3s mutation is blocked by command filtering and RBAC, while access to selected host files comes from ACLs and journal group membership. This is not an isolated sandbox or a general containment guarantee.
- **Outbound DNS/TLS probes can contact arbitrary supplied hostnames.** Use them only for authorised diagnostics. Keep the diagnostic account and host network appropriately restricted.
- **Do not put real credentials in demo material.** Use a non-production cluster and redact SSH keys, tokens, internal domains and log contents before publishing screenshots or the repo.

The sample `server/audit-policy-fragment.yaml` is an optional **fragment**, not a complete K3s audit policy. It is not installed or activated by `install.sh`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| SSH timeout/refused | Reachability of the server and SSH port; firewall rules; SSH service. |
| `Permission denied (publickey)` | Alias, SSH identity path, installed public key, and server-side authorised key permissions. |
| Host-key verification failed | Verify the server's host key through an out-of-band channel; do not bypass the check. |
| `Denied: Unknown command` | The request is outside the dispatcher allowlist. Do not bypass it. |
| `Forbidden` from Kubernetes | RBAC does not grant the requested API operation/resource. |
| A configured extra path cannot be read | Check both host ACLs **and** the dispatcher's hard-coded path allowlist. |
| Failed to list namespaces after installation | Check K3s API availability, ServiceAccount token population, RBAC, and `/home/codexdiag/.kube/config`. |
| Pod has no container logs | If image pulling failed, inspect Pod description and Events instead. |

## Revoke and uninstall

Perform the following with separate administrator access (never through the restricted alias):

```bash
sudo k3s kubectl delete clusterrolebinding codex-diagnostics-readonly
sudo k3s kubectl delete clusterrole codex-diagnostics-readonly
sudo k3s kubectl delete secret codex-diagnostics-token -n kube-system
sudo k3s kubectl delete serviceaccount codex-diagnostics -n kube-system
sudo userdel -r codexdiag
sudo rm -f /usr/local/sbin/codexdiag-dispatch
```

Also remove the ACL entries the installer placed on each allowed file/tree and any extra paths. Examples (adjust to what was actually installed):

```bash
sudo setfacl -x u:codexdiag /etc/rancher/k3s/config.yaml
sudo setfacl -R -x u:codexdiag /var/lib/rancher/k3s/server/manifests
sudo setfacl -R -x d:u:codexdiag /var/lib/rancher/k3s/server/manifests
```

If a file or directory no longer exists, omit that command. Check remaining access-control entries with `getfacl` as needed. Remember to remove the workstation SSH alias and the dedicated private key when they are no longer required.

## Scope

This repository contains an agent skill and server-side setup, **not** a standalone Kubernetes controller or an MCP server. Diagnostics are executed by `ssh.exe` through a restricted forced-command SSH account; any resulting remediation belongs to an engineer with separate administrative access.
