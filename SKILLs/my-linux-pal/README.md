# My Linux Pal

## Overview

My Linux Pal is an agentic skill and a pair of helper scripts for working with a
remote Linux server over SSH from Windows 11. The PowerShell script is the default on
Windows. The Bash script can be used from Git Bash or WSL.

The scripts support checking basic server status, running commands as the SSH user or
with `sudo`, and transferring files with `scp`.

## 1. Prerequisites

On the Windows workstation:

- Windows PowerShell 5.1 or later;
- Windows OpenSSH Client (`ssh.exe` and `scp.exe`);
- a private SSH key which can access the server.

On the remote Linux server:

- SSH access for the configured user;
- Bash and the `base64` command;
- `sudo` access for actions which need root privileges.

Check whether the Windows OpenSSH Client is installed:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client*
```

If it is not installed, open PowerShell as Administrator and run:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

## 2. Install the skill

Copy the complete `my-linux-pal` directory, including `SKILL.md` and `scripts`, to
one of the agent's skill directories, e.g.:

- Project installation: `<project>\.agent\skills\my-linux-pal\`

Keep the folder name as `my-linux-pal`. Agent reads the instructions from
`SKILL.md`. Restart the agent if it was already running during installation.

## 3. Configure the PowerShell script

Create the config directory and file:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\my-linux-pal" | Out-Null
notepad "$env:USERPROFILE\.config\my-linux-pal\config.json"
```

Use this template and replace placeholders with your connection details:

```json
{
  "host": "<server-hostname-or-ip>",
  "user": "<ssh-user>",
  "port": 22,
  "key": "%USERPROFILE%\\.ssh\\id_ed25519",
  "sudoPass": ""
}
```

`host` and `user` are required. `port` defaults to `22`. The `key` value points to
the SSH private key on the Windows workstation. Environment variables such as
`%USERPROFILE%` are expanded. Backslashes must be doubled in JSON.

If the account has passwordless sudo, leave `sudoPass` empty. The script will use
`sudo -n`. Otherwise, a sudo password can be set in the local config file. Keep that
file private and do not paste the password into chat or command lines.

To use a different config path, set `MY_LINUX_PAL_CONFIG` before running the script:

```powershell
$env:MY_LINUX_PAL_CONFIG = "C:\path\to\config.json"
```

### Private key permissions

If OpenSSH reports `UNPROTECTED PRIVATE KEY FILE!`, restrict access to the key:

```powershell
$key = "$env:USERPROFILE\.ssh\id_ed25519"
icacls $key /inheritance:r
icacls $key /grant:r "$($env:USERNAME):(R)"
```

## 4. Test the connection

Run the connection and sudo check. Update `$skill` to the folder where the skill was
installed:

```powershell
$skill = "$env:USERPROFILE\.config\agent\skills\my-linux-pal"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" check
```

The script checks SSH access first, then checks sudo access. If sudo is not available,
review the account's sudo configuration before using actions which need root.

Show general server information:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" info
```

## 5. Use the PowerShell helper

The available actions are `info`, `check`, `run`, `sudo`, `put`, and `get`.

```powershell
# Run a command as the configured SSH user
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" run "df -h /"

# Run a command with sudo
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" sudo "systemctl --failed --no-pager"

# Upload a local file
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" put "C:\work\nginx.conf" "/tmp/nginx.conf"

# Download a remote file
powershell -NoProfile -ExecutionPolicy Bypass -File "$skill\scripts\my-linux-pal.ps1" get "/var/log/syslog" "C:\work\syslog.txt"
```

Use one logical action per call. Check the output and exit code before continuing.
Review the `SKILL.md` safety rules before making changes to the server.

## 6. Use the Bash helper from Git Bash or WSL

The Bash script reads `~/.config/my-linux-pal/config.env` by default. Create the file
with these settings:

```bash
MY_LINUX_PAL_HOST="<server-hostname-or-ip>"
MY_LINUX_PAL_USER="<ssh-user>"
MY_LINUX_PAL_PORT="22"
MY_LINUX_PAL_KEY="$HOME/.ssh/id_ed25519"
MY_LINUX_PAL_SUDO_PASS=""
```

The file is sourced as a shell script. Keep it private if it contains a sudo password.
You can set `MY_LINUX_PAL_CONFIG` to use another config file.

Run it from Git Bash or WSL:

```bash
./my-linux-pal.sh check
./my-linux-pal.sh info
./my-linux-pal.sh run "df -h /"
```

## 7. Ask agent to use the skill

After installation, ask the agent to do a task in normal language, for example:

- `Check the status of my Linux server and show failed systemd services.`
- `Check the last 50 error messages in the server journal.`
- `Upload this local config file to /tmp and validate it on the server.`

The skill gives the agent the connection workflow and safety rules. The local config
file provides the connection details to the helper script.

## 8. Troubleshooting

| Problem | What to check |
| --- | --- |
| `ssh.exe not found` or `scp.exe not found` | Install the Windows OpenSSH Client feature |
| `UNPROTECTED PRIVATE KEY FILE!` | Restrict the private key ACL with `icacls` |
| `Permission denied (publickey)` | Check the key path and the remote user's `authorized_keys` |
| `Connection timed out` | Check hostname, port, server availability, network, and VPN |
| `sudo: a password is required` | Configure passwordless sudo or set `sudoPass` in the local config |
| `base64: command not found` | Install or locate the `base64` utility on the Linux server |
| `$'\r': command not found` | Convert uploaded scripts from CRLF to LF line endings |

For more operational guidance and safety rules, see `SKILL.md`.
