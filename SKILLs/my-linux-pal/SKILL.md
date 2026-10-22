---
name: my-linux-pal
description: Use when the user asks to inspect or manage a remote Linux server over SSH from Windows 11 - check status and logs, manage systemd services or Docker, inspect disk, memory or network, install packages, edit files, transfer files, or reboot. Uses SSH key authentication and sudo when required.
---

# Skill: Remote Linux server (SSH access from Windows)

This skill helps the user inspect and manage a remote Linux server over SSH. The local
workstation is Windows 11. Use `scripts\my-linux-pal.ps1` by default; it uses the
built-in Windows OpenSSH client.

## 1. Overview

- Connect with SSH and a private key. Do not use password-based SSH login.
- The remote account may use `sudo`. An optional sudo password is read from a local
  JSON config and sent through stdin, not as a command-line argument.
- The PowerShell wrapper sends the remote command as base64 and decodes it on the
  server. This keeps stdin available for sudo input and avoids quoting problems.
- `scripts\my-linux-pal.sh` provides the same actions for Git Bash or WSL. On Windows,
  use the PowerShell version by default.

This is a real remote server, not a test environment. Be careful with changes which can
break network access, boot, services, or data.

## 2. How to call the PowerShell script

Use the installed skill path and pass one action per call:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.config\opencode\skills\my-linux-pal\scripts\my-linux-pal.ps1" <action> ...
```

If the skill is installed in a project, replace the path with that project's
`.opencode\skills\my-linux-pal\scripts\my-linux-pal.ps1` path.

Actions:

```powershell
# connection and sudo test
... my-linux-pal.ps1 check

# basic server status
... my-linux-pal.ps1 info

# command as the normal user
... my-linux-pal.ps1 run "df -h /"
... my-linux-pal.ps1 run "docker ps -a"

# command with sudo
... my-linux-pal.ps1 sudo "systemctl restart nginx"
... my-linux-pal.ps1 sudo "apt-get update"

# file transfer
... my-linux-pal.ps1 put "C:\work\nginx.conf" "/tmp/nginx.conf"
... my-linux-pal.ps1 get "/var/log/syslog" "C:\work\syslog.txt"
```

Rules:

- Run one logical action per call. Avoid long chained one-liners.
- Prefer non-interactive commands and flags, for example `systemctl --no-pager` and
  `journalctl --no-pager`.
- Do not run commands which wait for interactive input (`top`, `htop`, `nano`, `vi`).
  Use `top -b -n1` for a non-interactive process snapshot.
- Multi-line Bash is allowed in `run` and `sudo`, but keep it short.
- Read the output and check for errors before the next step.
- Check `$LASTEXITCODE` for the remote command result.

## 3. Configuration (Windows)

Default config file:
`%USERPROFILE%\.config\my-linux-pal\config.json`

```json
{
  "host": "<server-hostname-or-ip>",
  "user": "<ssh-user>",
  "port": 22,
  "key": "%USERPROFILE%\\.ssh\\id_ed25519",
  "sudoPass": ""
}
```

- `host` and `user` are required.
- `port` defaults to `22`.
- `key` is the private key path. Environment variables such as `%USERPROFILE%` are
  expanded. Backslashes must be doubled in JSON.
- `sudoPass` is optional. If empty, the script uses `sudo -n` and expects passwordless
  sudo. Keep this file private if it contains a password.
- Set `MY_LINUX_PAL_CONFIG` to use a different config path.

Create the default directory and file:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\my-linux-pal" | Out-Null
notepad "$env:USERPROFILE\.config\my-linux-pal\config.json"
```

If the config does not exist, ask the user for the host, SSH user, and key path. Never
print a sudo password, copy it into another file, or include it in session output.

### Private key permissions

Windows OpenSSH can reject a private key which is readable by other users with
`UNPROTECTED PRIVATE KEY FILE!`. Restrict its ACL if needed:

```powershell
$key = "$env:USERPROFILE\.ssh\id_ed25519"
icacls $key /inheritance:r
icacls $key /grant:r "$($env:USERNAME):(R)"
```

Apply appropriate access restrictions to `config.json` too if it contains `sudoPass`.

### If the OpenSSH client is missing

Check or install the Windows optional OpenSSH Client feature:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client*
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

## 4. Safety rules

Before running a destructive command, show the exact command and ask the user to
confirm. Destructive actions include:

- deleting or moving data, truncating files, `dd`, filesystem or partition operations;
- package removal, purge, distribution upgrade, or autoremove;
- changes to network, SSH, firewall, boot, mount, user-account, or sudoers configuration;
- reboot, shutdown, or stopping/disabling services;
- deleting Docker volumes, running `docker system prune`, or removing containers with
  data.

Always:

1. Back up a configuration file before editing it, for example:
   `... my-linux-pal.ps1 sudo "cp -a /etc/<file> /etc/<file>.bak.$(date +%Y%m%d%H%M%S)"`
2. Check syntax after editing when the service supports it, for example `nginx -t`,
   `sshd -t`, `visudo -c`, or `docker compose config`.
3. After a service change, check its status and recent logs.
4. Keep changes minimal; do not refactor existing configuration without a request.

Never apply an SSH or firewall change which may drop the current connection without a
rollback plan. Confirm that the SSH port remains allowed when changing firewall rules.

Never print sudo passwords, SSH keys, tokens, or the contents of `~/.ssh/`. Mask secrets
if they appear in logs or configuration output.

## 5. Typical diagnostic sequence

Start with a general status, then check failed services, logs, and relevant components:

```powershell
... my-linux-pal.ps1 info
... my-linux-pal.ps1 sudo "systemctl --failed --no-pager"
... my-linux-pal.ps1 sudo "journalctl -p err -n 50 --no-pager"
... my-linux-pal.ps1 run "docker ps -a"                 # if Docker is used
... my-linux-pal.ps1 sudo "dmesg -T | tail -n 50"
```

## 6. Editing files on the server

For small changes, use a tool which creates a backup. For larger changes, prepare the
file locally on Windows and upload it:

```powershell
# small change
... my-linux-pal.ps1 sudo "sed -i.bak 's/^#\?Port .*/Port 22/' /etc/ssh/sshd_config"
... my-linux-pal.ps1 sudo "sshd -t"

# full file replacement
... my-linux-pal.ps1 put "C:\work\nginx.conf" "/tmp/nginx.conf"
... my-linux-pal.ps1 sudo "cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak && install -m 644 /tmp/nginx.conf /etc/nginx/nginx.conf && nginx -t"
... my-linux-pal.ps1 sudo "systemctl reload nginx"
```

ATTENTION! Windows files may use CRLF line endings. This can break shell scripts,
`systemd` units, and some configuration files. Convert a script to LF before upload:

```powershell
$text = Get-Content -Raw "C:\work\script.sh"
[IO.File]::WriteAllText("C:\work\script.sh", ($text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
```

Or remove CR characters on the server after upload:
`... my-linux-pal.ps1 run "sed -i 's/\r$//' /tmp/script.sh"`.

## 7. Package updates

Package manager commands depend on the server's Linux distribution. These examples are
for Debian or Ubuntu:

```powershell
... my-linux-pal.ps1 sudo "apt-get update"
... my-linux-pal.ps1 sudo "apt-get -s upgrade"          # simulate first and review output
... my-linux-pal.ps1 sudo "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
... my-linux-pal.ps1 sudo "test -e /var/run/reboot-required"
```

Use the distribution's package manager on other systems. Run distribution upgrades,
package removal, and autoremove only after explicit confirmation. Reboot only after
explicit confirmation. After reboot, wait and test the connection:

```powershell
... my-linux-pal.ps1 sudo "systemctl reboot"
Start-Sleep -Seconds 45
... my-linux-pal.ps1 info
```

## 8. Troubleshooting

| Problem | What to check |
| --- | --- |
| `UNPROTECTED PRIVATE KEY FILE!` | Restrict key ACL with `icacls`, see section 3 |
| `Permission denied (publickey)` | Check key path and confirm its public key is in the remote user's `~/.ssh/authorized_keys` |
| `Connection timed out` | Check host, port, server availability, network, and VPN |
| `Host key verification failed` | Confirm the host key change with the user before running `ssh-keygen -R <host>` |
| `sudo: a password is required` | Configure passwordless sudo or provide `sudoPass` in the local config |
| `base64: command not found` | Check that `base64` (usually provided by coreutils) is installed on the server |
| `$'\r': command not found` | Convert the uploaded file to LF line endings, see section 6 |
| Script does not start | Use `-NoProfile -ExecutionPolicy Bypass -File`, as shown in section 2 |

## 9. Reporting back

After the work is done, give a short report:

- what was checked or changed;
- exact commands which changed something;
- result and current status;
- how to roll back, if a change was applied.
