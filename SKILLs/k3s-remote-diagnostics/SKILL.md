---
name: k3s-remote-diagnostics
description: Diagnose a remote K3s cluster from Windows over a restricted SSH alias (myk3s-ro). Inspect Pods, Events, failed image pulls, workloads, K3s journal, Traefik, networking, storage, resource pressure, and selected host configurations. Read-only incident investigation only; never modify the host or cluster.
---

# K3s Remote Diagnostics

Use this skill to investigate incidents in a remote K3s cluster **without making changes**. The Windows agent calls `ssh.exe`; a dedicated SSH account is bound to a forced-command dispatcher on the server. The dispatcher permits only selected diagnostic actions, and Kubernetes access uses a limited ServiceAccount with no write permissions.

**Do not use a direct remote shell or a PowerShell wrapper. Do not use this skill to remediate an incident.**

## Connection and command format

Use the existing SSH config alias **exactly** as provided:

```text
myk3s-ro
```

Send a single read-only diagnostic action per call:

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro <action> <arguments>
```

Examples:

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro help
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro status
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro resources
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get pods -A -o wide
```

Host, user, key, timeout, and batch mode come from the user's SSH configuration. Do not substitute an IP address, another user, another key, or another target. Never bypass SSH host-key verification.

## Mandatory safety rules

- **Diagnosis only.** Never run or propose executing a write operation through this connection.
- Do not attempt `apply`, `create`, `delete`, `edit`, `patch`, `replace`, `scale`, `set`, `label`, `annotate`, `taint`, `cordon`, `uncordon`, `drain`, `exec`, `attach`, `cp`, `port-forward`, `rollout restart`, or equivalent mutations.
- Never request Kubernetes Secret resources or attempt to obtain tokens, kubeconfigs, SSH keys, or other credentials. Do not bypass the dispatcher or RBAC, or substitute a different transport.
- Never override kubectl identity, context, user, server, TLS/CA, proxy, or impersonation flags.
- Never request a general SSH shell, TTY, tunnel, file transfer, SCP, SFTP, rsync, or SSH port forwarding (`-L`, `-R`, `-D`, `-W`).
- Do not request streaming output (`-f`, `--follow`, `-w`, `--watch`, `--watch-only`, or `--output-watch-events`). Prefer bounded Events, logs, and journal snapshots.
- Restrict queries to relevant namespaces and objects once identified; minimise output.
- **Read permissions can still expose secrets in logs, ConfigMaps and manifests.** Avoid fetching unrelated configuration and do not repeat or reproduce exposed credentials in the report.
- Do not edit local repository files unless the user separately asks for a local-only source change.
- If a fix is needed, explain it for an authorised engineer to apply separately. **Do not execute it with this skill.**

## Actions supported by the dispatcher

```text
kube <allowlisted read-only kubectl command and arguments>
journal [duration] [lines]
read <allowlisted-path> [start-line] [line-count]
find <allowlisted-directory> [max-depth]
status
resources
ports
dns <hostname>
tls <hostname> [port]
help
```

The dispatcher accepts selected kubectl operations such as `get`, `describe`, `logs`, `top`, `events`, `explain`, `api-resources`, `api-versions`, and limited read-oriented status commands. Kubernetes Secrets and modifications are not permitted. The remote host and RBAC are the source of truth about access; if an action is denied, report the denial and **do not attempt a workaround**.

## Investigation strategy

Start with the symptom and narrow the investigation. Only gather evidence needed to support or reject an explanation. Record affected namespace, resource name, status, Event reason, error text, and relevant timestamps.

### 1. Cluster overview

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro status
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro resources
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get nodes -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get pods -A -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get events -A --sort-by=.metadata.creationTimestamp
```

Common signals include `Pending`, `ImagePullBackOff`, `ErrImagePull`, `CrashLoopBackOff`, `CreateContainerConfigError`, `OOMKilled`, mount errors, unhealthy probes, and scheduling failures. Events may be short-lived; absence of older Events is not evidence that a failure never happened.

### 2. Image-pull failure / GitLab Container Registry (presentation example)

For a Pod stuck in `ErrImagePull` or `ImagePullBackOff`:

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get pods -n NAMESPACE -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube describe pod POD_NAME -n NAMESPACE
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get events -n NAMESPACE --sort-by=.metadata.creationTimestamp
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get deployment DEPLOYMENT_NAME -n NAMESPACE -o wide
```

Inspect container image references, `imagePullSecrets` **names only**, `Failed`/`BackOff` Warning Events, and registry errors. Look for `401 Unauthorized`, `403 Forbidden`, `unauthorized: authentication required`, `failed to authorize`, DNS failures, registry TLS errors, or missing tags.

**Critical distinction:** registry authentication failure is not proof of an *expired* token. The token might be missing, invalid, revoked, under-scoped, or expired. Because this skill cannot inspect Kubernetes Secrets or independently check GitLab credentials, report **"registry authentication failure; token expiry suspected"** unless external evidence confirms expiration.

A container that has **never** been created because image pulling failed generally has no application logs. Do not interpret an empty/failed `kubectl logs` request as evidence that the application is healthy. Pod Events and `describe` output are more informative.

Propose a human-controlled fix such as validating/renewing the GitLab registry credential, updating the image-pull Secret through separately authorised access, and verifying a successful subsequent pull. **Do not attempt to read or replace the Secret.**

### 3. CrashLoopBackOff / application failures

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube describe pod POD_NAME -n NAMESPACE
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube logs POD_NAME -n NAMESPACE --all-containers --tail=200
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube logs POD_NAME -n NAMESPACE --all-containers --previous --tail=200
```

Correlate exit status, termination reasons, restart count, probes, limits, and logs. Mask credentials if a log accidentally contains them.

### 4. Services, Ingress, Traefik and certificates

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get service,endpoints,endpointslice -A -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get ingress -A -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get ingressroute,middleware,traefikservice -A -o wide
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube logs deployment/traefik -n kube-system --tail=300
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro kube get helmchartconfig traefik -n kube-system -o yaml
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro dns example.com
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro tls example.com 443
```

Check selector/endpoint mismatch, `targetPort`, ingress class, Traefik routing, DNS resolution, ACME challenge configuration, certificate validity, or rate limits. Custom resources may be absent; treat a `NotFound` as context, not automatically as a cluster failure.

### 5. K3s and host issues

```powershell
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro journal 2h 300
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro ports
ssh.exe -o ClearAllForwardings=yes -o PermitLocalCommand=no myk3s-ro find /var/lib/rancher/k3s/server/manifests 3
```

The dispatcher also offers `read /etc/rancher/k3s/config.yaml`, but **this file may contain cluster credentials**; do not request it unless its contents have been explicitly reviewed/sanitised for diagnostic access. Avoid reading entire YAML manifests without checking whether they contain Secret resources or embedded credentials.

Use bounded host logs and status for K3s startup failures, resource exhaustion, TLS issues, and local port conflicts.

## Failure handling

- SSH exit code 255: investigate transport, host-key, DNS, SSH identity, and connectivity; do not mistake it for a Kubernetes failure.
- Host-key failure: stop and report; never set `StrictHostKeyChecking=no`.
- `Permission denied (publickey)`: report; do not try another identity or password automatically.
- Dispatcher `Denied:`: report the rejected action; do not work around it.
- Kubernetes `Forbidden`: report that RBAC blocks the operation; do not use impersonation or a privileged kubeconfig.
- Resource `NotFound`: check namespace, resource name, and resource type before concluding a workload is absent.
- Distinguish observed facts, probable causes, and conclusions that need further evidence.

## Report format

1. **Incident / affected resources:** concise summary including namespace and Pod/workload.
2. **Observed evidence:** exact status, Warning Event reasons, relevant short error messages and any timestamps.
3. **Root cause and confidence:** state whether proven, probable, or only suspected; list alternative explanations if needed.
4. **Recommended remediation (not executed):** smallest practical change and who must perform it.
5. **Verification plan:** read-only checks the agent can run after an engineer has applied the fix.
6. **Actions taken:** list diagnostic queries; state clearly that **no cluster or host changes were made**.
